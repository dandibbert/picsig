import UIKit
import PicSigCore

/// Draws annotations and the watermark. All sizes are fractions of the image
/// width, so a mark drawn on a preview lands identically on the full size export.
enum AnnotationRenderer {
    static func draw(annotations: [Annotation], in size: CGSize, context: UIGraphicsImageRendererContext) {
        for annotation in annotations {
            draw(annotation, in: size, context: context)
        }
    }

    static func draw(_ annotation: Annotation, in size: CGSize, context: UIGraphicsImageRendererContext) {
        let points = annotation.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard !points.isEmpty else { return }
        let lineWidth = max(1, CGFloat(annotation.lineWidth) * size.width)
        let color = annotation.color.uiColor
        let cgContext = context.cgContext

        cgContext.saveGState()
        cgContext.setLineCap(.round)
        cgContext.setLineJoin(.round)

        switch annotation.tool {
        case .pen, .highlighter:
            let path = UIBezierPath()
            path.move(to: points[0])
            if points.count == 1 {
                path.addLine(to: CGPoint(x: points[0].x + 0.1, y: points[0].y))
            } else {
                // Quadratic smoothing through the midpoints keeps a finger drawn
                // line from looking like a polyline.
                for index in 1..<points.count {
                    let midpoint = CGPoint(x: (points[index - 1].x + points[index].x) / 2,
                                           y: (points[index - 1].y + points[index].y) / 2)
                    path.addQuadCurve(to: midpoint, controlPoint: points[index - 1])
                }
                path.addLine(to: points[points.count - 1])
            }
            path.lineWidth = annotation.tool == .highlighter ? lineWidth * 3 : lineWidth
            path.lineCapStyle = annotation.tool == .highlighter ? .square : .round
            (annotation.tool == .highlighter ? color.withAlphaComponent(0.35) : color).setStroke()
            if annotation.tool == .highlighter {
                cgContext.setBlendMode(.multiply)
            }
            path.stroke()

        case .line, .arrow:
            guard points.count >= 2 else { break }
            let start = points[0]
            let end = points[points.count - 1]
            color.setStroke()
            let path = UIBezierPath()
            path.move(to: start)
            path.addLine(to: end)
            path.lineWidth = lineWidth
            path.stroke()
            if annotation.tool == .arrow {
                drawArrowHead(from: start, to: end, lineWidth: lineWidth, color: color)
            }

        case .rectangle:
            guard points.count >= 2 else { break }
            let rect = CGRect(x: min(points[0].x, points[1].x),
                              y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x),
                              height: abs(points[1].y - points[0].y))
            let path = UIBezierPath(roundedRect: rect, cornerRadius: lineWidth)
            if annotation.isFilled {
                color.withAlphaComponent(0.28).setFill()
                path.fill()
            }
            color.setStroke()
            path.lineWidth = lineWidth
            path.stroke()

        case .ellipse:
            guard points.count >= 2 else { break }
            let rect = CGRect(x: min(points[0].x, points[1].x),
                              y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x),
                              height: abs(points[1].y - points[0].y))
            let path = UIBezierPath(ovalIn: rect)
            if annotation.isFilled {
                color.withAlphaComponent(0.28).setFill()
                path.fill()
            }
            color.setStroke()
            path.lineWidth = lineWidth
            path.stroke()

        case .text:
            guard !annotation.text.isEmpty else { break }
            let fontSize = max(8, CGFloat(annotation.fontSize) * size.width)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color
            ]
            let text = annotation.text as NSString
            let bounds = text.boundingRect(with: CGSize(width: size.width - points[0].x,
                                                        height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin],
                                           attributes: attributes,
                                           context: nil)
            text.draw(in: CGRect(origin: points[0], size: bounds.size), withAttributes: attributes)

        case .numberBadge:
            let diameter = max(16, CGFloat(annotation.fontSize) * size.width * 1.6)
            let rect = CGRect(x: points[0].x - diameter / 2,
                              y: points[0].y - diameter / 2,
                              width: diameter,
                              height: diameter)
            color.setFill()
            UIBezierPath(ovalIn: rect).fill()
            let label = String(annotation.number ?? 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: diameter * 0.6, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                       withAttributes: attributes)
        }

        cgContext.restoreGState()
    }

    private static func drawArrowHead(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat, color: UIColor) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(lineWidth * 4, 12)
        let spread = CGFloat.pi / 7
        let left = CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread))
        let right = CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread))
        let path = UIBezierPath()
        path.move(to: end)
        path.addLine(to: left)
        path.addLine(to: right)
        path.close()
        color.setFill()
        path.fill()
    }

    static func draw(watermark: Watermark, in size: CGSize, context: UIGraphicsImageRendererContext) {
        guard !watermark.isEmpty else { return }
        let fontSize = max(9, CGFloat(watermark.fontSize) * size.width)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: watermark.color.uiColor.withAlphaComponent(CGFloat(watermark.opacity))
        ]
        let text = watermark.text as NSString
        let textSize = text.size(withAttributes: attributes)
        let inset = fontSize * 0.8

        switch watermark.position {
        case .tiled:
            let cgContext = context.cgContext
            cgContext.saveGState()
            cgContext.rotate(by: -.pi / 9)
            let stepX = textSize.width * 1.8
            let stepY = textSize.height * 5
            var y = -size.height
            while y < size.height * 1.6 {
                var x = -size.width
                while x < size.width * 1.6 {
                    text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
                    x += stepX
                }
                y += stepY
            }
            cgContext.restoreGState()
        case .bottomTrailing:
            text.draw(at: CGPoint(x: size.width - textSize.width - inset,
                                  y: size.height - textSize.height - inset),
                      withAttributes: attributes)
        case .bottomLeading:
            text.draw(at: CGPoint(x: inset, y: size.height - textSize.height - inset), withAttributes: attributes)
        case .topTrailing:
            text.draw(at: CGPoint(x: size.width - textSize.width - inset, y: inset), withAttributes: attributes)
        case .topLeading:
            text.draw(at: CGPoint(x: inset, y: inset), withAttributes: attributes)
        case .center:
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                  y: (size.height - textSize.height) / 2),
                      withAttributes: attributes)
        }
    }
}
