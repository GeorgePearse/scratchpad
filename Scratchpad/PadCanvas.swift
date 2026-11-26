import PencilKit
import ScratchKit
import SwiftUI
import UIKit

/// The drawing surface: clean diagram underneath, live PencilKit ink on top, on a canvas that
/// pans and zooms.
struct PadCanvas: UIViewRepresentable {
    let store: PadStore
    // Passed in as plain values so SwiftUI calls `updateUIView` whenever they change.
    let diagram: Diagram
    let document: PadDocument?
    let summary: String
    let tool: PadStore.Tool
    let penColor: InkColor
    let highlighterColor: InkColor
    let penWidth: Double
    let highlighterWidth: Double
    let fingerDraws: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeUIView(context: Context) -> PadView {
        let view = PadView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PadView, context: Context) {
        view.diagramView.diagram = diagram
        view.diagramView.document = document
        // PDF pages are white paper. Keep the pad light while one is shown, or Dark Mode would
        // turn the ink white and make it vanish on the page.
        view.overrideUserInterfaceStyle = document == nil ? .unspecified : .light
        view.accessibilityValue = summary
        view.configure(.init(tool: tool, penColor: penColor, highlighterColor: highlighterColor,
                             penWidth: penWidth, highlighterWidth: highlighterWidth, fingerDraws: fingerDraws))
    }

    @MainActor
    final class Coordinator: NSObject, InkSurface, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        private let store: PadStore
        private weak var view: PadView?
        private var movingNodeID: String?
        private var moveStart: CGPoint = .zero

        init(store: PadStore) {
            self.store = store
        }

        func attach(to view: PadView) {
            self.view = view
            view.canvas.delegate = self
            view.onFirstLayout = { [store] in store.showContent(animated: false) }

            view.movePan.addTarget(self, action: #selector(handleMove))
            view.movePan.delegate = self
            view.selectPan.addTarget(self, action: #selector(handleSelect))
            view.selectPan.delegate = self
            view.eraseTracker.addTarget(self, action: #selector(handleErase))
            view.eraseTracker.delegate = self
            view.canvas.addInteraction(UIPencilInteraction(delegate: self))

            store.ink = self

            if Trace.isOn {
                // Report every touch that reaches the canvas, and prove the main thread is alive.
                let probe = UILongPressGestureRecognizer(target: self, action: #selector(traceTouch))
                probe.minimumPressDuration = 0
                probe.cancelsTouchesInView = false
                probe.delaysTouchesEnded = false
                probe.delegate = self
                view.canvas.addGestureRecognizer(probe)
                traceProbe = probe
                Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let view = self.view else { return }
                        let r = view.visibleRect
                        Trace.log("alive; viewing (\(Int(r.minX)), \(Int(r.minY))) \(Int(r.width))x\(Int(r.height)) at zoom \(String(format: "%.2f", view.canvas.zoomScale)), policy \(view.canvas.drawingPolicy.rawValue), tool \(type(of: view.canvas.tool)), strokes \(view.canvas.drawing.strokes.count), loop \(self.store.loop.phase), error \(self.store.loop.lastError ?? "none")")
                    }
                }
            }
        }

        private var traceProbe: UIGestureRecognizer?
        private var traceTouchType = "?"

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if recognizer === view?.selectPan, let view {
                // Where the finger first lands is one corner of the box. A pan only reports itself
                // after some travel, so the corner has to be caught here.
                selectionStart = touch.location(in: view)
            }
            if recognizer === view?.movePan, let view {
                // Likewise for dragging a shape: what matters is what the finger landed on.
                moveStart = touch.location(in: view)
            }
            if recognizer === traceProbe {
                traceTouchType = touch.type == .pencil ? "pencil" : touch.type == .direct ? "finger" : "other(\(touch.type.rawValue))"
            }
            return true
        }

        @objc private func traceTouch(_ probe: UILongPressGestureRecognizer) {
            guard let view, probe.state == .began || probe.state == .ended else { return }
            let p = probe.location(in: view)
            Trace.log("\(traceTouchType) \(probe.state == .began ? "down" : "up") at (\(Int(p.x)), \(Int(p.y)))")
        }

        // MARK: InkSurface

        var drawing: PKDrawing {
            get { view?.canvas.drawing ?? PKDrawing() }
            set { view?.canvas.drawing = newValue }
        }

        var visibleRect: CGRect {
            view?.visibleRect ?? .zero
        }

        func show(_ rect: CGRect, animated: Bool) {
            view?.show(rect, animated: animated)
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            store.canvasInkChanged(canvasView.drawing)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            store.penDown()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            store.penUp()
        }

        // The diagram layer does not live inside the scroll view, so it has to be told where to draw.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            view?.syncDiagramToViewport()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            view?.syncDiagramToViewport()
        }

        // MARK: Pencil double-tap

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            // Honour the system setting for people who have double-tap switched off.
            guard UIPencilInteraction.preferredTapAction != .ignore else { return }
            store.tool = store.tool == .eraser ? store.lastDrawingTool : .eraser
        }

        // MARK: Moving nodes with a finger

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, pan === view?.movePan, let view else { return true }
            // By the time a pan is recognised the finger has already travelled; test where it landed.
            movingNodeID = store.beginMove(at: view.worldPoint(moveStart))
            return movingNodeID != nil
        }

        @objc private func handleMove(_ pan: UIPanGestureRecognizer) {
            guard let view, let id = movingNodeID else { return }
            switch pan.state {
            case .began, .changed:
                let travelled = pan.translation(in: view)
                let zoom = view.canvas.zoomScale
                store.move(id, by: CGPoint(x: travelled.x / zoom, y: travelled.y / zoom))
                pan.setTranslation(.zero, in: view)
            case .ended, .cancelled, .failed:
                movingNodeID = nil
                store.endMove()
            default:
                break
            }
        }

        // MARK: Selecting a region to explain

        private var selectionStart: CGPoint = .zero

        @objc private func handleSelect(_ pan: UIPanGestureRecognizer) {
            guard let view else { return }
            let point = pan.location(in: view)
            switch pan.state {
            case .began, .changed:
                view.showSelection(CGRect(from: selectionStart, to: point))
            case .ended:
                view.showSelection(nil)
                let a = view.worldPoint(selectionStart)
                let b = view.worldPoint(point)
                let region = CGRect(from: a, to: b)
                // One selection per pick-up of the tool, then back to drawing.
                store.tool = store.lastDrawingTool
                // Ignore a stray tap or a sliver; it would only produce a useless note.
                if region.width * view.canvas.zoomScale > 24, region.height * view.canvas.zoomScale > 24 {
                    store.explain(region)
                }
            default:
                view.showSelection(nil)
            }
        }

        // MARK: Erasing shapes

        /// The tracker only watches; PencilKit's own recognizer must keep erasing ink alongside it.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            recognizer === view?.eraseTracker || other === view?.eraseTracker
                || recognizer === traceProbe || other === traceProbe
        }

        @objc private func handleErase(_ tracker: UILongPressGestureRecognizer) {
            guard let view else { return }
            // A second finger means a pan or pinch, not erasing.
            guard tracker.numberOfTouches <= 1 else { return }
            // The reach of the eraser stays the same on screen however far in or out the canvas is.
            let reach = 14 / view.canvas.zoomScale
            switch tracker.state {
            case .began:
                store.beginErasing()
                store.erase(at: view.worldPoint(tracker.location(in: view)), reach: reach)
            case .changed:
                store.erase(at: view.worldPoint(tracker.location(in: view)), reach: reach)
            default:
                break
            }
        }
    }
}

final class PadView: UIView {
    /// The canvas is a square this many points across. It is big enough to feel endless (about
    /// fifteen screens each way) while staying a size PencilKit handles comfortably.
    static let worldSide: CGFloat = 20000
    /// The middle of the canvas, where a new pad starts.
    static let worldCenter = CGPoint(x: worldSide / 2, y: worldSide / 2)

    let diagramView = DiagramView()
    let canvas = PKCanvasView()
    let movePan = UIPanGestureRecognizer()
    /// Follows the eraser's position, since PencilKit doesn't report where it is erasing.
    let eraseTracker = UILongPressGestureRecognizer()
    /// Drags out the box for the explain tool.
    let selectPan = UIPanGestureRecognizer()
    private let selectionLayer = CAShapeLayer()
    /// Called once, when the view first has a size and can be pointed at the content.
    var onFirstLayout: (() -> Void)?

    struct Configuration: Equatable {
        var tool: PadStore.Tool
        var penColor: InkColor
        var highlighterColor: InkColor
        var penWidth: Double
        var highlighterWidth: Double
        var fingerDraws: Bool
    }

    private var configuration: Configuration?
    private var hasLaidOut = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        addSubview(diagramView)

        // The ink layer is transparent, so the diagram shows through from below.
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // PKCanvasView is a scroll view, so panning and pinch-zooming come with it. Ink and diagram
        // share one coordinate space: points on this content area at zoom 1.
        canvas.contentSize = CGSize(width: Self.worldSide, height: Self.worldSide)
        canvas.minimumZoomScale = 0.1
        canvas.maximumZoomScale = 5
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.bouncesZoom = false
        addSubview(canvas)

        // One element for assistive technology, which passes touches straight through so drawing still works.
        isAccessibilityElement = true
        accessibilityIdentifier = "canvas"
        accessibilityLabel = "Canvas"
        accessibilityTraits = .allowsDirectInteraction

        movePan.maximumNumberOfTouches = 1
        movePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.addGestureRecognizer(movePan)
        // A finger that lands on a shape drags the shape; anywhere else it pans the canvas.
        canvas.panGestureRecognizer.require(toFail: movePan)

        // While the explain tool is up, one finger or the Pencil drags a selection box; two fingers
        // still pan. A disabled recognizer counts as failed, so this costs nothing otherwise.
        selectPan.maximumNumberOfTouches = 1
        selectPan.isEnabled = false
        canvas.addGestureRecognizer(selectPan)
        canvas.panGestureRecognizer.require(toFail: selectPan)
        selectionLayer.fillColor = UIColor.tintColor.withAlphaComponent(0.12).cgColor
        selectionLayer.strokeColor = UIColor.tintColor.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.lineDashPattern = [7, 5]
        layer.addSublayer(selectionLayer)

        // Zero press duration makes this a plain "where is the touch" tracker.
        eraseTracker.minimumPressDuration = 0
        eraseTracker.allowableMovement = .greatestFiniteMagnitude
        eraseTracker.cancelsTouchesInView = false
        eraseTracker.delaysTouchesEnded = false
        canvas.addGestureRecognizer(eraseTracker)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        diagramView.frame = bounds
        canvas.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !hasLaidOut {
            hasLaidOut = true
            show(CGRect(origin: Self.worldCenter, size: .zero), animated: false)
            onFirstLayout?()
        }
        syncDiagramToViewport()
    }

    // MARK: Viewport

    /// The part of the canvas on screen, in canvas points.
    var visibleRect: CGRect {
        let zoom = canvas.zoomScale
        return CGRect(
            x: canvas.contentOffset.x / zoom, y: canvas.contentOffset.y / zoom,
            width: bounds.width / zoom, height: bounds.height / zoom
        )
    }

    /// Converts a point in this view to canvas points.
    func worldPoint(_ point: CGPoint) -> CGPoint {
        let zoom = canvas.zoomScale
        return CGPoint(x: (point.x + canvas.contentOffset.x) / zoom, y: (point.y + canvas.contentOffset.y) / zoom)
    }

    /// Centres `rect` on screen, zooming out as far as needed to fit it but never zooming in past 100%.
    func show(_ rect: CGRect, animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let margin: CGFloat = 40
        let fit = min(bounds.width / (rect.width + margin * 2), bounds.height / (rect.height + margin * 2))
        let zoom = min(max(fit, canvas.minimumZoomScale), 1)
        let size = CGSize(width: bounds.width / zoom, height: bounds.height / zoom)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        canvas.zoom(to: target, animated: animated)
        syncDiagramToViewport()
    }

    /// Draws the selection box, in this view's coordinates, or removes it.
    func showSelection(_ rect: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = bounds
        selectionLayer.path = rect.map { UIBezierPath(roundedRect: $0, cornerRadius: 4).cgPath }
        CATransaction.commit()
    }

    func syncDiagramToViewport() {
        diagramView.setViewport(zoom: canvas.zoomScale, offset: canvas.contentOffset)
    }

    // MARK: Tools

    func configure(_ new: Configuration) {
        guard new != configuration else { return }
        configuration = new
        let tool = new.tool
        let fingerDraws = new.fingerDraws

        // With finger drawing on, one finger draws and two fingers pan and pinch. With it off, only
        // the Pencil draws, so one finger is free to pan the canvas and to drag shapes.
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        movePan.isEnabled = !fingerDraws && tool != .explain
        // The explain tool takes over the canvas: no ink while a box is being dragged.
        selectPan.isEnabled = tool == .explain
        canvas.drawingGestureRecognizer.isEnabled = tool != .explain
        // The eraser takes out shapes as well as ink, with whatever is allowed to draw.
        eraseTracker.isEnabled = tool == .eraser
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        eraseTracker.allowedTouchTypes = fingerDraws ? [pencil, finger] : [pencil]

        switch tool {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: new.penColor.uiColor, width: new.penWidth)
        case .highlighter:
            // The marker ink is translucent, so what is underneath stays readable.
            canvas.tool = PKInkingTool(.marker, color: new.highlighterColor.uiColor, width: new.highlighterWidth)
        case .eraser:
            canvas.tool = PKEraserTool(.vector)
        case .explain:
            break
        }
    }
}

/// Paints the clean diagram beneath the ink, following the canvas as it pans and zooms.
final class DiagramView: UIView {
    var diagram = Diagram() {
        didSet {
            if diagram != oldValue { setNeedsDisplay() }
        }
    }

    var document: PadDocument? {
        didSet {
            if document != oldValue {
                pageImages.removeAllObjects()
                setNeedsDisplay()
            }
        }
    }

    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero
    /// Pictures of pages, drawn once and reused while panning and zooming.
    private let pageImages: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        cache.countLimit = 8
        return cache
    }()

    /// A picture of the page at twice its natural size, which stays sharp up to 200% zoom.
    private func pageImage(_ index: Int) -> UIImage? {
        if let image = pageImages.object(forKey: NSNumber(value: index)) { return image }
        guard let document, let page = document.pdf.page(at: index + 1) else { return nil }
        let size = document.frames[index].size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            DiagramRenderer.draw(page, in: CGRect(origin: .zero, size: size), context: context.cgContext)
        }
        pageImages.setObject(image, forKey: NSNumber(value: index))
        return image
    }

    func setViewport(zoom: CGFloat, offset: CGPoint) {
        guard zoom != self.zoom || offset != self.offset else { return }
        self.zoom = zoom
        self.offset = offset
        setNeedsDisplay()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DiagramView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.translateBy(x: -offset.x, y: -offset.y)
        context.scaleBy(x: zoom, y: zoom)
        let visible = CGRect(
            x: offset.x / zoom, y: offset.y / zoom,
            width: bounds.width / zoom, height: bounds.height / zoom
        )
        if let document {
            // Past 200% the picture would blur, so draw the page itself; few are in view by then.
            let usePictures = zoom <= 2
            DiagramRenderer.drawPages(of: document, in: context, visible: visible) { [unowned self] index in
                usePictures ? pageImage(index) : nil
            }
        }
        DiagramRenderer.draw(diagram, visible: visible)
    }
}

extension CGRect {
    /// The rectangle with these two points as opposite corners.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
