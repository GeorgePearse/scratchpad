import PencilKit
import ScratchKit
import SwiftUI
import UIKit

/// The drawing surface: clean diagram underneath, live PencilKit ink on top.
struct PadCanvas: UIViewRepresentable {
    let store: PadStore
    // Passed in as plain values so SwiftUI calls `updateUIView` whenever they change.
    let diagram: Diagram
    let summary: String
    let tool: PadStore.Tool
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
        view.accessibilityValue = summary
        view.configure(tool: tool, fingerDraws: fingerDraws)
    }

    @MainActor
    final class Coordinator: NSObject, InkSurface, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        private let store: PadStore
        private weak var view: PadView?
        private var movingNodeID: String?

        init(store: PadStore) {
            self.store = store
        }

        func attach(to view: PadView) {
            self.view = view
            view.canvas.delegate = self
            view.onResize = { [store] size in store.canvasSize = size }

            view.movePan.addTarget(self, action: #selector(handleMove))
            view.movePan.delegate = self
            view.eraseTracker.addTarget(self, action: #selector(handleErase))
            view.eraseTracker.delegate = self
            view.canvas.addInteraction(UIPencilInteraction(delegate: self))

            store.ink = self
        }

        // MARK: InkSurface

        var drawing: PKDrawing {
            get { view?.canvas.drawing ?? PKDrawing() }
            set { view?.canvas.drawing = newValue }
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

        // MARK: Pencil double-tap

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            // Honour the system setting for people who have double-tap switched off.
            guard UIPencilInteraction.preferredTapAction != .ignore else { return }
            store.tool = store.tool == .pen ? .eraser : .pen
        }

        // MARK: Moving nodes with a finger

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, pan === view?.movePan, let view else { return true }
            // By the time a pan is recognised the finger has already travelled; test where it started.
            let location = pan.location(in: view)
            let travelled = pan.translation(in: view)
            let start = CGPoint(x: location.x - travelled.x, y: location.y - travelled.y)
            movingNodeID = store.beginMove(at: start)
            return movingNodeID != nil
        }

        // MARK: Erasing shapes

        /// The tracker only watches; PencilKit's own recognizer must keep erasing ink alongside it.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            recognizer === view?.eraseTracker || other === view?.eraseTracker
        }

        @objc private func handleErase(_ tracker: UILongPressGestureRecognizer) {
            guard let view else { return }
            switch tracker.state {
            case .began:
                store.beginErasing()
                store.erase(at: tracker.location(in: view))
            case .changed:
                store.erase(at: tracker.location(in: view))
            default:
                break
            }
        }

        @objc private func handleMove(_ pan: UIPanGestureRecognizer) {
            guard let view, let id = movingNodeID else { return }
            switch pan.state {
            case .began, .changed:
                store.move(id, by: pan.translation(in: view))
                pan.setTranslation(.zero, in: view)
            case .ended, .cancelled, .failed:
                movingNodeID = nil
                store.endMove()
            default:
                break
            }
        }
    }
}

final class PadView: UIView {
    let diagramView = DiagramView()
    let canvas = PKCanvasView()
    let movePan = UIPanGestureRecognizer()
    /// Follows the eraser's position, since PencilKit doesn't report where it is erasing.
    let eraseTracker = UILongPressGestureRecognizer()
    var onResize: ((CGSize) -> Void)?

    private var configuration: (tool: PadStore.Tool, fingerDraws: Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        addSubview(diagramView)

        // The ink layer is transparent, so the diagram shows through from below.
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // One fixed page the size of the screen: no scrolling, no zoom, no inset surprises,
        // which keeps ink coordinates and diagram coordinates the same thing.
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        addSubview(canvas)

        // One element for assistive technology, which passes touches straight through so drawing still works.
        isAccessibilityElement = true
        accessibilityIdentifier = "canvas"
        accessibilityLabel = "Canvas"
        accessibilityTraits = .allowsDirectInteraction

        movePan.maximumNumberOfTouches = 1
        movePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.addGestureRecognizer(movePan)

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
        canvas.contentSize = bounds.size
        onResize?(bounds.size)
    }

    func configure(tool: PadStore.Tool, fingerDraws: Bool) {
        if let configuration, configuration == (tool, fingerDraws) { return }
        configuration = (tool, fingerDraws)

        // Pencil-first: the Pencil draws and a finger moves shapes. With finger drawing on, a finger
        // draws too, so it can no longer be used to move things.
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        movePan.isEnabled = !fingerDraws
        // The eraser takes out shapes as well as ink, with whatever is allowed to draw.
        eraseTracker.isEnabled = tool == .eraser
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        eraseTracker.allowedTouchTypes = fingerDraws ? [pencil, finger] : [pencil]

        switch tool {
        case .pen:
            // Black adapts by itself: PencilKit shows it as white ink in Dark Mode.
            canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        case .eraser:
            canvas.tool = PKEraserTool(.vector)
        }
    }
}

/// Paints the clean diagram beneath the ink.
final class DiagramView: UIView {
    var diagram = Diagram() {
        didSet {
            if diagram != oldValue { setNeedsDisplay() }
        }
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
        DiagramRenderer.draw(diagram)
    }
}
