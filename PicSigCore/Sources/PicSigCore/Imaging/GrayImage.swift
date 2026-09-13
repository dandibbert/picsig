import Foundation

/// A row-major 8 bit grayscale buffer.
///
/// Every stitching algorithm works on this representation: converting a
/// `CGImage` once and then matching on grayscale is both much faster and much
/// more robust than comparing colour pixels, and it keeps the algorithms free of
/// any platform dependency.
public struct GrayImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0, "negative dimensions")
        precondition(pixels.count == width * height, "pixel buffer does not match dimensions")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, repeating value: UInt8 = 0) {
        self.init(width: width, height: height,
                  pixels: [UInt8](repeating: value, count: max(0, width * height)))
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    @inline(__always)
    public func pixel(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    public mutating func setPixel(x: Int, y: Int, value: UInt8) {
        pixels[y * width + x] = value
    }

    public func row(_ y: Int) -> ArraySlice<UInt8> {
        pixels[(y * width)..<((y + 1) * width)]
    }

    public func cropped(to rect: PixelRect) -> GrayImage {
        let r = rect.clamped(to: size)
        guard !r.isEmpty else { return GrayImage(width: 0, height: 0, pixels: []) }
        var out = [UInt8]()
        out.reserveCapacity(r.area)
        for y in r.minY..<r.maxY {
            let start = y * width + r.minX
            out.append(contentsOf: pixels[start..<(start + r.width)])
        }
        return GrayImage(width: r.width, height: r.height, pixels: out)
    }

    /// Box-filter downsample. `factorX`/`factorY` are integer divisors.
    public func downsampled(factorX: Int, factorY: Int) -> GrayImage {
        let fx = max(1, factorX)
        let fy = max(1, factorY)
        if fx == 1 && fy == 1 { return self }
        let newWidth = max(1, width / fx)
        let newHeight = max(1, height / fy)
        var out = [UInt8](repeating: 0, count: newWidth * newHeight)
        for oy in 0..<newHeight {
            let srcYStart = oy * fy
            let srcYEnd = min(height, srcYStart + fy)
            for ox in 0..<newWidth {
                let srcXStart = ox * fx
                let srcXEnd = min(width, srcXStart + fx)
                var sum = 0
                var count = 0
                for sy in srcYStart..<srcYEnd {
                    let rowStart = sy * width
                    for sx in srcXStart..<srcXEnd {
                        sum += Int(pixels[rowStart + sx])
                        count += 1
                    }
                }
                out[oy * newWidth + ox] = count > 0 ? UInt8(sum / count) : 0
            }
        }
        return GrayImage(width: newWidth, height: newHeight, pixels: out)
    }

    /// Rotates the buffer by 90° so that horizontal algorithms can reuse the
    /// vertical implementation. `transposed()[x, y] == self[y, x]`.
    public func transposed() -> GrayImage {
        guard !isEmpty else { return self }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width {
                out[x * height + y] = pixels[rowStart + x]
            }
        }
        return GrayImage(width: height, height: width, pixels: out)
    }

    /// Mean absolute difference between two rows of two images, sampling every
    /// `stride`-th column. Both images must share the same width.
    ///
    /// `insetX` columns at each edge are skipped. The scroll indicator lives in
    /// the right hand gutter and sits at a different height in every capture, so
    /// including it would penalise every correct alignment.
    public func rowDifference(_ y: Int, to other: GrayImage, row otherY: Int,
                              stride: Int = 1, insetX: Int = 0) -> Double {
        let sampleStride = max(1, stride)
        let commonWidth = min(width, other.width)
        let inset = max(0, min(insetX, commonWidth / 4))
        guard commonWidth - 2 * inset > 0 else { return 0 }
        var total = 0
        var count = 0
        var x = inset
        let base = y * width
        let otherBase = otherY * other.width
        while x < commonWidth - inset {
            let a = Int(pixels[base + x])
            let b = Int(other.pixels[otherBase + x])
            total += abs(a - b)
            count += 1
            x += sampleStride
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    /// Fraction of sampled columns whose values are within `tolerance` of each
    /// other.
    ///
    /// Unlike the mean difference this is not dominated by one small region that
    /// changed: a status bar whose clock ticked still matches on ~90% of its
    /// columns, and a translucent bar whose backdrop shifted a little still
    /// matches wherever the change stayed under the tolerance.
    public func rowMatchFraction(_ y: Int, to other: GrayImage, row otherY: Int,
                                 tolerance: Int, stride: Int = 1, insetX: Int = 0) -> Double {
        let sampleStride = max(1, stride)
        let commonWidth = min(width, other.width)
        let inset = max(0, min(insetX, commonWidth / 4))
        guard commonWidth - 2 * inset > 0 else { return 0 }
        var matches = 0
        var count = 0
        var x = inset
        let base = y * width
        let otherBase = otherY * other.width
        while x < commonWidth - inset {
            if abs(Int(pixels[base + x]) - Int(other.pixels[otherBase + x])) <= tolerance {
                matches += 1
            }
            count += 1
            x += sampleStride
        }
        return count > 0 ? Double(matches) / Double(count) : 0
    }

    /// Standard deviation of a row; near-zero means a flat band (background,
    /// separator, whitespace) which is a bad anchor for matching and a good
    /// place to cut a page.
    public func rowStandardDeviation(_ y: Int, stride: Int = 1) -> Double {
        let sampleStride = max(1, stride)
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        var x = 0
        let base = y * width
        while x < width {
            let value = Double(pixels[base + x])
            sum += value
            sumSquares += value * value
            count += 1
            x += sampleStride
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, (sumSquares / count) - mean * mean).squareRoot()
    }

    /// Row activity profile: one standard deviation value per row.
    public func rowActivityProfile(stride: Int = 4) -> [Double] {
        guard !isEmpty else { return [] }
        return (0..<height).map { rowStandardDeviation($0, stride: stride) }
    }
}
