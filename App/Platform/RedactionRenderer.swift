import UIKit
import CoreImage
import PicSigCore

/// Draws a `RedactionPlan` onto an image.
///
/// Design rules that make this stronger than a plain overlay:
/// * Mosaic and solid blocks replace pixels; nothing of the original survives in
///   the exported file, because the export always rasterises this result.
/// * A mosaic block is at least 8 pixels and grows with the text height, so the
///   glyph shapes cannot be read from the block pattern.
/// * A little deterministic noise is added on top of the mosaic. Averaging based
///   attacks on pixelated text rely on clean block values; noise removes that.
/// * Replacement text is drawn on an opaque plate, so the original never shows
///   through the new glyphs.
enum RedactionRenderer {
    /// Creating a `CIContext` is expensive, so the tone adjustments in
    /// `ImageComposer` share one. `CIContext` is thread safe, and composition
    /// always runs off the main actor, so sharing one instance across tasks is fine.
    /// Masking itself no longer uses Core Image — see `blurred(_:radius:)`.
    nonisolated(unsafe) static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    struct Options {
        /// Mosaic block size at strength 0, in pixels.
        var minimumBlockSize: Int = 8
        /// Mosaic block size at strength 1, as a fraction of the masked height.
        var maximumBlockFraction: Double = 0.55
        var addsMosaicNoise: Bool = true
        /// Font used for replacement text; a system font keeps it legible in both
        /// Chinese and Latin.
        var replacementFontName: String?

        static let `default` = Options()
    }

    static func apply(plan: RedactionPlan, to image: UIImage, options: Options = .default) -> UIImage {
        guard !plan.isEmpty else { return image }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            for item in plan.items {
                let rect = item.box.cgRect(in: size).integral
                guard rect.width >= 1, rect.height >= 1 else { continue }
                switch item.style {
                case .mosaic:
                    drawMosaic(item: item, rect: rect, source: image, context: context, options: options)
                case .blur:
                    drawBlur(item: item, rect: rect, source: image, context: context)
                case .solid:
                    drawSolid(rect: rect, context: context)
                case .sticker:
                    drawSticker(item: item, rect: rect, context: context)
                case .replacement:
                    drawReplacement(item: item, rect: rect, context: context, options: options)
                }
            }
        }
    }

    // MARK: - Styles

    private static func drawMosaic(item: RedactionItem,
                                   rect: CGRect,
                                   source: UIImage,
                                   context: UIGraphicsImageRendererContext,
                                   options: Options) {
        let block = blockSize(for: rect, strength: item.strength, options: options)
        guard let cgImage = source.cgImage,
              let cropped = cgImage.cropping(to: rect) else {
            drawSolid(rect: rect, context: context)
            return
        }

        let columns = max(1, Int(rect.width) / block)
        let rows = max(1, Int(rect.height) / block)

        // Downsample with no interpolation, then scale back up the same way: the
        // result contains only `columns * rows` distinct colours.
        let smallFormat = UIGraphicsImageRendererFormat.preferred()
        smallFormat.scale = 1
        smallFormat.opaque = true
        let small = UIGraphicsImageRenderer(size: CGSize(width: columns, height: rows), format: smallFormat)
            .image { smallContext in
                smallContext.cgContext.interpolationQuality = .medium
                UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: columns, height: rows))
            }

        context.cgContext.saveGState()
        context.cgContext.interpolationQuality = .none
        small.draw(in: rect)
        context.cgContext.restoreGState()

        if options.addsMosaicNoise {
            drawNoise(in: rect, block: block, seed: item.id.hashValue, context: context)
        }
    }

    private static func blockSize(for rect: CGRect, strength: Double, options: Options) -> Int {
        let byHeight = Double(rect.height) * options.maximumBlockFraction * max(0.2, strength)
        return max(options.minimumBlockSize, Int(byHeight.rounded()))
    }

    /// Deterministic speckle over the mosaic. Deterministic so the same document
    /// exports identically twice, speckled so block values are not clean averages.
    private static func drawNoise(in rect: CGRect,
                                  block: Int,
                                  seed: Int,
                                  context: UIGraphicsImageRendererContext) {
        var state = UInt64(bitPattern: Int64(seed)) | 1
        func nextUnit() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 1000) / 1000
        }
        let step = CGFloat(max(2, block / 2))
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                let alpha = 0.04 + nextUnit() * 0.08
                let white = nextUnit() > 0.5
                (white ? UIColor.white : UIColor.black).withAlphaComponent(CGFloat(alpha)).setFill()
                context.fill(CGRect(x: x, y: y, width: step, height: step).intersection(rect))
                x += step
            }
            y += step
        }
    }

    private static func drawBlur(item: RedactionItem,
                                 rect: CGRect,
                                 source: UIImage,
                                 context: UIGraphicsImageRendererContext) {
        guard let cgImage = source.cgImage else {
            drawSolid(rect: rect, context: context)
            return
        }
        // Blur a slightly larger area so the edges do not stay sharp, then clip
        // back to the requested rectangle.
        let padding = max(4, rect.height * 0.5)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let sampleRect = rect.insetBy(dx: -padding, dy: -padding).intersection(bounds).integral
        guard !sampleRect.isEmpty, let cropped = cgImage.cropping(to: sampleRect) else {
            drawSolid(rect: rect, context: context)
            return
        }

        let radius = blurRadius(for: rect, strength: item.strength)
        guard let blurred = blurred(cropped, radius: radius) else {
            drawSolid(rect: rect, context: context)
            return
        }

        context.cgContext.saveGState()
        context.cgContext.clip(to: rect)
        context.cgContext.interpolationQuality = .high
        blurred.draw(in: sampleRect)
        context.cgContext.restoreGState()
    }

    /// Radius in pixels: a quarter of the text height already makes a line
    /// unreadable, and full strength smears it into a soft band of the line's own
    /// colours — still visibly a blur, not a block.
    static func blurRadius(for rect: CGRect, strength: Double) -> CGFloat {
        max(3, rect.height * CGFloat(0.15 + 0.4 * min(1, max(0.2, strength))))
    }

    /// Blur by resampling: shrink until one pixel spans about `radius` source
    /// pixels, smooth once more at half that size, then scale back up with bicubic
    /// interpolation.
    ///
    /// This runs on the CPU in Core Graphics. The previous Core Image version fell
    /// back to a solid block whenever the context could not render — which is why
    /// "blur" and "solid" used to come out identical — and a resample has no
    /// context, no GPU texture limit for a 20000 pixel stitch, and gives the same
    /// pixels on every device.
    static func blurred(_ image: CGImage, radius: CGFloat) -> UIImage? {
        let full = CGSize(width: image.width, height: image.height)
        guard full.width >= 1, full.height >= 1, radius > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true

        func resample(_ source: UIImage, to size: CGSize) -> UIImage {
            UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.interpolationQuality = .high
                source.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        func shrunk(_ size: CGSize, by factor: CGFloat) -> CGSize {
            CGSize(width: max(1, (size.width / factor).rounded(.up)),
                   height: max(1, (size.height / factor).rounded(.up)))
        }

        let factor = max(2, radius)
        let small = shrunk(full, by: factor)
        let tiny = shrunk(small, by: 2)

        // Two passes: a single shrink is a box average whose footprint shows as a
        // faint grid when scaled back up; averaging the average rounds it off.
        let first = resample(UIImage(cgImage: image), to: small)
        let second = resample(resample(first, to: tiny), to: small)
        return resample(second, to: full)
    }

    private static func drawSolid(rect: CGRect, context: UIGraphicsImageRendererContext) {
        UIColor(white: 0.13, alpha: 1).setFill()
        context.fill(rect)
    }

    private static func drawSticker(item: RedactionItem,
                                    rect: CGRect,
                                    context: UIGraphicsImageRendererContext) {
        // A sticker must not leave the original readable around its edges.
        UIColor(white: 0.92, alpha: 1).setFill()
        context.fill(rect)
        let symbol = item.stickerSymbol.isEmpty ? "🙈" : item.stickerSymbol
        let fontSize = min(rect.height * 0.9, rect.width * 0.9)
        guard fontSize > 4 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize)
        ]
        let text = symbol as NSString
        let textSize = text.size(withAttributes: attributes)
        let origin = CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
        text.draw(at: origin, withAttributes: attributes)
    }

    private static func drawReplacement(item: RedactionItem,
                                        rect: CGRect,
                                        context: UIGraphicsImageRendererContext,
                                        options: Options) {
        // Opaque plate first: the fake value must not be drawn on top of the real
        // one, or both stay readable.
        UIColor.white.setFill()
        context.fill(rect)

        let text = (item.replacementText ?? "") as NSString
        guard text.length > 0 else { return }
        var fontSize = rect.height * 0.82
        let font: (CGFloat) -> UIFont = { size in
            if let name = options.replacementFontName, let custom = UIFont(name: name, size: size) {
                return custom
            }
            return UIFont.systemFont(ofSize: size)
        }

        // Shrink until the fake value fits the space the original occupied.
        var attributes: [NSAttributedString.Key: Any] = [.font: font(fontSize),
                                                         .foregroundColor: UIColor.black]
        var textSize = text.size(withAttributes: attributes)
        while textSize.width > rect.width, fontSize > 6 {
            fontSize *= 0.92
            attributes[.font] = font(fontSize)
            textSize = text.size(withAttributes: attributes)
        }
        let origin = CGPoint(x: rect.minX, y: rect.midY - textSize.height / 2)
        text.draw(at: origin, withAttributes: attributes)
    }
}
