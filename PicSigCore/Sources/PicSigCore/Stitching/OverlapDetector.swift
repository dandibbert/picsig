import Foundation

/// Result of aligning the top of one screenshot against the bottom of the
/// previous one.
public struct OverlapMatch: Equatable, Sendable {
    /// Number of rows that appear in both images.
    public let overlap: Int
    /// Mean absolute pixel difference (0...255) inside the overlapping area.
    public let cost: Double
    /// 0...1, how much the algorithm trusts this alignment.
    public let confidence: Double
    /// Ratio between the best and the runner-up candidate. Values close to 1
    /// mean the image is repetitive (e.g. a plain list) and the offset is
    /// ambiguous.
    public let ambiguity: Double

    public init(overlap: Int, cost: Double, confidence: Double, ambiguity: Double) {
        self.overlap = overlap
        self.cost = cost
        self.confidence = confidence
        self.ambiguity = ambiguity
    }
}

/// Finds how far a screenshot has been scrolled relative to the previous one.
///
/// Strategy: take a strongly textured strip from the top of the *next* image and
/// slide it over the *previous* image. The offset with the smallest mean
/// absolute difference wins. A coarse pass on a 1/4 scale pyramid narrows the
/// search down, a full resolution pass refines it to the exact row, and a final
/// verification pass measures the cost across the whole overlapping area.
public enum OverlapDetector {
    public struct Options: Sendable {
        /// Minimum number of shared rows for a match to be plausible.
        public var minOverlap: Int
        /// Height (in full resolution rows) of the strip taken from `next`.
        public var stripHeight: Int
        /// Sample every n-th column when comparing rows.
        public var columnStride: Int
        /// Downscale factor of the coarse pyramid level.
        public var coarseFactor: Int
        /// Cost at which confidence reaches zero.
        public var acceptableCost: Double
        /// Minimum vertical texture a strip must have to be used as an anchor.
        public var minTexture: Double
        /// How far down the strip search may move to find textured content.
        public var maxStripSearchFraction: Double
        /// Rows sampled during the verification pass.
        public var verificationSamples: Int

        public init(minOverlap: Int = 12,
                    stripHeight: Int = 64,
                    columnStride: Int = 3,
                    coarseFactor: Int = 4,
                    acceptableCost: Double = 14,
                    minTexture: Double = 2.5,
                    maxStripSearchFraction: Double = 0.5,
                    verificationSamples: Int = 96) {
            self.minOverlap = minOverlap
            self.stripHeight = stripHeight
            self.columnStride = columnStride
            self.coarseFactor = coarseFactor
            self.acceptableCost = acceptableCost
            self.minTexture = minTexture
            self.maxStripSearchFraction = maxStripSearchFraction
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
                                          maxStripSearchFraction: 0.6,
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
        guard !previous.full.isEmpty, !next.full.isEmpty else { return nil }
        let prevRange = clamp(previousContent ?? 0..<previous.height, to: previous.height)
        let nextRange = clamp(nextContent ?? 0..<next.height, to: next.height)
        let maxOverlap = min(prevRange.count, nextRange.count)
        guard maxOverlap >= options.minOverlap else { return nil }

        guard let strip = selectStrip(in: next, content: nextRange, options: options) else { return nil }

        // --- coarse pass -----------------------------------------------------
        let factor = max(1, previous.factor)
        let coarseStripLower = strip.lowerBound / factor
        let coarseStripUpper = max(coarseStripLower + 2, strip.upperBound / factor)
        let coarseCandidates = searchOffsets(strip: coarseStripLower..<coarseStripUpper,
                                             source: next.coarse,
                                             target: previous.coarse,
                                             searchRange: previous.coarseRange(prevRange),
                                             columnStride: max(1, options.columnStride / 2),
                                             rowStride: 1)
        guard let coarseBest = coarseCandidates.best else { return nil }

        // --- refinement at full resolution -----------------------------------
        let center = coarseBest.offset * factor
        let slack = factor * 2 + 2
        let lowestOffset = max(prevRange.lowerBound, center - slack)
        let highestOffset = min(prevRange.upperBound - strip.count, center + slack)
        guard highestOffset >= lowestOffset else { return nil }
        let refined = searchOffsets(strip: strip,
                                    source: next.full,
                                    target: previous.full,
                                    searchRange: lowestOffset..<(highestOffset + strip.count),
                                    columnStride: options.columnStride,
                                    rowStride: 2)
        guard let best = refined.best else { return nil }

        // Map the matched strip position back to an overlap length.
        let stripOffsetInNext = strip.lowerBound - nextRange.lowerBound
        let alignedNextTop = best.offset - stripOffsetInNext
        let overlap = prevRange.upperBound - alignedNextTop
        guard overlap >= options.minOverlap, overlap <= maxOverlap else { return nil }

        // --- verification over the whole overlapping area ---------------------
        let verifyCost = meanDifference(source: next.full,
                                        sourceStart: nextRange.lowerBound,
                                        target: previous.full,
                                        targetStart: prevRange.upperBound - overlap,
                                        rows: overlap,
                                        columnStride: options.columnStride,
                                        maxSamples: options.verificationSamples)

        let ambiguity: Double
        if let runnerUp = coarseCandidates.runnerUp, runnerUp.cost > 0 {
            ambiguity = min(1, max(0, coarseBest.cost / runnerUp.cost))
        } else {
            ambiguity = 0
        }

        let costConfidence = 1 - min(1, verifyCost / max(1, options.acceptableCost))
        let lengthConfidence = min(1, Double(overlap) / Double(max(options.minOverlap * 4, 1)))
        let uniqueness = 1 - ambiguity * 0.5
        let confidence = max(0, min(1, costConfidence * uniqueness * (0.6 + 0.4 * lengthConfidence)))

        return OverlapMatch(overlap: overlap, cost: verifyCost, confidence: confidence, ambiguity: ambiguity)
    }

    // MARK: - Internals

    private struct Candidate {
        let offset: Int
        let cost: Double
    }

    private struct SearchResult {
        let best: Candidate?
        let runnerUp: Candidate?
    }

    private static func clamp(_ range: Range<Int>, to limit: Int) -> Range<Int> {
        let lower = max(0, min(range.lowerBound, limit))
        let upper = max(lower, min(range.upperBound, limit))
        return lower..<upper
    }

    /// Picks the anchor strip: the first sufficiently textured window at the top
    /// of the content area. Anchoring on a blank band (a white gap between
    /// cards, a solid background) is the classic reason naive stitchers align
    /// screenshots one row off.
    private static func selectStrip(in image: GrayPyramid,
                                    content: Range<Int>,
                                    options: Options) -> Range<Int>? {
        let height = min(max(8, options.stripHeight), max(8, content.count / 2))
        guard content.count >= height else { return nil }
        let lastStart = content.upperBound - height
        let searchLimit = min(lastStart,
                              content.lowerBound + Int(Double(content.count) * options.maxStripSearchFraction))
        var bestStart = content.lowerBound
        var bestTexture = -1.0
        var start = content.lowerBound
        let step = max(4, height / 4)
        while start <= searchLimit {
            let texture = verticalTexture(of: image.full,
                                          rows: start..<(start + height),
                                          columnStride: options.columnStride)
            if texture >= options.minTexture {
                return start..<(start + height)
            }
            if texture > bestTexture {
                bestTexture = texture
                bestStart = start
            }
            start += step
        }
        guard bestTexture > 0.2 else { return nil }
        return bestStart..<(bestStart + height)
    }

    /// Mean absolute difference between neighbouring rows: a direct measure of
    /// how well a vertical offset can be pinned down inside this window.
    static func verticalTexture(of image: GrayImage, rows: Range<Int>, columnStride: Int) -> Double {
        guard rows.count > 1, rows.upperBound <= image.height else { return 0 }
        var total = 0.0
        var count = 0.0
        for y in rows.lowerBound..<(rows.upperBound - 1) {
            total += image.rowDifference(y, to: image, row: y + 1, stride: columnStride)
            count += 1
        }
        return count > 0 ? total / count : 0
    }

    private static func searchOffsets(strip: Range<Int>,
                                      source: GrayImage,
                                      target: GrayImage,
                                      searchRange: Range<Int>,
                                      columnStride: Int,
                                      rowStride: Int) -> SearchResult {
        let stripHeight = strip.count
        guard stripHeight > 0, strip.upperBound <= source.height else {
            return SearchResult(best: nil, runnerUp: nil)
        }
        let lower = max(0, searchRange.lowerBound)
        let upper = min(target.height, searchRange.upperBound) - stripHeight
        guard upper >= lower else { return SearchResult(best: nil, runnerUp: nil) }

        var costs = [Double]()
        costs.reserveCapacity(upper - lower + 1)
        for offset in lower...upper {
            var total = 0.0
            var count = 0.0
            var row = strip.lowerBound
            while row < strip.upperBound {
                total += source.rowDifference(row, to: target,
                                              row: offset + (row - strip.lowerBound),
                                              stride: columnStride)
                count += 1
                row += max(1, rowStride)
            }
            costs.append(count > 0 ? total / count : Double.greatestFiniteMagnitude)
        }

        guard let minIndex = costs.indices.min(by: { costs[$0] < costs[$1] }) else {
            return SearchResult(best: nil, runnerUp: nil)
        }
        let best = Candidate(offset: lower + minIndex, cost: costs[minIndex])

        // The runner-up must be outside a small exclusion window, otherwise the
        // neighbouring offsets of the same minimum would be reported.
        let exclusion = max(2, stripHeight / 8)
        var runnerUp: Candidate?
        for (index, cost) in costs.enumerated() where abs(index - minIndex) > exclusion {
            if runnerUp == nil || cost < runnerUp!.cost {
                runnerUp = Candidate(offset: lower + index, cost: cost)
            }
        }
        return SearchResult(best: best, runnerUp: runnerUp)
    }

    /// Mean absolute difference between two aligned regions, sampling at most
    /// `maxSamples` rows.
    static func meanDifference(source: GrayImage,
                               sourceStart: Int,
                               target: GrayImage,
                               targetStart: Int,
                               rows: Int,
                               columnStride: Int,
                               maxSamples: Int) -> Double {
        guard rows > 0 else { return 0 }
        let usableRows = min(rows,
                             min(source.height - sourceStart, target.height - targetStart))
        guard usableRows > 0, sourceStart >= 0, targetStart >= 0 else { return .greatestFiniteMagnitude }
        let sampleCount = min(usableRows, max(1, maxSamples))
        var total = 0.0
        for index in 0..<sampleCount {
            let rowOffset = usableRows == sampleCount
                ? index
                : Int((Double(index) + 0.5) * Double(usableRows) / Double(sampleCount))
            total += source.rowDifference(sourceStart + rowOffset,
                                          to: target,
                                          row: targetStart + rowOffset,
                                          stride: columnStride)
        }
        return total / Double(sampleCount)
    }
}
