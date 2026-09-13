import CoreGraphics
import UIKit
import PicSigCore

extension CGImage {
    /// Converts to the 8 bit grayscale buffer the stitching algorithms work on.
    ///
    /// A bitmap context stores its first row at the top of the drawn image, which
    /// is the same convention `GrayImage` and `PixelRect` use, so no flip is
    /// needed here. Getting that wrong would mirror every stitch seam.
    func grayImage(maxWidth: Int? = nil) -> GrayImage? {
        let scale: Double
        if let maxWidth, width > maxWidth, width > 0 {
            scale = Double(maxWidth) / Double(width)
        } else {
            scale = 1
        }
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))

        var pixels = [UInt8](repeating: 255, count: targetWidth * targetHeight)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base,
                                          width: targetWidth,
                                          height: targetHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: targetWidth,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Screenshots can contain transparency; compositing on white keeps the
            // matching stable instead of turning clear pixels into black ones.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            context.interpolationQuality = .medium
            context.draw(self, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return true
        }
        guard success else { return nil }
        return GrayImage(width: targetWidth, height: targetHeight, pixels: pixels)
    }

    var pixelSize: PixelSize { PixelSize(width: width, height: height) }
}

extension UIImage {
    /// Bakes the image orientation into the pixels. Screenshots are always `.up`,
    /// but photos picked from the library are not, and a rotated CGImage would
    /// stitch sideways.
    func normalizedCGImage() -> CGImage? {
        if imageOrientation == .up, let cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}

extension PixelRect {
    var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}

extension PixelSize {
    var cgSize: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
}

/// Vision gained its own `NormalizedRect` in iOS 18, so the bare name is ambiguous
/// in any file that imports both Vision and the core package. Those files spell the
/// core type `CoreRect` instead of repeating the full module path at every use.
typealias CoreRect = PicSigCore.NormalizedRect

extension NormalizedRect {
    func cgRect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
}

extension RGBAColor {
    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }
}

/// Wrapper that lets images cross task boundaries without tripping over
/// `Sendable` checks. Images handed over this way are never mutated afterwards.
struct ImageBox: @unchecked Sendable {
    let image: UIImage

    init(_ image: UIImage) { self.image = image }
}

struct CGImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) { self.image = image }
}
