import Foundation

/// Two level image pyramid (full resolution + coarse) used by the matching
/// algorithms. Building it once per source image keeps the coarse-to-fine
/// search cheap when a sequence of 20+ screenshots is stitched.
public struct GrayPyramid: Sendable {
    public let full: GrayImage
    public let coarse: GrayImage
    public let factor: Int

    public init(image: GrayImage, factor: Int = 4) {
        let clampedFactor = max(1, factor)
        self.full = image
        self.factor = clampedFactor
        self.coarse = clampedFactor == 1 ? image : image.downsampled(factorX: clampedFactor, factorY: clampedFactor)
    }

    public var width: Int { full.width }
    public var height: Int { full.height }
    public var size: PixelSize { full.size }

    public func coarseRange(_ range: Range<Int>) -> Range<Int> {
        let lower = range.lowerBound / factor
        let upper = max(lower + 1, range.upperBound / factor)
        return lower..<min(upper, max(1, coarse.height))
    }

    /// Pyramid of the transposed image, so horizontal stitching can reuse the
    /// vertical code paths.
    public func transposed() -> GrayPyramid {
        GrayPyramid(image: full.transposed(), factor: factor)
    }
}
