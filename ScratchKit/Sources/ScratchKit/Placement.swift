import CoreGraphics

public enum Placement {
    /// Finds somewhere to put a box of `size` next to `anchor` without covering anything in `avoiding`.
    ///
    /// It tries the right, the left, below and above, hard against the anchor first and then
    /// further and further out, and takes the first spot that is clear. So a note about a paragraph
    /// in the middle of a page lands in the nearest empty margin, and a second note about the same
    /// place goes to the other side or further along instead of on top of the first.
    public static func origin(
        for size: CGSize, beside anchor: CGRect, avoiding obstacles: [CGRect], gap: CGFloat = 28
    ) -> CGPoint {
        func isClear(_ origin: CGPoint) -> Bool {
            let rect = CGRect(origin: origin, size: size)
            return !obstacles.contains { $0.intersects(rect) }
        }
        for distance in stride(from: CGFloat(0), through: 2400, by: 120) {
            let reach = gap + distance
            let candidates = [
                CGPoint(x: anchor.maxX + reach, y: anchor.minY),
                CGPoint(x: anchor.minX - reach - size.width, y: anchor.minY),
                CGPoint(x: anchor.minX, y: anchor.maxY + reach),
                CGPoint(x: anchor.minX, y: anchor.minY - reach - size.height),
            ]
            if let free = candidates.first(where: isClear) { return free }
        }
        // Nothing clear within reach: fall back to the right, as close as allowed.
        return CGPoint(x: anchor.maxX + gap, y: anchor.minY)
    }
}
