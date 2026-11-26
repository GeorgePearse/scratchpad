import Foundation
import Observation
import PencilKit
import ScratchKit
import UIKit

/// The store's handle on the live ink, which is owned by the PKCanvasView.
@MainActor
protocol InkSurface: AnyObject {
    var drawing: PKDrawing { get set }
    /// The part of the canvas on screen, in canvas points.
    var visibleRect: CGRect { get }
    /// Scrolls and zooms so that `rect` is centred and fully in view.
    func show(_ rect: CGRect, animated: Bool)
}

/// Everything on the pad: the clean diagram, the ink, undo history, and the model loop that edits them.
@MainActor
@Observable
final class PadStore {
    enum Tool {
        case pen, highlighter, eraser
        /// Drag a box around part of the canvas to have it explained.
        case explain
    }

    /// The pen or highlighter used most recently, which is what Pencil double-tap returns to.
    @ObservationIgnored private(set) var lastDrawingTool: Tool = .pen

    private(set) var diagram = Diagram()
    /// A PDF shown on the canvas beneath the diagram and the ink, if one has been imported.
    private(set) var document: PadDocument?
    private(set) var strokeCount = 0
    private(set) var canUndo = false
    var tool: Tool = .pen {
        didSet {
            if tool == .pen || tool == .highlighter { lastDrawingTool = tool }
            Trace.log("tool is now \(tool)")
        }
    }
    /// Stands in for the configured Claude model. The demo and the UI tests set this.
    var modelOverride: (any DiagramModel)?
    /// Stands in for Claude when explaining a selection. The demo and the UI tests set this.
    @ObservationIgnored var explainerOverride: (any RegionExplainer)?

    let id: UUID
    let settings: PadSettings
    /// Where this pad keeps its `pad.json` and `document.pdf`.
    @ObservationIgnored private let folder: URL
    let loop = ModelLoop()

    /// The part of the canvas on screen, in canvas points. Empty until the canvas has laid out.
    var viewport: CGRect { ink?.visibleRect ?? .zero }
    /// The canvas view, once it exists. Until then the store's own copy of the ink stands in.
    @ObservationIgnored weak var ink: (any InkSurface)? {
        didSet { ink?.drawing = drawing }
    }
    /// Off in the scripted demo, so it never overwrites a real pad.
    @ObservationIgnored var persists = true

    @ObservationIgnored private var drawing = PKDrawing()
    @ObservationIgnored private var history: [(diagram: Diagram, drawing: PKDrawing)] = []
    @ObservationIgnored private var penIsDown = false
    @ObservationIgnored private var eraseIsRecorded = false
    @ObservationIgnored private var deferredWork: [() -> Void] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var isBlank: Bool { diagram.isEmpty && strokeCount == 0 && document == nil }

    /// True when the loop has nothing to run on until the user supplies a key.
    var needsAPIKey: Bool { modelOverride == nil && settings.apiKey.isEmpty }

    /// What is on the canvas, in words. This is the canvas's accessibility value.
    var summary: String {
        guard !isBlank else { return "Empty" }
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return [
            count(diagram.nodes.count, "shape"),
            count(diagram.edges.count, "connector"),
            count(strokeCount, "ink stroke"),
        ].joined(separator: ", ")
    }

    init(id: UUID, folder: URL, settings: PadSettings) {
        self.id = id
        self.folder = folder
        self.settings = settings
        load()
        loop.timing = { [settings] in
            ModelLoop.Timing(settle: .seconds(settings.settleSeconds))
        }
        loop.makeModel = { [weak self, settings] in
            if let override = self?.modelOverride { return override }
            guard !settings.apiKey.isEmpty else { return nil }
            return ClaudeModel(apiKey: settings.apiKey, model: settings.modelID, effort: settings.effort)
        }
        loop.capture = { [weak self] in self?.makeJob() }
        // Ink left over from last time has already been looked at, so wait for a fresh stroke.
        loop.setEnabled(settings.loopEnabled, lookNow: false)
    }

    func setLoopEnabled(_ enabled: Bool) {
        settings.loopEnabled = enabled
        loop.setEnabled(enabled)
    }

    // MARK: Ink, as changed by the user

    /// The canvas reports a new drawing. Echoes of our own programmatic changes are ignored.
    func canvasInkChanged(_ new: PKDrawing) {
        guard new != drawing else { return }
        Trace.log("ink changed: \(drawing.strokes.count) -> \(new.strokes.count) strokes")
        pushHistory()
        drawing = new
        strokeCount = new.strokes.count
        loop.noteChange()
        scheduleSave()
    }

    func penDown() {
        Trace.log("tool down (\(tool))")
        penIsDown = true
        loop.penDown()
    }

    func penUp() {
        Trace.log("tool up")
        penIsDown = false
        loop.penUp()
        // PencilKit commits the finished stroke just after this callback; let it land before touching the ink.
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            flushDeferredWork()
        }
    }

    // MARK: Direct manipulation

    /// Starts dragging the node under `point`, if there is one.
    func beginMove(at point: CGPoint) -> String? {
        guard let node = diagram.node(at: point, slop: 10) else { return nil }
        pushHistory()
        return node.id
    }

    func move(_ id: String, by delta: CGPoint) {
        guard let index = diagram.nodes.firstIndex(where: { $0.id == id }) else { return }
        var frame = diagram.nodes[index].frame.offsetBy(dx: delta.x, dy: delta.y)
        // Keep the centre on the canvas, so a node can't be dragged off the edge of the world.
        frame.origin.x = min(max(frame.origin.x, -frame.width / 2), PadView.worldSide - frame.width / 2)
        frame.origin.y = min(max(frame.origin.y, -frame.height / 2), PadView.worldSide - frame.height / 2)
        diagram.nodes[index].frame = frame
    }

    func endMove() {
        scheduleSave()
    }

    // MARK: Explaining a selection

    /// Has the model explain what is inside `region` and pastes the answer onto the canvas beside it.
    func explain(_ region: CGRect) {
        // The note goes to the right of the selection, level with its top.
        let id = diagram.freeIDs(prefix: "x", count: 1)[0]
        let origin = CGPoint(x: region.maxX + 28, y: region.minY)
        pushHistory()
        setNote(id, at: origin, lines: ["Explaining…"], color: .gray)

        guard let snapshot = CanvasSnapshot.make(diagram: diagram.part(in: region), drawing: currentDrawing(),
                                                 document: document, rect: region, tags: false) else {
            setNote(id, at: origin, lines: ["That selection was too small to read."], color: .red)
            return
        }
        let explainer: (any RegionExplainer)?
        if let explainerOverride {
            explainer = explainerOverride
        } else if settings.apiKey.isEmpty {
            explainer = nil
        } else {
            explainer = ClaudeExplainer(apiKey: settings.apiKey, model: settings.modelID, effort: settings.effort)
        }
        guard let explainer else {
            setNote(id, at: origin, lines: ["Add an API key in settings to get explanations."], color: .red)
            return
        }

        Task {
            do {
                let text = try await explainer.explain(imagePNG: snapshot.png)
                setNote(id, at: origin, lines: TextLayout.wrap(text, width: 62), color: .standard)
            } catch {
                let reason = TextLayout.wrap("Couldn't explain this. \(error.localizedDescription)", width: 62)
                setNote(id, at: origin, lines: reason, color: .red)
            }
            scheduleSave()
        }
    }

    /// Creates or rewrites a note: free text, one line of type per entry.
    private func setNote(_ id: String, at origin: CGPoint, lines: [String], color: NodeColor) {
        let lineHeight: CGFloat = 23
        let width = CGFloat(lines.map(\.count).max() ?? 1) * 7.6
        let node = Node(id: id, shape: .text,
                        frame: CGRect(origin: origin, size: CGSize(width: width, height: lineHeight * CGFloat(max(lines.count, 1)))),
                        label: lines.joined(separator: "\n"), color: color)
        if let index = diagram.nodes.firstIndex(where: { $0.id == id }) {
            diagram.nodes[index] = node
        } else if lines == ["Explaining…"] {
            diagram.nodes.append(node)
        }
        // If the placeholder is gone, the user undid or erased it while waiting: leave it gone.
    }

    // MARK: Erasing clean elements

    /// The eraser has touched down. PencilKit removes the ink it crosses; this handles shapes.
    func beginErasing() {
        eraseIsRecorded = false
    }

    /// Removes the shape or connector whose line is within `reach` of the eraser at `point`.
    func erase(at point: CGPoint, reach: CGFloat) {
        guard let id = diagram.elementID(touchedAt: point, tolerance: reach) else { return }
        Trace.log("eraser removed \(id)")
        // One undo step per sweep of the eraser, however many things it takes out.
        if !eraseIsRecorded {
            pushHistory()
            eraseIsRecorded = true
        }
        diagram.remove(id)
        scheduleSave()
    }

    // MARK: Whole-pad actions

    // MARK: Document

    /// Copies a PDF into the app and lays its pages out on the canvas, clear of what is already there.
    func importDocument(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let destination = documentURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        document = nil
        placeDocument(at: nil)
        saveNow()
        if let document { ink?.show(document.frames.first ?? document.bounds, animated: true) }
    }

    func removeDocument() {
        document = nil
        try? FileManager.default.removeItem(at: documentURL)
        saveNow()
    }

    /// Loads the stored PDF. With no saved position it goes to the right of the existing content,
    /// or to the middle of an empty canvas.
    private func placeDocument(at saved: CGPoint?) {
        let url = documentURL
        guard FileManager.default.fileExists(atPath: url.path), let size = PadDocument.size(of: url) else { return }
        var topLeft = saved ?? CGPoint(x: PadView.worldCenter.x - size.width / 2, y: PadView.worldCenter.y - 500)
        if saved == nil, let content = contentBounds(includingDocument: false) {
            topLeft = CGPoint(x: content.maxX + 500, y: content.minY)
        }
        document = PadDocument(url: url, topLeft: topLeft)
    }

    private func contentBounds(includingDocument: Bool) -> CGRect? {
        var bounds = diagram.bounds ?? .null
        let inkBounds = currentDrawing().bounds
        if !inkBounds.isNull, !inkBounds.isEmpty { bounds = bounds.union(inkBounds) }
        if includingDocument, let document { bounds = bounds.union(document.bounds) }
        return bounds.isNull ? nil : bounds
    }

    /// Brings everything on the pad into view. Does nothing on a blank pad.
    func showContent(animated: Bool = true) {
        if let bounds = contentBounds(includingDocument: true) { ink?.show(bounds, animated: animated) }
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        canUndo = !history.isEmpty
        diagram = previous.diagram
        setDrawing(previous.drawing)
        scheduleSave()
    }

    func clear() {
        guard !diagram.isEmpty || strokeCount > 0 else { return }
        pushHistory()
        diagram = Diagram()
        setDrawing(PKDrawing())
        scheduleSave()
    }

    /// Empties the pad and forgets its history, as if newly installed. Used by the scripted demo.
    func startFresh() {
        diagram = Diagram()
        setDrawing(PKDrawing())
        history = []
        canUndo = false
    }

    /// Adds strokes as though the user had just drawn them. Used by the scripted demo.
    func userDrew(_ strokes: [PKStroke]) {
        pushHistory()
        var drawing = currentDrawing()
        drawing.strokes.append(contentsOf: strokes)
        setDrawing(drawing)
        loop.noteChange()
    }

    // MARK: Model passes

    private func makeJob() -> ModelLoop.Job? {
        let drawing = currentDrawing()
        // Ink is how the user addresses the model, so with no ink there is nothing to answer.
        // The model sees what the user sees: the visible part of the canvas, at whatever zoom.
        let view = viewport
        let inView = diagram.part(in: view)
        guard drawing.strokes.contains(where: { $0.renderBounds.intersects(view) }),
              let snapshot = CanvasSnapshot.make(diagram: inView, drawing: drawing, document: document, rect: view) else { return nil }

        // What the model is answering. By the time it replies, the canvas may have moved on.
        let base = diagram
        let strokesSeen = Set(drawing.strokes.map(\.path.creationDate))

        let input = ModelInput(
            imagePNG: snapshot.png,
            imageSize: snapshot.pixelSize,
            diagram: inView.applying(snapshot.toImage),
            instructions: settings.instructions,
            // New ids must be unused across the whole canvas, not just the part in view.
            unusedIDs: (diagram.freeIDs(prefix: "n", count: 6), diagram.freeIDs(prefix: "e", count: 6))
        )
        return ModelLoop.Job(input: input) { [weak self] output in
            guard let self else { return }
            let ops = output.ops.map { $0.applying(snapshot.toImage.inverted()) }
            whenPenIsUp { self.apply(ops, base: base, strokesSeen: strokesSeen) }
        }
    }

    private func apply(_ ops: [EditOp], base: Diagram, strokesSeen: Set<Date>) {
        let result = diagram.merging(ops, base: base)
        Trace.log("model replied with \(ops.count) ops, \(result.appliedCount) applied")

        var drawing = currentDrawing()
        let strokeCount = drawing.strokes.count
        if !result.eraseRegions.isEmpty {
            // Only strokes the model actually saw can be erased; anything drawn since is safe.
            drawing.strokes.removeAll { stroke in
                strokesSeen.contains(stroke.path.creationDate)
                    && InkErasure.covers(strokeBounds: stroke.renderBounds, regions: result.eraseRegions)
            }
        }
        let inkChanged = drawing.strokes.count != strokeCount
        guard inkChanged || result.diagram != diagram else { return }

        pushHistory()
        diagram = result.diagram
        if inkChanged { setDrawing(drawing) }
        scheduleSave()
    }

    /// Changing the canvas's drawing mid-stroke would fight PencilKit, so edits wait for the pencil to lift.
    private func whenPenIsUp(_ work: @escaping () -> Void) {
        if penIsDown {
            deferredWork.append(work)
        } else {
            work()
        }
    }

    private func flushDeferredWork() {
        guard !penIsDown, !deferredWork.isEmpty else { return }
        let work = deferredWork
        deferredWork = []
        work.forEach { $0() }
    }

    // MARK: Ink plumbing

    private func currentDrawing() -> PKDrawing {
        ink?.drawing ?? drawing
    }

    private func setDrawing(_ new: PKDrawing) {
        drawing = new
        strokeCount = new.strokes.count
        ink?.drawing = new
    }

    /// Records the state before a change. This must be the store's own copy of the ink, not the
    /// canvas's: when the canvas reports a new stroke, its drawing already contains that stroke.
    private func pushHistory() {
        history.append((diagram, drawing))
        if history.count > 200 { history.removeFirst(history.count - 200) }
        canUndo = true
    }

    // MARK: Persistence

    private struct SavedPad: Codable {
        var diagram: Diagram
        var drawing: Data
        /// 2 since the canvas became pannable. Files without it were drawn on a fixed page whose
        /// top-left corner was the origin.
        var version: Int?
        /// Top-left corner of the imported PDF's first page, if there is one.
        var documentOrigin: CGPoint?
        /// Rectangles whose ink should be removed when the pad is next opened. A tool that edits
        /// a pad file from outside the app sets this, because only the app can rewrite the ink.
        /// It is applied once and never written back.
        var eraseInk: [CGRect]?
    }

    private var documentURL: URL {
        folder.appending(path: "document.pdf")
    }

    private var fileURL: URL {
        folder.appending(path: "pad.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(SavedPad.self, from: data) else {
            placeDocument(at: nil)
            return
        }
        diagram = saved.diagram
        drawing = (try? PKDrawing(data: saved.drawing)) ?? PKDrawing()
        if saved.version == nil {
            // Move a fixed-page pad to the middle of the big canvas, so there is room on every side.
            let shift = CGAffineTransform(translationX: PadView.worldCenter.x, y: PadView.worldCenter.y)
            diagram = diagram.applying(shift)
            drawing = drawing.transformed(using: shift)
        }
        if let regions = saved.eraseInk, !regions.isEmpty {
            drawing.strokes.removeAll { stroke in regions.contains { $0.contains(stroke.renderBounds) } }
            scheduleSave()
        }
        strokeCount = drawing.strokes.count
        placeDocument(at: saved.documentOrigin)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard persists else { return }
        let saved = SavedPad(diagram: diagram, drawing: currentDrawing().dataRepresentation(), version: 2,
                             documentOrigin: document?.frames.first?.origin)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
