import CoreGraphics
import Foundation

/// One edit a model asks for. This is the whole vocabulary a model has for changing the canvas.
public enum EditOp: Equatable, Sendable {
    /// Create the node, or replace the node that has this id.
    case node(Node)
    /// Create the edge, or replace the edge that has this id.
    case edge(Edge)
    /// Remove the node or edge with this id. Removing a node removes its edges.
    case delete(id: String)
    /// Remove the freehand ink that lies inside this rectangle. Never touches nodes or edges.
    case erase(CGRect)

    /// The same op in another coordinate space. The transform is expected to be a scale and translation.
    public func applying(_ transform: CGAffineTransform) -> EditOp {
        switch self {
        case .node(var node):
            node.frame = node.frame.applying(transform)
            return .node(node)
        case .erase(let rect):
            return .erase(rect.applying(transform))
        case .edge, .delete:
            return self
        }
    }

    public func scaled(by factor: CGFloat) -> EditOp {
        applying(CGAffineTransform(scaleX: factor, y: factor))
    }
}

extension EditOp: Decodable {
    private enum CodingKeys: String, CodingKey {
        case op, id, shape, x, y, w, h, label, color, from, to, style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .op)
        switch kind {
        case "node":
            self = .node(Node(
                id: try c.decode(String.self, forKey: .id),
                shape: try c.decode(Node.Shape.self, forKey: .shape),
                frame: try Self.rect(from: c),
                label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
                color: try c.decodeIfPresent(NodeColor.self, forKey: .color) ?? .standard
            ))
        case "edge":
            self = .edge(Edge(
                id: try c.decode(String.self, forKey: .id),
                from: try c.decode(String.self, forKey: .from),
                to: try c.decode(String.self, forKey: .to),
                label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
                style: try c.decodeIfPresent(Edge.Style.self, forKey: .style) ?? .arrow
            ))
        case "delete":
            self = .delete(id: try c.decode(String.self, forKey: .id))
        case "erase":
            self = .erase(try Self.rect(from: c))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "Unknown op \"\(kind)\"")
        }
    }

    private static func rect(from c: KeyedDecodingContainer<CodingKeys>) throws -> CGRect {
        let rect = CGRect(
            x: try c.decode(Double.self, forKey: .x),
            y: try c.decode(Double.self, forKey: .y),
            width: try c.decode(Double.self, forKey: .w),
            height: try c.decode(Double.self, forKey: .h)
        ).standardized
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else {
            throw DecodingError.dataCorruptedError(forKey: .x, in: c, debugDescription: "Non-finite rectangle")
        }
        return rect
    }
}

/// The JSON document a model replies with: `{"ops": [...]}`.
///
/// Decoding is lenient per op: one malformed op is dropped rather than discarding the whole reply,
/// because the rest of the batch is usually still worth applying.
public struct EditBatch: Decodable, Sendable {
    public var ops: [EditOp]

    public init(ops: [EditOp]) { self.ops = ops }

    private enum CodingKeys: String, CodingKey { case ops }
    private struct Lenient: Decodable {
        let op: EditOp?
        init(from decoder: Decoder) throws { op = try? EditOp(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ops = try c.decode([Lenient].self, forKey: .ops).compactMap(\.op)
    }
}
