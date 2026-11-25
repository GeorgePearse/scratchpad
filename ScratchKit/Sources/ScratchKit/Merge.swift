import CoreGraphics
import Foundation

/// The outcome of applying a model's ops to the live canvas.
public struct MergeResult: Equatable, Sendable {
    /// The diagram after the edits.
    public var diagram: Diagram
    /// Rectangles whose ink should be removed.
    public var eraseRegions: [CGRect]
    /// How many of the ops took effect.
    public var appliedCount: Int
}

extension Diagram {
    /// Applies `ops` to this diagram, where the ops were computed against `base`.
    ///
    /// A model answers a snapshot that is a second or two old by the time the answer lands, and the
    /// user keeps working in the meantime. So this is a three-way merge: an op on an element the user
    /// has changed or removed since `base` is dropped, and the user's version wins. Everything else
    /// applies, which means new ink and untouched elements are never disturbed by a late answer.
    public func merging(_ ops: [EditOp], base: Diagram) -> MergeResult {
        var result = self
        var regions: [CGRect] = []
        var applied = 0
        var waitingEdges: [Edge] = []

        func upsert(_ edge: Edge) {
            if let index = result.edges.firstIndex(where: { $0.id == edge.id }) {
                result.edges[index] = edge
            } else {
                result.edges.append(edge)
            }
            applied += 1
        }

        for op in ops {
            switch op {
            case .node(var node):
                let idIsAnEdge = edge(node.id) != nil || base.edge(node.id) != nil
                guard !node.id.isEmpty, !idIsAnEdge, self.node(node.id) == base.node(node.id) else { continue }
                node.frame.size.width = max(node.frame.width, Self.minimumNodeSide)
                node.frame.size.height = max(node.frame.height, Self.minimumNodeSide)
                if let index = result.nodes.firstIndex(where: { $0.id == node.id }) {
                    result.nodes[index] = node
                } else {
                    result.nodes.append(node)
                }
                applied += 1

            case .edge(let edge):
                let idIsANode = node(edge.id) != nil || base.node(edge.id) != nil
                guard !edge.id.isEmpty, !idIsANode, edge.from != edge.to,
                      self.edge(edge.id) == base.edge(edge.id) else { continue }
                if result.node(edge.from) != nil, result.node(edge.to) != nil {
                    upsert(edge)
                } else {
                    // Its nodes may be created later in the same batch.
                    waitingEdges.append(edge)
                }

            case .delete(let id):
                if result.node(id) != nil, node(id) == base.node(id) {
                    result.nodes.removeAll { $0.id == id }
                    applied += 1
                } else if result.edge(id) != nil, edge(id) == base.edge(id) {
                    result.edges.removeAll { $0.id == id }
                    applied += 1
                }

            case .erase(let rect):
                guard rect.width > 0, rect.height > 0 else { continue }
                regions.append(rect)
                applied += 1
            }
        }

        for edge in waitingEdges where result.node(edge.from) != nil && result.node(edge.to) != nil {
            upsert(edge)
        }
        let surviving = Set(result.nodes.map(\.id))
        result.edges.removeAll { !surviving.contains($0.from) || !surviving.contains($0.to) }

        return MergeResult(diagram: result, eraseRegions: regions, appliedCount: applied)
    }

    static let minimumNodeSide: CGFloat = 8
}

public enum InkErasure {
    /// Whether a stroke with these bounds should be removed by an erase over `region`.
    ///
    /// A stroke goes when most of it lies inside the region. That keeps a long stroke that merely
    /// passes through (an arrow leaving a box that is being replaced) while taking everything the
    /// model evidently meant, even if its rectangle is a few pixels shy.
    public static func covers(strokeBounds: CGRect, region: CGRect) -> Bool {
        let overlap = strokeBounds.intersection(region)
        guard !overlap.isNull else { return false }
        let area = strokeBounds.width * strokeBounds.height
        guard area > 1 else {
            return region.contains(CGPoint(x: strokeBounds.midX, y: strokeBounds.midY))
        }
        return (overlap.width * overlap.height) / area >= 0.6
    }

    public static func covers(strokeBounds: CGRect, regions: [CGRect]) -> Bool {
        regions.contains { covers(strokeBounds: strokeBounds, region: $0) }
    }
}
