import PencilKit
import ScratchKit
import UIKit

/// Draws the clean elements. The same code paints the screen and the picture a model is sent,
/// so the model always sees exactly what the user sees (plus id tags).
@MainActor
enum DiagramRenderer {
    /// Draws into the current UIKit graphics context, in canvas points.
    ///
    /// - Parameter tagSize: When set, each element's id is printed beside it at this font size.
    ///   Only the model's copy of the canvas carries tags.
    ///   - visible: When set, elements wholly outside this rectangle are skipped.
    static func draw(_ diagram: Diagram, tagSize: CGFloat? = nil, visible: CGRect? = nil) {
        let nodesByID = Dictionary(diagram.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var edgeTags: [(String, CGPoint)] = []
        for edge in diagram.edges {
            guard let from = nodesByID[edge.from], let to = nodesByID[edge.to],
                  let segment = Geometry.segment(from: from, to: to, gap: 5) else { continue }
            if let visible {
                let reach = CGRect(x: min(segment.start.x, segment.end.x), y: min(segment.start.y, segment.end.y),
                                   width: abs(segment.end.x - segment.start.x), height: abs(segment.end.y - segment.start.y))
                guard reach.insetBy(dx: -80, dy: -30).intersects(visible) else { continue }
            }
            draw(edge, from: segment.start, to: segment.end)

            // A quarter of the way along and off to one side, clear of both the line and its label.
            let dx = segment.end.x - segment.start.x
            let dy = segment.end.y - segment.start.y
            let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
            let offset = (tagSize ?? 0) * 1.2
            edgeTags.append((edge.id, CGPoint(
                x: segment.start.x + dx * 0.25 - dy / length * offset,
                y: segment.start.y + dy * 0.25 + dx / length * offset
            )))
        }
        for node in diagram.nodes {
            // Free text can run past the right of its frame, so give it room before culling.
            if let visible, !node.frame.insetBy(dx: node.shape == .text ? -2000 : -10, dy: -10).intersects(visible) { continue }
            draw(node)
        }
        if let tagSize {
            for (id, center) in edgeTags {
                drawTag(id, size: tagSize) { textSize in
                    CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2)
                }
            }
            for node in diagram.nodes {
                drawTag(node.id, size: tagSize) { textSize in
                    // Just above the top-left corner, or just inside it at the top edge of the picture.
                    let above = node.frame.minY - textSize.height - 1
                    return CGPoint(x: node.frame.minX, y: above >= (visible?.minY ?? 0) ? above : node.frame.minY + 2)
                }
            }
        }
    }

    // MARK: Document pages

    /// Draws the pages of a PDF as white sheets. `cached` may supply a ready-made picture of a page,
    /// which is far cheaper to draw than the page itself while the canvas is moving.
    static func drawPages(of document: PadDocument, in context: CGContext, visible: CGRect?, cached: ((Int) -> UIImage?)? = nil) {
        for (index, frame) in document.frames.enumerated() {
            if let visible, !frame.insetBy(dx: -4, dy: -4).intersects(visible) { continue }
            UIColor(white: 0.78, alpha: 1).setFill()
            UIRectFill(frame.insetBy(dx: -1, dy: -1))
            UIColor.white.setFill()
            UIRectFill(frame)
            if let image = cached?(index) {
                image.draw(in: frame)
            } else if let page = document.pdf.page(at: index + 1) {
                draw(page, in: frame, context: context)
            }
        }
    }

    /// Draws one PDF page into `frame`. PDF space has its origin at the bottom left, so it is flipped.
    static func draw(_ page: CGPDFPage, in frame: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: frame)
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: frame.size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
    }

    // MARK: Nodes

    private static func draw(_ node: Node) {
        let color = node.color.uiColor
        let frame = node.frame

        if let outline = outline(of: node) {
            // An opaque fill first, so edges and ink-coloured clutter never show through a shape.
            UIColor.systemBackground.setFill()
            outline.fill()
            if node.color != .standard {
                color.withAlphaComponent(0.12).setFill()
                outline.fill()
            }
            color.setStroke()
            outline.lineWidth = 2
            outline.lineJoinStyle = .round
            outline.stroke()
        }

        guard !node.label.isEmpty else { return }
        if node.shape == .text {
            // Free text keeps the scale it was written at: the frame's height, shared between its
            // lines, sets the type size. Lines start at the frame's left edge and never wrap.
            let lines = node.label.components(separatedBy: "\n")
            let lineHeight = frame.height / CGFloat(lines.count)
            let font = font(min(max(lineHeight * 0.62, 9), 72))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            for (index, line) in lines.enumerated() {
                let y = frame.minY + CGFloat(index) * lineHeight + (lineHeight - font.lineHeight) / 2
                (line as NSString).draw(at: CGPoint(x: frame.minX, y: y), withAttributes: attributes)
            }
        } else {
            let inset: CGFloat = switch node.shape {
            case .ellipse: 0.16
            case .diamond: 0.24
            default: 0
            }
            let area = frame.insetBy(dx: frame.width * inset + 8, dy: frame.height * inset + 4)
            drawLabel(node.label, in: area, color: color)
        }
    }

    private static func outline(of node: Node) -> UIBezierPath? {
        let frame = node.frame
        switch node.shape {
        case .rect:
            return UIBezierPath(roundedRect: frame, cornerRadius: 4)
        case .rounded:
            return UIBezierPath(roundedRect: frame, cornerRadius: min(frame.width, frame.height) * 0.3)
        case .ellipse:
            return UIBezierPath(ovalIn: frame)
        case .diamond:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: frame.midX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
            path.close()
            return path
        case .text:
            return nil
        }
    }

    /// Wrapped, centred, and shrunk until it fits (down to a legible floor).
    private static func drawLabel(_ text: String, in area: CGRect, color: UIColor) {
        guard area.width > 4 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: paragraph]
        var bounds = CGRect.zero
        for size in [17, 15, 13, 12, 11, 10] as [CGFloat] {
            attributes[.font] = font(size)
            bounds = (text as NSString).boundingRect(
                with: CGSize(width: area.width, height: .greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin, attributes: attributes, context: nil
            )
            if bounds.height <= area.height { break }
        }
        let height = ceil(bounds.height)
        (text as NSString).draw(
            in: CGRect(x: area.minX, y: area.midY - height / 2, width: area.width, height: height),
            withAttributes: attributes
        )
    }

    // MARK: Edges

    private static func draw(_ edge: Edge, from start: CGPoint, to end: CGPoint) {
        let color = UIColor.label
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let ux = dx / length
        let uy = dy / length

        let hasHead = edge.style != .line
        let headLength: CGFloat = min(12, length * 0.6)
        // Stop the shaft inside the head, so its round cap doesn't blunt the tip.
        let shaftEnd = hasHead ? CGPoint(x: end.x - ux * headLength * 0.7, y: end.y - uy * headLength * 0.7) : end

        let shaft = UIBezierPath()
        shaft.move(to: start)
        shaft.addLine(to: shaftEnd)
        shaft.lineWidth = 2
        shaft.lineCapStyle = .round
        if edge.style == .dashed {
            shaft.setLineDash([7, 6], count: 2, phase: 0)
        }
        color.setStroke()
        shaft.stroke()

        if hasHead {
            let halfWidth = headLength * 0.45
            let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
            let head = UIBezierPath()
            head.move(to: end)
            head.addLine(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
            head.addLine(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
            head.close()
            color.setFill()
            head.fill()
        }

        if !edge.label.isEmpty {
            let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            drawText(edge.label, centeredAt: middle, font: font(13, weight: .regular), color: color, backed: true)
        }
    }

    // MARK: Text

    private static func drawText(_ text: String, centeredAt center: CGPoint, font: UIFont, color: UIColor, backed: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if backed {
            UIColor.systemBackground.setFill()
            UIBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -5, dy: -1), cornerRadius: 4).fill()
        }
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private static func drawTag(_ id: String, size: CGFloat, origin: (CGSize) -> CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: size, weight: .bold),
            .foregroundColor: tagColor,
        ]
        let textSize = (id as NSString).size(withAttributes: attributes)
        let origin = origin(textSize)
        // A white plate keeps the tag legible where it lands on top of something.
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: origin, size: textSize).insetBy(dx: -size * 0.15, dy: 0))
        (id as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// Magenta: a colour nothing else on the canvas uses, so a model can tell tags from content.
    private static let tagColor = UIColor(red: 0.86, green: 0, blue: 0.72, alpha: 1)

    private static func font(_ size: CGFloat, weight: UIFont.Weight = .medium) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: size)
    }
}

extension NodeColor {
    var uiColor: UIColor {
        switch self {
        case .standard: .label
        case .red: .systemRed
        case .orange: .systemOrange
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }
}

/// The canvas as a model sees it: one flat PNG, scaled so its long edge is at most `longEdge` pixels.
struct CanvasSnapshot {
    let png: Data
    let pixelSize: CGSize
    /// Maps canvas points to pixels in the image.
    let toImage: CGAffineTransform

    @MainActor
    /// Renders the part of the canvas inside `rect` (canvas points).
    static func make(diagram: Diagram, drawing: PKDrawing, document: PadDocument? = nil, rect: CGRect, longEdge: CGFloat = 1024) -> CanvasSnapshot? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let scale = min(1, longEdge / max(rect.width, rect.height))
        let pixelSize = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let image = UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            // Always black ink on white paper, whatever appearance the iPad is in.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pixelSize))
                context.cgContext.scaleBy(x: scale, y: scale)
                context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
                if let document { DiagramRenderer.drawPages(of: document, in: context.cgContext, visible: rect) }
                DiagramRenderer.draw(diagram, tagSize: 12 / scale, visible: rect)
                // Rendered at twice the target density so thin strokes survive the downscale.
                drawing.image(from: rect, scale: scale * 2).draw(in: rect)
            }
        }
        guard let png = image.pngData() else { return nil }
        let toImage = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return CanvasSnapshot(png: png, pixelSize: pixelSize, toImage: toImage)
    }
}
