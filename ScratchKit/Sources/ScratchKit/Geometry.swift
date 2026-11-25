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

    /// Whether `point` lies on the drawn outline of `node`, give or take `tolerance`. Free text has
    /// no outline, so anywhere on it counts.
    public static func outline(of node: Node, isTouchedAt point: CGPoint, tolerance: CGFloat) -> Bool {
        let frame = node.frame
        guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        let halfWidth = max(frame.width / 2, 0.001)
        let halfHeight = max(frame.height / 2, 0.001)
        let dx = abs(point.x - frame.midX)
        let dy = abs(point.y - frame.midY)
        switch node.shape {
        case .text:
            return true
        case .rect, .rounded:
            return !frame.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .ellipse:
            // Scale the point onto the unit circle, then measure how far it is from radius 1.
            let radius = ((dx / halfWidth) * (dx / halfWidth) + (dy / halfHeight) * (dy / halfHeight)).squareRoot()
            return abs(radius - 1) * min(halfWidth, halfHeight) <= tolerance
        case .diamond:
            let radius = dx / halfWidth + dy / halfHeight
            return abs(radius - 1) * min(halfWidth, halfHeight) <= tolerance
        }
    }

    /// Distance from `point` to the segment between `a` and `b`.
    public static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        let nearest = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
        return ((point.x - nearest.x) * (point.x - nearest.x) + (point.y - nearest.y) * (point.y - nearest.y)).squareRoot()
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
