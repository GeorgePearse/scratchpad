import CoreGraphics
import Foundation

/// A PDF laid out on the canvas as a column of pages, to read and to write around.
struct PadDocument: Equatable {
    let pdf: CGPDFDocument
    /// Where each page sits, in canvas points. One PDF point is one canvas point.
    let frames: [CGRect]

    /// The gap between consecutive pages.
    static let spacing: CGFloat = 60

    init?(url: URL, topLeft: CGPoint) {
        guard let pdf = CGPDFDocument(url as CFURL), pdf.numberOfPages > 0 else { return nil }
        var frames: [CGRect] = []
        var y = topLeft.y
        for number in 1...pdf.numberOfPages {
            guard let page = pdf.page(at: number) else { continue }
            var size = page.getBoxRect(.cropBox).size
            if page.rotationAngle % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            frames.append(CGRect(origin: CGPoint(x: topLeft.x, y: y), size: size))
            y += size.height + Self.spacing
        }
        self.pdf = pdf
        self.frames = frames
    }

    var bounds: CGRect {
        frames.reduce(CGRect.null) { $0.union($1) }
    }

    /// The size the document would occupy, before it is given a position.
    static func size(of url: URL) -> CGSize? {
        PadDocument(url: url, topLeft: .zero)?.bounds.size
    }

    static func == (a: PadDocument, b: PadDocument) -> Bool {
        a.pdf === b.pdf && a.frames == b.frames
    }
}
