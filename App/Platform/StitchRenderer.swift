import UIKit
import PicSigCore

/// Executes a `StitchPlan`: every segment is one crop-and-draw.
enum StitchRenderer {
    /// Renders the plan at full resolution.
    /// - Parameter maxPixels: safety valve for absurdly long results; the canvas
    ///   is scaled down uniformly if it would exceed this.
    static func render(plan: StitchPlan,
                       sources: [CGImage],
                       background: RGBAColor = .white,
                       maxPixels: Int = 180_000_000) -> UIImage? {
        guard !plan.isEmpty, !sources.isEmpty else { return nil }

        var scale = 1.0
        if plan.canvasSize.pixelCount > maxPixels {
            scale = (Double(maxPixels) / Double(plan.canvasSize.pixelCount)).squareRoot()
        }
        let canvasSize = plan.canvasSize.scaled(by: scale)
        guard !canvasSize.isEmpty else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = background.alpha >= 1
        let renderer = UIGraphicsImageRenderer(size: canvasSize.cgSize, format: format)

        return renderer.image { context in
            background.uiColor.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize.cgSize))
            context.cgContext.interpolationQuality = .high

            for segment in plan.segments {
                guard sources.indices.contains(segment.sourceIndex) else { continue }
                let source = sources[segment.sourceIndex]
                let sourceRect = segment.sourceRect.clamped(to: source.pixelSize)
                guard !sourceRect.isEmpty, let cropped = source.cropping(to: sourceRect.cgRect) else { continue }
                var destination = segment.destinationRect.cgRect
                if scale != 1 {
                    destination = destination.applying(CGAffineTransform(scaleX: scale, y: scale))
                }
                UIImage(cgImage: cropped).draw(in: destination)
            }
        }
    }

    /// Renders a manual layout, applying the canvas style (rounded corners,
    /// borders, shadows) to each placed image.
    static func renderStyled(plan: StitchPlan,
                             sources: [CGImage],
                             style: CanvasStyle) -> UIImage? {
        guard !plan.isEmpty, !sources.isEmpty else { return nil }
        let margin = Int((Double(plan.canvasSize.width) * style.margin).rounded())
        let canvasSize = PixelSize(width: plan.canvasSize.width + margin * 2,
                                   height: plan.canvasSize.height + margin * 2)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = style.backgroundColor.alpha >= 1
        let renderer = UIGraphicsImageRenderer(size: canvasSize.cgSize, format: format)

        return renderer.image { context in
            style.backgroundColor.uiColor.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize.cgSize))
            context.cgContext.interpolationQuality = .high

            for segment in plan.segments {
                guard sources.indices.contains(segment.sourceIndex) else { continue }
                let source = sources[segment.sourceIndex]
                let sourceRect = segment.sourceRect.clamped(to: source.pixelSize)
                guard !sourceRect.isEmpty, let cropped = source.cropping(to: sourceRect.cgRect) else { continue }
                let destination = segment.destinationRect.cgRect
                    .offsetBy(dx: CGFloat(margin), dy: CGFloat(margin))
                let radius = CGFloat(Double(segment.destinationRect.width) * style.cornerRadius)
                let path = UIBezierPath(roundedRect: destination, cornerRadius: radius)

                context.cgContext.saveGState()
                if style.shadowOpacity > 0 {
                    let blur = CGFloat(Double(plan.canvasSize.width) * style.shadowRadius)
                    context.cgContext.setShadow(offset: CGSize(width: 0, height: blur / 3),
                                                blur: blur,
                                                color: UIColor.black.withAlphaComponent(CGFloat(style.shadowOpacity)).cgColor)
                    style.backgroundColor.uiColor.setFill()
                    path.fill()
                    context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                }
                path.addClip()
                UIImage(cgImage: cropped).draw(in: destination)
                context.cgContext.restoreGState()

                if style.borderWidth > 0 {
                    style.borderColor.uiColor.setStroke()
                    path.lineWidth = CGFloat(Double(plan.canvasSize.width) * style.borderWidth)
                    path.stroke()
                }
            }
        }
    }
}

extension UIImage {
    func resized(longestEdge: Int) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > CGFloat(longestEdge), longest > 0 else { return self }
        let scale = CGFloat(longestEdge) / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    func resized(to size: PixelSize) -> UIImage {
        guard !size.isEmpty, size != PixelSize(width: Int(self.size.width), height: Int(self.size.height)) else {
            return self
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size.cgSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size.cgSize))
        }
    }
}
