#if DEBUG
import PencilKit
import ScratchKit
import UIKit

/// Debug launch arguments for running the pad with no Pencil and no API key.
///
/// - `-cannedModel YES` starts from a blank, unsaved pad and swaps the Claude model for a canned one
///   that answers its first two passes with fixed edits. The UI tests draw against this.
/// - `-demo YES` does the same and also draws the ink itself, playing a short scripted session.
///
/// Either way the whole pipeline runs for real (ink in, snapshot, pass, merge, ink erased, diagram
/// drawn), and each snapshot the "model" receives is saved to the app's Documents folder as
/// `pass-N.png`, so you can see exactly what a real model would be shown.
@MainActor
enum DemoScript {
    static func runIfRequested(on store: PadStore) async {
        let scripted = UserDefaults.standard.bool(forKey: "demo")
        guard scripted || UserDefaults.standard.bool(forKey: "cannedModel") else { return }

        store.persists = false
        store.clear()
        store.modelOverride = CannedModel()
        store.loop.timing = { ModelLoop.Timing(settle: .milliseconds(300)) }
        store.loop.setEnabled(true)
        store.loop.retry()

        guard scripted else { return }
        while store.canvasSize == .zero {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let size = store.canvasSize

        // First the user sketches two shapes and joins them.
        store.userDrew(Sketch.box(Layout.a.in(size)) + Sketch.oval(Layout.b.in(size))
            + Sketch.arrow(from: Layout.arrow1.from.in(size), to: Layout.arrow1.to.in(size)))
        await wait { store.diagram.nodes.count == 2 }
        try? await Task.sleep(for: .seconds(1))

        // Then adds a third, plus a doodle the model should leave alone.
        store.userDrew(Sketch.diamond(Layout.c.in(size))
            + Sketch.arrow(from: Layout.arrow2.from.in(size), to: Layout.arrow2.to.in(size))
            + Sketch.squiggle(Layout.doodle.in(size)))
        await wait { store.diagram.nodes.count == 3 }
    }

    private static func wait(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Where things go, as fractions of the canvas, shared by the fake ink and the fake model.
private enum Layout {
    static let a = CGRect(x: 0.10, y: 0.24, width: 0.20, height: 0.16)
    static let b = CGRect(x: 0.46, y: 0.22, width: 0.22, height: 0.20)
    static let c = CGRect(x: 0.47, y: 0.60, width: 0.20, height: 0.24)
    static let arrow1 = (from: CGPoint(x: 0.31, y: 0.32), to: CGPoint(x: 0.45, y: 0.32))
    static let arrow2 = (from: CGPoint(x: 0.57, y: 0.435), to: CGPoint(x: 0.57, y: 0.585))
    static let doodle = CGRect(x: 0.10, y: 0.74, width: 0.20, height: 0.05)
}

private extension CGRect {
    func `in`(_ size: CGSize) -> CGRect {
        CGRect(x: minX * size.width, y: minY * size.height, width: width * size.width, height: height * size.height)
    }
}

private extension CGPoint {
    func `in`(_ size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}

/// Answers the two passes of the script the way a real model should.
private actor CannedModel: DiagramModel {
    private var pass = 0

    func edit(_ input: ModelInput) async throws -> ModelOutput {
        pass += 1
        let documents = URL.documentsDirectory
        try? input.imagePNG.write(to: documents.appending(path: "pass-\(pass).png"))
        try? Data(Prompt.userText(for: input).utf8).write(to: documents.appending(path: "pass-\(pass).txt"))
        try await Task.sleep(for: .milliseconds(600))

        let size = input.imageSize
        func around(_ from: CGPoint, _ to: CGPoint) -> CGRect {
            CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
                .in(size).insetBy(dx: -24, dy: -24)
        }
        // `-demoFailure YES` makes the second pass fail, to show how an outage looks.
        if pass == 2, UserDefaults.standard.bool(forKey: "demoFailure") {
            throw ModelError.unavailable(message: "Overloaded. The service is busy; this pass will be retried shortly.", retryAfter: .seconds(60))
        }
        switch pass {
        case 1:
            return ModelOutput(ops: [
                .node(Node(id: "n1", shape: .rect, frame: Layout.a.in(size), label: "Pencil stroke")),
                .node(Node(id: "n2", shape: .ellipse, frame: Layout.b.in(size), label: "Model pass")),
                .edge(Edge(id: "e1", from: "n1", to: "n2", label: "snapshot")),
                .erase(Layout.a.in(size).insetBy(dx: -10, dy: -10)),
                .erase(Layout.b.in(size).insetBy(dx: -10, dy: -10)),
                .erase(around(Layout.arrow1.from, Layout.arrow1.to)),
            ])
        case 2:
            return ModelOutput(ops: [
                .node(Node(id: "n3", shape: .diamond, frame: Layout.c.in(size), label: "Edits?", color: .blue)),
                .edge(Edge(id: "e2", from: "n2", to: "n3", label: "ops", style: .dashed)),
                .erase(Layout.c.in(size).insetBy(dx: -10, dy: -10)),
                .erase(around(Layout.arrow2.from, Layout.arrow2.to)),
            ])
        default:
            return ModelOutput(ops: [])
        }
    }
}

/// Hand-drawn-looking strokes, wobble included.
@MainActor
private enum Sketch {
    private static var clock = Date()

    static func box(_ r: CGRect) -> [PKStroke] {
        let corners = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY - 6),
        ]
        return [stroke(polyline(corners))]
    }

    static func diamond(_ r: CGRect) -> [PKStroke] {
        let corners = [
            CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.midX + 5, y: r.minY),
        ]
        return [stroke(polyline(corners))]
    }

    static func oval(_ r: CGRect) -> [PKStroke] {
        let points = stride(from: 0.0, through: 2 * Double.pi + 0.25, by: 0.08).map { angle in
            CGPoint(x: r.midX + cos(angle - 1.2) * r.width / 2, y: r.midY + sin(angle - 1.2) * r.height / 2)
        }
        return [stroke(points)]
    }

    static func arrow(from: CGPoint, to: CGPoint) -> [PKStroke] {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        let ux = dx / length
        let uy = dy / length
        func barb(_ side: CGFloat) -> CGPoint {
            CGPoint(x: to.x - ux * 18 - uy * 11 * side, y: to.y - uy * 18 + ux * 11 * side)
        }
        return [stroke(polyline([from, to])), stroke(polyline([barb(1), to, barb(-1)]))]
    }

    static func squiggle(_ r: CGRect) -> [PKStroke] {
        let points = stride(from: 0.0, through: 1.0, by: 0.02).map { t in
            CGPoint(x: r.minX + r.width * t, y: r.midY + sin(t * 28) * r.height / 2)
        }
        return [stroke(points)]
    }

    /// Points every few pixels along the corners' path, so the wobble has something to act on.
    private static func polyline(_ corners: [CGPoint]) -> [CGPoint] {
        var points: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = max(Int(hypot(b.x - a.x, b.y - a.y) / 6), 1)
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let last = corners.last { points.append(last) }
        return points
    }

    private static func stroke(_ points: [CGPoint]) -> PKStroke {
        // Each stroke needs its own creation date: that is how the pad tells strokes apart.
        clock.addTimeInterval(1)
        let controlPoints = points.enumerated().map { index, point in
            let wobble = CGPoint(x: sin(Double(index) * 0.9) * 1.6, y: cos(Double(index) * 0.7) * 1.6)
            return PKStrokePoint(
                location: CGPoint(x: point.x + wobble.x, y: point.y + wobble.y),
                timeOffset: Double(index) * 0.008,
                size: CGSize(width: 4, height: 4),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: controlPoints, creationDate: clock))
    }
}
#endif
