import Foundation

/// Result of aligning the top of one screenshot against the bottom of the
/// previous one.
public struct OverlapMatch: Equatable, Sendable {
    /// Number of rows that appear in both images' content ranges.
    public let overlap: Int
    /// Mean absolute pixel difference (0...255) inside the overlapping area.
    public let cost: Double
    /// 0...1, how much the algorithm trusts this alignment.
    public let confidence: Double
    /// Support for the best competing offset relative to the winner. Values
    /// close to 1 mean the image is repetitive (e.g. a plain list) and the
    /// offset is ambiguous.
    public let ambiguity: Double
    /// Rows the content moved up between the two captures.
    public let scrollDelta: Int
    /// Static chrome measured from this pair once the movement was known.
    public let fixedRegions: FixedRegions

    public init(overlap: Int, cost: Double, confidence: Double, ambiguity: Double,
                scrollDelta: Int = 0, fixedRegions: FixedRegions = .none) {
        self.overlap = overlap
        self.cost = cost
        self.confidence = confidence
        self.ambiguity = ambiguity
        self.scrollDelta = scrollDelta
        self.fixedRegions = fixedRegions
    }
}

/// Finds how far a screenshot has been scrolled relative to the previous one.
///
/// A thin layer over `ScrollAligner` that expresses the answer as an overlap
/// inside the given content ranges, which is what the planners consume.
public enum OverlapDetector {
    public struct Options: Sendable {
        /// Minimum number of shared rows for a match to be plausible.
        public var minOverlap: Int
        /// Height (in full resolution rows) of each voting strip.
        public var stripHeight: Int
        /// Sample every n-th column when comparing rows at full resolution.
        public var columnStride: Int
        /// Downscale factor of the coarse pyramid level.
        public var coarseFactor: Int
        /// Cost at which confidence reaches zero.
        public var acceptableCost: Double
        /// Minimum vertical texture a strip must have to cast a vote.
        public var minTexture: Double
        /// Upper bound on voting strips, spread evenly over the image.
        public var maxStrips: Int
        /// Fraction of the width ignored at each edge, where the scroll indicator
        /// lives.
        public var edgeInsetFraction: Double
        /// Rows sampled during the verification pass.
        public var verificationSamples: Int

        public init(minOverlap: Int = 12,
                    stripHeight: Int = 64,
                    columnStride: Int = 3,
                    coarseFactor: Int = 4,
                    acceptableCost: Double = 14,
                    minTexture: Double = 2.5,
                    maxStrips: Int = 12,
                    edgeInsetFraction: Double = 0.025,
                    verificationSamples: Int = 96) {
            self.minOverlap = minOverlap
            self.stripHeight = stripHeight
            self.columnStride = columnStride
            self.coarseFactor = coarseFactor
            self.acceptableCost = acceptableCost
            self.minTexture = minTexture
            self.maxStrips = maxStrips
            self.edgeInsetFraction = edgeInsetFraction
            self.verificationSamples = verificationSamples
        }

        public static let `default` = Options()

        /// Video frames are noisier (compression artefacts, animations) and the
        /// frame-to-frame delta is small, so the tolerances are looser.
        public static let video = Options(minOverlap: 24,
                                          stripHeight: 48,
                                          columnStride: 3,
                                          coarseFactor: 4,
                                          acceptableCost: 22,
                                          minTexture: 2.0,
                                          maxStrips: 10,
                                          edgeInsetFraction: 0.025,
                                          verificationSamples: 64)
    }

    public static func detect(previous: GrayImage,
                              next: GrayImage,
                              previousContent: Range<Int>? = nil,
                              nextContent: Range<Int>? = nil,
                              options: Options = .default) -> OverlapMatch? {
        let factor = max(1, options.coarseFactor)
        return detect(previous: GrayPyramid(image: previous, factor: factor),
                      next: GrayPyramid(image: next, factor: factor),
                      previousContent: previousContent,
                      nextContent: nextContent,
                      options: options)
    }

    public static func detect(previous: GrayPyramid,
                              next: GrayPyramid,
                              previousContent: Range<Int>? = nil,
                              nextContent: Range<Int>? = nil,
                              options: Options = .default) -> OverlapMatch? {
        guard let alignment = ScrollAligner.align(previous: previous,
                                                  next: next,
                                                  previousRange: previousContent,
                                                  nextRange: nextContent,
                                                  options: options) else { return nil }
        let prevRange = previousContent ?? 0..<previous.height
        let nextRange = nextContent ?? 0..<next.height
        let overlap = sharedRows(previous: prevRange, next: nextRange, scrollDelta: alignment.scrollDelta)
        guard overlap >= options.minOverlap || alignment.scrollDelta == 0 else { return nil }
        return OverlapMatch(overlap: overlap,
                            cost: alignment.cost,
                            confidence: alignment.confidence,
                            ambiguity: alignment.ambiguity,
                            scrollDelta: alignment.scrollDelta,
                            fixedRegions: alignment.fixedRegions)
    }

    /// Rows of `next`'s content range that also appear in `previous`'s content
    /// range once `next` is shifted down by `scrollDelta`.
    public static func sharedRows(previous: Range<Int>, next: Range<Int>, scrollDelta: Int) -> Int {
        let lower = max(next.lowerBound, previous.lowerBound - scrollDelta)
        let upper = min(next.upperBound, previous.upperBound - scrollDelta)
        return max(0, upper - lower)
    }
}
