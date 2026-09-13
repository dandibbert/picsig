import XCTest
import UIKit
@testable import PicSig
import PicSigCore

/// Pixel level checks on the mask styles.
///
/// The styles are the user's choice, so they have to look like what they are
/// called. Blur in particular used to silently fall back to a solid block when
/// the Core Image path could not render, which made the two styles
/// indistinguishable; these tests pin each style to its own signature.
final class RedactionRendererTests: XCTestCase {
    private let phone = "13812345678"

    private func maskedImage(style: RedactionStyle, strength: Double = 1) -> (image: UIImage, rect: CGRect) {
        let image = SyntheticScreenshot.make(rows: [.init(label: "联系电话", value: phone)])
        // The row is drawn at x 32, y 40 with a 26pt font; this box covers the value.
        let box = NormalizedRect(x: 32 / image.size.width,
                                 y: 36 / image.size.height,
                                 width: 320 / image.size.width,
                                 height: 40 / image.size.height)
        let item = RedactionItem(box: box, style: style, strength: strength, category: .custom, isManual: true)
        let plan = RedactionPlan(items: [item],
                                 imageSize: PixelSize(width: Int(image.size.width), height: Int(image.size.height)))
        let masked = RedactionRenderer.apply(plan: plan, to: image)
        return (masked, box.cgRect(in: image.size).integral)
    }

    func testSolidIsAUniformDarkBlock() throws {
        let (image, rect) = maskedImage(style: .solid)
        let stats = try luminance(of: image, in: rect)
        XCTAssertLessThan(stats.mean, 60, "a solid block should be dark, mean was \(stats.mean)")
        XCTAssertLessThan(stats.max - stats.min, 4, "a solid block should be flat")
    }

    func testBlurKeepsTheAreaLightAndSmoothInsteadOfBlack() throws {
        let original = SyntheticScreenshot.make(rows: [.init(label: "联系电话", value: phone)])
        let (image, rect) = maskedImage(style: .blur)
        let before = try luminance(of: original, in: rect)
        let after = try luminance(of: image, in: rect)
        let solid = try luminance(of: maskedImage(style: .solid).image, in: rect)

        // Black text on white averages to a light grey: nowhere near the solid block …
        XCTAssertGreaterThan(after.mean, solid.mean + 80,
                             "blur (mean \(after.mean)) is as dark as solid (mean \(solid.mean))")
        // … but not the original either: the pure black glyph pixels must be gone.
        XCTAssertLessThan(before.min, 30, "fixture has no dark text pixels; the test proves nothing")
        XCTAssertGreaterThan(after.min, before.min + 40, "glyph pixels survived the blur")
        // And it has to be smooth: no hard edges left between neighbouring pixels.
        XCTAssertLessThan(after.maxNeighbourStep, 24,
                          "blur left a hard edge of \(after.maxNeighbourStep) levels")
    }

    func testBlurStrengthChangesTheResult() throws {
        let weakResult = maskedImage(style: .blur, strength: 0.2)
        let strongResult = maskedImage(style: .blur, strength: 1)
        let weak = try luminance(of: weakResult.image, in: weakResult.rect)
        let strong = try luminance(of: strongResult.image, in: strongResult.rect)
        XCTAssertGreaterThan(weak.maxNeighbourStep, strong.maxNeighbourStep,
                             "a weaker blur should keep more detail than a stronger one")
    }

    func testBlurredPhoneNumberIsNotReadable() throws {
        let (image, _) = maskedImage(style: .blur)
        var service = TextRecognitionService()
        service.options.tileHeight = 4000
        service.options.computesCharacterBoxes = false
        let text = try service.recognize(cgImage: XCTUnwrap(image.cgImage)).plainText
        XCTAssertFalse(text.contains(phone), "the number is still readable through the blur:\n\(text)")
    }

    func testMosaicIsBlockyNotFlat() throws {
        let (image, rect) = maskedImage(style: .mosaic)
        let stats = try luminance(of: image, in: rect)
        let solid = try luminance(of: maskedImage(style: .solid).image, in: rect)
        XCTAssertGreaterThan(stats.mean, solid.mean + 60, "mosaic should keep the area's own colours")
        XCTAssertGreaterThan(stats.max - stats.min, 10, "mosaic should still show block to block variation")
    }

    // MARK: - Pixels

    private struct Luminance {
        var mean: Double
        var min: Double
        var max: Double
        /// Largest brightness step between two horizontally adjacent pixels.
        var maxNeighbourStep: Double
    }

    private func luminance(of image: UIImage, in rect: CGRect) throws -> Luminance {
        let cgImage = try XCTUnwrap(image.cgImage)
        let region = rect.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)).integral
        let width = Int(region.width), height = Int(region.height)
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                                                  width: width,
                                                  height: height,
                                                  bitsPerComponent: 8,
                                                  bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // Shift the image so `region` lands on the context's origin.
            context.draw(cgImage, in: CGRect(x: -region.minX,
                                             y: -(CGFloat(cgImage.height) - region.maxY),
                                             width: CGFloat(cgImage.width),
                                             height: CGFloat(cgImage.height)))
        }

        var sum = 0.0, minimum = 255.0, maximum = 0.0, step = 0.0
        for y in 0..<height {
            var previous: Double?
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
                sum += value
                minimum = Swift.min(minimum, value)
                maximum = Swift.max(maximum, value)
                if let previous { step = Swift.max(step, abs(value - previous)) }
                previous = value
            }
        }
        return Luminance(mean: sum / Double(width * height), min: minimum, max: maximum, maxNeighbourStep: step)
    }
}
