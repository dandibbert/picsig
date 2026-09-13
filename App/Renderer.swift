import UIKit

extension PaperColor {
    var uiColor: UIColor {
        switch self {
        case .white: return .white
        case .ivory: return UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)
        case .midnight: return UIColor(red: 0.10, green: 0.12, blue: 0.17, alpha: 1)
        case .lavender: return UIColor(red: 0.94, green: 0.92, blue: 0.99, alpha: 1)
        }
    }
}

enum Renderer {
    static func render(_ project: Project, region requested: Box? = nil, scale: Double = 1,
                       edits: Bool = true, finalGeometry: Bool = true, maxPixels: Double = 32_000_000) throws -> UIImage {
        try Task.checkCancellation()
        let composition = try Composition.build(project)
        let geometry = try ExportGeometry(canvas: composition.size,
                                          crop: finalGeometry ? project.edit.crop : .unit,
                                          turns: finalGeometry ? project.edit.quarterTurns : 0)
        let whole = Box(0, 0, geometry.size.width, geometry.size.height)
        let region = (requested ?? whole).intersection(whole)
        guard region.isValid, scale.isFinite, scale > 0, region.area * scale * scale <= maxPixels else { throw PicSigError.tooLarge }
        let size = CGSize(width: max(1, ceil(region.width * scale)), height: max(1, ceil(region.height * scale)))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        var renderingError: Error?
        let image = UIGraphicsImageRenderer(size: size, format: format).image { output in
            let context = output.cgContext
            project.layout.paper.uiColor.setFill(); context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -region.x, y: -region.y)
            switch geometry.turns {
            case 1: context.translateBy(x: geometry.size.width, y: 0); context.rotate(by: .pi / 2)
            case 2: context.translateBy(x: geometry.size.width, y: geometry.size.height); context.rotate(by: .pi)
            case 3: context.translateBy(x: 0, y: geometry.size.height); context.rotate(by: -.pi / 2)
            default: break
            }
            context.translateBy(x: -geometry.crop.x, y: -geometry.crop.y)
            let visible = geometry.sourceRegion(for: region)
            for placement in composition.placements where placement.destination.intersection(visible).area > 0 {
                if Task.isCancelled { renderingError = CancellationError(); break }
                autoreleasepool {
                    do {
                        let source = try ProjectStore.image(placement.image, project: project.id)
                        guard let cropped = source.cropping(to: placement.source.cgRect.integral) else { throw PicSigError.invalidImage }
                        context.saveGState()
                        if project.layout.cornerRadius > 0 { UIBezierPath(roundedRect: placement.destination.cgRect, cornerRadius: project.layout.cornerRadius).addClip() }
                        UIImage(cgImage: cropped).draw(in: placement.destination.cgRect)
                        context.restoreGState()
                    } catch { renderingError = error }
                }
                if renderingError != nil { break }
            }
            if edits {
                // Draw redactions LAST: annotations must never overwrite a privacy mask.
                drawAnnotations(project.edit.annotations, canvas: composition.size, context: context)
                drawMasks(project.edit.masks, canvas: composition.size, context: context)
            }
        }
        if let error = renderingError { throw error }
        return image
    }
    static func preview(_ project: Project, edits: Bool = false, finalGeometry: Bool = false) throws -> UIImage {
        let composition = try Composition.build(project)
        let geometry = try ExportGeometry(canvas: composition.size, crop: finalGeometry ? project.edit.crop : .unit, turns: finalGeometry ? project.edit.quarterTurns : 0)
        let scale = min(1, 1440 / min(geometry.size.width, geometry.size.height),
                        16384 / max(geometry.size.width, geometry.size.height), sqrt(5_000_000 / geometry.size.area))
        return try render(project, scale: scale, edits: edits, finalGeometry: finalGeometry, maxPixels: 5_100_000)
    }
    static func drawMasks(_ masks: [PrivacyMask], canvas: Size2D, context: CGContext) {
        for mask in masks where mask.enabled {
            let rect = mask.rect.intersection(.unit).scaled(to: canvas).cgRect.integral
            guard rect.width > 0, rect.height > 0 else { continue }
            context.saveGState(); context.setShouldAntialias(false); context.setAlpha(1); context.setBlendMode(.normal)
            let ink = UIColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1)
            context.setFillColor((mask.style == .paper ? UIColor.white : ink).cgColor)
            context.fill(rect)
            if mask.style == .mosaic {
                // Decorative, FULLY OPAQUE pixels. Never sample the original confidential image.
                context.clip(to: rect)
                let block = max(6, min(24, rect.height / 3))
                for y in stride(from: rect.minY, to: rect.maxY, by: block) {
                    for x in stride(from: rect.minX, to: rect.maxX, by: block) {
                        let shade = CGFloat((Int(x / block) * 7 + Int(y / block) * 11) % 5) * 0.045 + 0.12
                        context.setFillColor(UIColor(white: shade, alpha: 1).cgColor)
                        context.fill(CGRect(x: x, y: y, width: block, height: block))
                    }
                }
            }
            context.restoreGState()
        }
    }
    static func markColor(_ name: String) -> UIColor {
        switch name { case "ink": return UIColor(white: 0.12, alpha: 1); case "mint": return .systemTeal; case "violet": return .systemIndigo; default: return .systemRed }
    }
    static func drawAnnotations(_ annotations: [Annotation], canvas: Size2D, context: CGContext) {
        for annotation in annotations {
            guard let first = annotation.points.first else { continue }
            let points = annotation.points.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) }
            let color = markColor(annotation.color)
            context.saveGState(); context.setStrokeColor(color.cgColor); context.setFillColor(color.cgColor)
            context.setLineWidth(annotation.width); context.setLineJoin(.round); context.setLineCap(.round)
            switch annotation.kind {
            case .text:
                let font = UIFont.systemFont(ofSize: max(18, annotation.width * 5), weight: .semibold)
                let point = CGPoint(x: first.x * canvas.width, y: first.y * canvas.height)
                let textRect = CGRect(x: point.x, y: point.y, width: max(1, canvas.width - point.x), height: max(1, canvas.height - point.y))
                (annotation.text as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: color])
            case .rectangle:
                if let last = points.last, let first = points.first {
                    context.stroke(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
                }
            case .pen, .arrow:
                if let first = points.first { context.move(to: first); for point in points.dropFirst() { context.addLine(to: point) }; context.strokePath() }
                if annotation.kind == .arrow, points.count >= 2, let first = points.first, let last = points.last {
                    let angle = atan2(last.y - first.y, last.x - first.x), length = max(18, CGFloat(annotation.width) * 4)
                    context.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                    context.addLine(to: last)
                    context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
                    context.strokePath()
                }
            }
            context.restoreGState()
        }
    }
}

extension Renderer {
    static func annotationBounds(_ mark: Annotation, canvas: Size2D) -> Box {
        guard let origin = mark.points.first else { return Box(0, 0, 0, 0) }
        if mark.kind == .text {
            let font = UIFont.systemFont(ofSize: max(18, mark.width * 5), weight: .semibold)
            let maxWidth = max(1, canvas.width * (1 - origin.x))
            let bounds = (mark.text as NSString).boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
            return Box(origin.x, origin.y, max(12, ceil(bounds.width)) / canvas.width, max(font.lineHeight, ceil(bounds.height)) / canvas.height)
        }
        let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
        let padding = max(4, mark.width) / 2
        return Box(xs.min() ?? 0, ys.min() ?? 0, max(1 / canvas.width, (xs.max() ?? 0) - (xs.min() ?? 0)), max(1 / canvas.height, (ys.max() ?? 0) - (ys.min() ?? 0)))
            .expanded(dx: padding / canvas.width, dy: padding / canvas.height)
    }
    static func hitAnnotation(_ mark: Annotation, at point: Point2D, canvas: Size2D, tolerance: Size2D) -> Bool {
        let box = annotationBounds(mark, canvas: canvas)
        guard box.expanded(dx: tolerance.width, dy: tolerance.height).contains(point) else { return false }
        if mark.kind == .text { return true }
        if mark.kind == .rectangle {
            let inner = box.expanded(dx: -tolerance.width, dy: -tolerance.height)
            return !inner.isValid || !inner.contains(point)
        }
        guard mark.points.count > 1 else { return true }
        let p = CGPoint(x: point.x * canvas.width, y: point.y * canvas.height)
        let threshold = max(tolerance.width * canvas.width, tolerance.height * canvas.height) + mark.width
        for i in 1..<mark.points.count {
            let a = mark.points[i - 1], b = mark.points[i]
            let ax = a.x * canvas.width, ay = a.y * canvas.height, dx = (b.x - a.x) * canvas.width, dy = (b.y - a.y) * canvas.height
            let t = max(0, min(1, ((p.x - ax) * dx + (p.y - ay) * dy) / max(0.0001, dx * dx + dy * dy)))
            if hypot(p.x - ax - t * dx, p.y - ay - t * dy) <= threshold { return true }
        }
        return false
    }
}
