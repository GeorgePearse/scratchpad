import CoreGraphics
import Foundation

public enum Geometry {
    /// The point where a ray from the centre of `node` towards `target` crosses the node's outline,
    /// pushed outwards by `gap`. Nil when `target` is the node's own centre.
    public static func boundaryPoint(of node: Node, toward target: CGPoint, gap: CGFloat = 0) -> CGPoint? {
        let center = node.center
        let dx = target.x - center.x
        let dy = target.y - center.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.001 else { return nil }

        let halfWidth = max(node.frame.width / 2, 0.001)
        let halfHeight = max(node.frame.height / 2, 0.001)

        // `t` scales (dx, dy) so that it ends exactly on the outline.
        let t: CGFloat
        switch node.shape {
        case .ellipse:
            let nx = dx / halfWidth
            let ny = dy / halfHeight
            t = 1 / (nx * nx + ny * ny).squareRoot()
        case .diamond:
            t = 1 / (abs(dx) / halfWidth + abs(dy) / halfHeight)
        case .rect, .rounded, .text:
            t = min(
                dx == 0 ? .infinity : halfWidth / abs(dx),
                dy == 0 ? .infinity : halfHeight / abs(dy)
            )
        }

        let reach = t * length + gap
        return CGPoint(x: center.x + dx / length * reach, y: center.y + dy / length * reach)
    }

    /// The visible segment of an edge between two nodes: outline to outline, with a small gap.
    /// Nil when the nodes overlap so much that nothing would be visible.
    public static func segment(from: Node, to: Node, gap: CGFloat = 4) -> (start: CGPoint, end: CGPoint)? {
        guard let start = boundaryPoint(of: from, toward: to.center, gap: gap),
              let end = boundaryPoint(of: to, toward: from.center, gap: gap) else { return nil }
        // If the two points have passed each other, the nodes overlap along this line.
        let along = (end.x - start.x) * (to.center.x - from.center.x)
            + (end.y - start.y) * (to.center.y - from.center.y)
        guard along > 0 else { return nil }
        return (start, end)
    }
}
