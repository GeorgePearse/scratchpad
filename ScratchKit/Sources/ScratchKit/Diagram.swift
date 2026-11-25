import CoreGraphics
import Foundation

/// A named colour a node can be drawn in. `standard` follows the canvas ink colour.
public enum NodeColor: String, Codable, CaseIterable, Sendable {
    case standard = "default"
    case red, orange, green, blue, purple, gray
}

/// A clean shape or free-standing piece of text on the canvas.
public struct Node: Identifiable, Codable, Equatable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable {
        case rect, rounded, ellipse, diamond, text
    }

    public var id: String
    public var shape: Shape
    public var frame: CGRect
    public var label: String
    public var color: NodeColor

    public init(id: String, shape: Shape, frame: CGRect, label: String = "", color: NodeColor = .standard) {
        self.id = id
        self.shape = shape
        self.frame = frame
        self.label = label
        self.color = color
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// A connector between two nodes. Its geometry is derived from the nodes, so it follows them when they move.
public struct Edge: Identifiable, Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// Solid line with an arrowhead at `to`.
        case arrow
        /// Solid line, no arrowhead.
        case line
        /// Dashed line with an arrowhead at `to`.
        case dashed
    }

    public var id: String
    public var from: String
    public var to: String
    public var label: String
    public var style: Style

    public init(id: String, from: String, to: String, label: String = "", style: Style = .arrow) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.style = style
    }
}

/// The structured half of the canvas: everything that is not freehand ink.
public struct Diagram: Codable, Equatable, Sendable {
    public var nodes: [Node]
    public var edges: [Edge]

    public init(nodes: [Node] = [], edges: [Edge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    public var isEmpty: Bool { nodes.isEmpty && edges.isEmpty }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    public func edge(_ id: String) -> Edge? { edges.first { $0.id == id } }

    /// The topmost node under `point`, with `slop` points of forgiveness around its frame.
    public func node(at point: CGPoint, slop: CGFloat = 0) -> Node? {
        nodes.last { $0.frame.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    /// The id of the element whose drawn line passes under `point`: a node's outline or an edge.
    /// This is what an eraser hits, so the inside of a shape is deliberately not a hit.
    public func elementID(touchedAt point: CGPoint, tolerance: CGFloat) -> String? {
        if let node = nodes.last(where: { Geometry.outline(of: $0, isTouchedAt: point, tolerance: tolerance) }) {
            return node.id
        }
        return edges.last { edge in
            guard let from = node(edge.from), let to = node(edge.to),
                  let segment = Geometry.segment(from: from, to: to) else { return false }
            return Geometry.distance(from: point, toSegment: segment.start, segment.end) <= tolerance
        }?.id
    }

    /// Removes a node (with its edges) or an edge. Returns false if there is no such element.
    @discardableResult
    public mutating func remove(_ id: String) -> Bool {
        if nodes.contains(where: { $0.id == id }) {
            nodes.removeAll { $0.id == id }
            edges.removeAll { $0.from == id || $0.to == id }
            return true
        }
        guard edges.contains(where: { $0.id == id }) else { return false }
        edges.removeAll { $0.id == id }
        return true
    }

    /// The same diagram in another coordinate space (canvas points <-> model image pixels).
    /// The transform is expected to be a scale and translation.
    public func applying(_ transform: CGAffineTransform) -> Diagram {
        var copy = self
        copy.nodes = nodes.map { node in
            var node = node
            node.frame = node.frame.applying(transform)
            return node
        }
        return copy
    }

    public func scaled(by factor: CGFloat) -> Diagram {
        applying(CGAffineTransform(scaleX: factor, y: factor))
    }

    /// The nodes that overlap `rect`, with the edges that join two of them: what a view of that
    /// rectangle shows.
    public func part(in rect: CGRect) -> Diagram {
        let kept = nodes.filter { $0.frame.intersects(rect) }
        let ids = Set(kept.map(\.id))
        return Diagram(nodes: kept, edges: edges.filter { ids.contains($0.from) && ids.contains($0.to) })
    }

    /// The smallest rectangle containing every node, or nil for an empty diagram.
    public var bounds: CGRect? {
        nodes.isEmpty ? nil : nodes.reduce(CGRect.null) { $0.union($1.frame) }
    }

    /// Ids of the form `<prefix><n>` that are not in use yet, lowest first.
    public func freeIDs(prefix: String, count: Int) -> [String] {
        let used = Set(nodes.map(\.id) + edges.map(\.id))
        var result: [String] = []
        var n = 1
        while result.count < count {
            let candidate = "\(prefix)\(n)"
            if !used.contains(candidate) { result.append(candidate) }
            n += 1
        }
        return result
    }
}

