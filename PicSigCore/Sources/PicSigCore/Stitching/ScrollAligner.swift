import Foundation

/// How two consecutive captures of one scrolling page relate.
public struct ScrollAlignment: Equatable, Sendable {
    /// Rows the content moved up between `previous` and `next`:
    /// `next[y] == previous[y + scrollDelta]` wherever both show content.
    /// Zero means nothing scrolled.
    public let scrollDelta: Int
    /// Mean absolute difference over the shared content, after alignment.
    public let cost: Double
    /// 0...1, how much to trust this.
    public let confidence: Double
    /// Best competing offset's support relative to the winner. Near 1 means the
    /// page is repetitive and several offsets explain it almost as well.
    public let ambiguity: Double
    /// Rows at the top and bottom that stayed put while the content moved.
    public let fixedRegions: FixedRegions
    /// Independent strips that agreed on `scrollDelta`.
    public let supportingStrips: Int

    public init(scrollDelta: Int, cost: Double, confidence: Double, ambiguity: Double,
                fixedRegions: FixedRegions, supportingStrips: Int) {
        self.scrollDelta = scrollDelta
        self.cost = cost
        self.confidence = confidence
        self.ambiguity = ambiguity
        self.fixedRegions = fixedRegions
        self.supportingStrips = supportingStrips
    }
}

/// Finds how far a page scrolled between two screenshots.
///
/// The obvious approach — take a strip from the top of the second shot and slide it
/// over the first — breaks on real captures. It has to know where the navigation
/// bar ends so it does not anchor on it, but on iOS the bars are translucent and
/// their pixels change with the content beneath, so that boundary cannot be found
/// by looking for identical rows. And once the strip lands on the bar, it matches
/// the bar in the previous shot at "no movement", the whole-area check fails, and
/// the fall-back is to append the shots with no overlap at all.
///
/// This aligner turns the problem around. Many textured strips spread over the
/// second shot each vote for the offset where they match best. Strips lying on the
/// chrome vote "did not move" and are set aside; strips lying on content agree on
/// the true scroll distance. Only once that distance is known are the fixed bars
/// measured, as the rows that match at the *same* position better than at the
/// *scrolled* one — a test that works whether the bar is opaque or translucent and
/// is indifferent to a clock that ticked.
public enum ScrollAligner {
    public static func align(previous: GrayPyramid,
                             next: GrayPyramid,
                             previousRange: Range<Int>? = nil,
                             nextRange: Range<Int>? = nil,
                             options: OverlapDetector.Options = .default) -> ScrollAlignment? {
        guard !previous.full.isEmpty, !next.full.isEmpty else { return nil }
        let prevRange = clamp(previousRange ?? 0..<previous.height, to: previous.height)
        let nextRange = clamp(nextRange ?? 0..<next.height, to: next.height)
        guard prevRange.count >= options.minOverlap, nextRange.count >= options.minOverlap else { return nil }

        let factor = max(1, previous.factor)
        let insetFull = Int(Double(next.width) * options.edgeInsetFraction)
        let insetCoarse = max(1, insetFull / factor)

        // --- coarse voting ------------------------------------------------------
        let strips = selectStrips(in: next.coarse,
                                  range: next.coarseRange(nextRange),
                                  stripHeight: max(3, options.stripHeight / factor),
                                  count: options.maxStrips,
                                  minTexture: options.minTexture * 0.5,
                                  insetX: insetCoarse)
        guard !strips.isEmpty else { return nil }

        let coarsePrevRange = previous.coarseRange(prevRange)
        let coarseNextRange = next.coarseRange(nextRange)
        var votes = [Vote]()

        // A vote is worth as much as its minimum stands out. The coarse cost is
        // never near zero — a scroll that is not a multiple of the pyramid factor
        // lands between coarse pixels — so an absolute budget would reject every
        // honest vote; full resolution verification judges the cost later. A strip
        // that matches equally well in two places (a lone separator line, a
        // repeated row) says nothing and is worth nothing.
        func quality(of result: Search) -> Double {
            let epsilon = 0.5
            let uniqueness = result.runnerUp.map {
                max(0, 1 - (result.best.cost + epsilon) / ($0.cost + epsilon))
            } ?? 1
            let plausible = max(0, 1 - result.best.cost / max(1, options.acceptableCost * 6))
            return uniqueness * plausible
        }

        // Strips from `next`, searched at or below their own row in `previous`.
        for strip in strips {
            guard let result = bestOffset(strip: strip,
                                          source: next.coarse,
                                          target: previous.coarse,
                                          searchRange: coarsePrevRange,
                                          minimumOffset: strip.lowerBound,
                                          maximumOffset: nil,
                                          columnStride: 1,
                                          rowStride: 1,
                                          insetX: insetCoarse) else { continue }
            votes.append(Vote(strip: strip,
                              delta: result.best.offset - strip.lowerBound,
                              cost: result.best.cost,
                              quality: quality(of: result),
                              anchoredInNext: true))
        }

        // And strips from `previous`, searched at or above their own row in
        // `next`. Doubling the electorate matters most when little overlaps: only
        // strips that happen to fall inside the shared band can vote for the truth.
        let reverseStrips = selectStrips(in: previous.coarse,
                                         range: coarsePrevRange,
                                         stripHeight: max(3, options.stripHeight / factor),
                                         count: options.maxStrips,
                                         minTexture: options.minTexture * 0.5,
                                         insetX: insetCoarse)
        for strip in reverseStrips {
            guard let result = bestOffset(strip: strip,
                                          source: previous.coarse,
                                          target: next.coarse,
                                          searchRange: coarseNextRange,
                                          minimumOffset: nil,
                                          maximumOffset: strip.lowerBound,
                                          columnStride: 1,
                                          rowStride: 1,
                                          insetX: insetCoarse) else { continue }
            votes.append(Vote(strip: strip,
                              delta: strip.lowerBound - result.best.offset,
                              cost: result.best.cost,
                              quality: quality(of: result),
                              anchoredInNext: false))
        }
        guard !votes.isEmpty else { return nil }

        let minMovingDelta = 2 // coarse rows; anything less is "did not move"
        let clusters = cluster(votes, tolerance: 1).sorted { $0.score > $1.score }
        let moving = clusters.filter { $0.delta >= minMovingDelta }
        let stationary = clusters.first { $0.delta < minMovingDelta }

        let winner: Cluster
        if let bestMoving = moving.first, bestMoving.score >= 0.35 {
            winner = bestMoving
        } else if let stationary, stationary.score >= 0.35 {
            // Nothing moved — if the two really are the same capture. Chrome alone
            // also votes "did not move", so this is checked on the content at full
            // resolution like any other alignment.
            let sharedLower = max(nextRange.lowerBound, prevRange.lowerBound)
            let sharedUpper = min(nextRange.upperBound, prevRange.upperBound)
            let cost = sharedUpper > sharedLower
                ? trimmedMeanDifference(source: next.full, sourceStart: sharedLower,
                                        target: previous.full, targetStart: sharedLower,
                                        rows: sharedUpper - sharedLower, columnStride: options.columnStride,
                                        maxSamples: options.verificationSamples, insetX: insetFull)
                : Double.greatestFiniteMagnitude
            let costConfidence = 1 - min(1, cost / max(1, options.acceptableCost))
            return ScrollAlignment(scrollDelta: 0,
                                   cost: cost,
                                   confidence: costConfidence * min(1, stationary.score),
                                   ambiguity: 0,
                                   fixedRegions: .none,
                                   supportingStrips: stationary.members.count)
        } else if let bestMoving = moving.first {
            winner = bestMoving
        } else {
            return nil
        }
        let runnerUp = moving.first { $0.delta != winner.delta }
        let ambiguity = runnerUp.map { min(1, $0.score / max(0.001, winner.score)) } ?? 0

        // --- full resolution refinement -----------------------------------------
        let coarseDelta = winner.delta * factor
        let slack = factor * 2 + 2
        var refined: (delta: Int, cost: Double)?
        for vote in winner.members.sorted(by: { $0.quality > $1.quality }).prefix(4) {
            let (source, target, sourceRange, targetRange) = vote.anchoredInNext
                ? (next.full, previous.full, nextRange, prevRange)
                : (previous.full, next.full, prevRange, nextRange)
            let lower = max(sourceRange.lowerBound, vote.strip.lowerBound * factor)
            let upper = min(sourceRange.upperBound, lower + options.stripHeight)
            guard upper - lower >= 4 else { continue }
            let strip = lower..<upper
            let centre = vote.anchoredInNext ? strip.lowerBound + coarseDelta : strip.lowerBound - coarseDelta
            let search = max(targetRange.lowerBound, centre - slack)..<min(targetRange.upperBound, centre + slack + strip.count)
            guard let result = bestOffset(strip: strip,
                                          source: source,
                                          target: target,
                                          searchRange: search,
                                          minimumOffset: vote.anchoredInNext ? strip.lowerBound : nil,
                                          maximumOffset: vote.anchoredInNext ? nil : strip.lowerBound,
                                          columnStride: options.columnStride,
                                          rowStride: 1,
                                          insetX: insetFull) else { continue }
            let delta = vote.anchoredInNext
                ? result.best.offset - strip.lowerBound
                : strip.lowerBound - result.best.offset
            if refined == nil || result.best.cost < refined!.cost { refined = (delta, result.best.cost) }
        }
        guard let refined, refined.delta > 0 else { return nil }
        let delta = refined.delta

        // --- fixed chrome, now that the movement is known --------------------------
        let fixed = fixedRegions(previous: previous.full, next: next.full, delta: delta,
                                 maxFraction: 0.35, insetX: insetFull, stride: options.columnStride)

        // --- verification over the shared content ---------------------------------
        let sharedLower = max(nextRange.lowerBound, fixed.topLength, prevRange.lowerBound - delta)
        let sharedUpper = min(nextRange.upperBound, next.height - fixed.bottomLength,
                              prevRange.upperBound - delta, previous.height - fixed.bottomLength - delta)
        let sharedRows = max(0, sharedUpper - sharedLower)
        let cost = sharedRows > 0
            ? trimmedMeanDifference(source: next.full, sourceStart: sharedLower,
                                    target: previous.full, targetStart: sharedLower + delta,
                                    rows: sharedRows, columnStride: options.columnStride,
                                    maxSamples: options.verificationSamples, insetX: insetFull)
            : Double.greatestFiniteMagnitude

        let costConfidence = 1 - min(1, cost / max(1, options.acceptableCost))
        let support = min(1, Double(winner.members.count) / 3)
        let uniqueness = 1 - ambiguity * 0.5
        let lengthConfidence = min(1, Double(sharedRows) / Double(max(options.minOverlap * 4, 1)))
        let confidence = max(0, min(1, costConfidence * (0.5 + 0.5 * support) * uniqueness * (0.6 + 0.4 * lengthConfidence)))

        return ScrollAlignment(scrollDelta: delta,
                               cost: cost,
                               confidence: confidence,
                               ambiguity: ambiguity,
                               fixedRegions: fixed,
                               supportingStrips: winner.members.count)
    }

    // MARK: - Fixed chrome

    /// Rows at either end that match the other shot at the same position better
    /// than at the scrolled position.
    ///
    /// Flat rows (white gaps) match equally well either way and are left
    /// undecided; the band ends at the last row that clearly stayed put, so a blank
    /// gap after the bar is never mistaken for part of it. The scan stops at the
    /// first run of rows that clearly moved, which keeps a live element deep in the
    /// content (a spinner, a ticking timestamp) from ever being read as chrome.
    ///
    /// The match tolerance is generous on purpose: a translucent bar's tint moves
    /// by a couple of dozen levels depending on what is blurred beneath it, while
    /// text against its background differs by two hundred, so there is room.
    static func fixedRegions(previous: GrayImage, next: GrayImage, delta: Int,
                             maxFraction: Double, insetX: Int, stride: Int) -> FixedRegions {
        let height = min(previous.height, next.height)
        let limit = Int(Double(height) * maxFraction)
        let tolerance = 28
        let margin = 0.15
        // Text lines are never this thin, so this many moving rows in a row is
        // content, not a glitch.
        let movingRunToStop = 3

        var top = 0
        var movingRun = 0
        var y = 0
        while y < limit {
            let same = next.rowMatchFraction(y, to: previous, row: y, tolerance: tolerance, stride: stride, insetX: insetX)
            let shifted = y + delta < previous.height
                ? next.rowMatchFraction(y, to: previous, row: y + delta, tolerance: tolerance, stride: stride, insetX: insetX)
                : 0
            let score = same - shifted
            if score > margin {
                top = y + 1
                movingRun = 0
            } else if score < -margin {
                movingRun += 1
                if movingRun >= movingRunToStop { break }
            } else {
                movingRun = 0
            }
            y += 1
        }

        var bottom = 0
        movingRun = 0
        var b = 0
        while b < limit {
            let py = previous.height - 1 - b
            let ny = next.height - 1 - b
            let same = previous.rowMatchFraction(py, to: next, row: ny, tolerance: tolerance, stride: stride, insetX: insetX)
            let shifted = py - delta >= 0
                ? previous.rowMatchFraction(py, to: next, row: py - delta, tolerance: tolerance, stride: stride, insetX: insetX)
                : 0
            let score = same - shifted
            if score > margin {
                bottom = b + 1
                movingRun = 0
            } else if score < -margin {
                movingRun += 1
                if movingRun >= movingRunToStop { break }
            } else {
                movingRun = 0
            }
            b += 1
        }

        return FixedRegions(topLength: top >= 4 ? top : 0, bottomLength: bottom >= 4 ? bottom : 0)
    }

    // MARK: - Strips

    struct Vote {
        let strip: Range<Int>
        let delta: Int
        let cost: Double
        let quality: Double
        /// Whether `strip` is a row range of `next` (searched in `previous`) or of
        /// `previous` (searched in `next`).
        let anchoredInNext: Bool
    }

    struct Cluster {
        var delta: Int
        var members: [Vote]
        var score: Double { members.reduce(0) { $0 + $1.quality } }
    }

    struct Candidate {
        let offset: Int
        let cost: Double
    }

    struct Search {
        let best: Candidate
        let runnerUp: Candidate?
    }

    /// Picks up to `count` textured windows spread evenly over `range`. Spreading
    /// matters more than picking the very best ones: the point is to land some
    /// strips on content no matter where the chrome is.
    static func selectStrips(in image: GrayImage,
                                     range: Range<Int>,
                                     stripHeight: Int,
                                     count: Int,
                                     minTexture: Double,
                                     insetX: Int) -> [Range<Int>] {
        guard range.count >= stripHeight, count > 0 else { return [] }
        let bandHeight = max(stripHeight, range.count / count)
        var strips = [Range<Int>]()
        var bandStart = range.lowerBound
        while bandStart + stripHeight <= range.upperBound {
            let bandEnd = min(range.upperBound, bandStart + bandHeight)
            var best: (start: Int, texture: Double)?
            var start = bandStart
            let step = max(1, stripHeight / 2)
            while start + stripHeight <= bandEnd {
                let texture = verticalTexture(of: image, rows: start..<(start + stripHeight), insetX: insetX)
                if best == nil || texture > best!.texture { best = (start, texture) }
                start += step
            }
            if let best, best.texture >= minTexture {
                strips.append(best.start..<(best.start + stripHeight))
            }
            bandStart = bandEnd
        }
        return strips
    }

    /// Mean absolute difference between neighbouring rows: how well a vertical
    /// offset can be pinned down inside this window.
    static func verticalTexture(of image: GrayImage, rows: Range<Int>, insetX: Int) -> Double {
        guard rows.count > 1, rows.upperBound <= image.height else { return 0 }
        var total = 0.0
        for y in rows.lowerBound..<(rows.upperBound - 1) {
            total += image.rowDifference(y, to: image, row: y + 1, stride: 1, insetX: insetX)
        }
        return total / Double(rows.count - 1)
    }

    /// Slides `strip` (rows of `source`) over `target` and returns the offset with
    /// the lowest mean difference, plus the best offset outside a small window
    /// around it.
    ///
    /// Content only moves up between captures, so a strip from the later shot can
    /// only match at or below its own row in the earlier one (`minimumOffset`), and
    /// a strip from the earlier shot only at or above its row in the later one
    /// (`maximumOffset`).
    static func bestOffset(strip: Range<Int>,
                           source: GrayImage,
                           target: GrayImage,
                           searchRange: Range<Int>,
                           minimumOffset: Int?,
                           maximumOffset: Int?,
                           columnStride: Int,
                           rowStride: Int,
                           insetX: Int) -> Search? {
        let stripHeight = strip.count
        guard stripHeight > 0, strip.upperBound <= source.height else { return nil }
        let lower = max(0, searchRange.lowerBound, minimumOffset ?? 0)
        let upper = min(min(target.height, searchRange.upperBound) - stripHeight, maximumOffset ?? .max)
        guard upper >= lower else { return nil }

        var costs = [Double]()
        costs.reserveCapacity(upper - lower + 1)
        for offset in lower...upper {
            var total = 0.0
            var count = 0.0
            var row = strip.lowerBound
            while row < strip.upperBound {
                total += source.rowDifference(row, to: target, row: offset + (row - strip.lowerBound),
                                              stride: columnStride, insetX: insetX)
                count += 1
                row += max(1, rowStride)
            }
            costs.append(count > 0 ? total / count : .greatestFiniteMagnitude)
        }

        guard let minIndex = costs.indices.min(by: { costs[$0] < costs[$1] }) else { return nil }
        let best = Candidate(offset: lower + minIndex, cost: costs[minIndex])
        let exclusion = max(2, stripHeight / 8)
        var runnerUp: Candidate?
        for (index, cost) in costs.enumerated() where abs(index - minIndex) > exclusion {
            if runnerUp == nil || cost < runnerUp!.cost {
                runnerUp = Candidate(offset: lower + index, cost: cost)
            }
        }
        return Search(best: best, runnerUp: runnerUp)
    }

    static func cluster(_ votes: [Vote], tolerance: Int) -> [Cluster] {
        var clusters = [Cluster]()
        for vote in votes.sorted(by: { $0.delta < $1.delta }) {
            if var last = clusters.last, abs(last.delta - vote.delta) <= tolerance {
                last.members.append(vote)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(Cluster(delta: vote.delta, members: [vote]))
            }
        }
        // Represent each cluster by its best member's offset.
        return clusters.map { cluster in
            var cluster = cluster
            cluster.delta = cluster.members.max(by: { $0.quality < $1.quality })?.delta ?? cluster.delta
            return cluster
        }
    }

    /// Mean of the best 80% of sampled row differences, sampled from rows that
    /// carry information.
    ///
    /// On a mostly white page a wrong alignment still compares blank rows against
    /// blank rows, so averaging over every row would call it a good match. Only
    /// rows with some texture can tell a right alignment from a wrong one; blank
    /// rows are used only when there is nothing else. Trimming the worst fifth keeps
    /// a timestamp that updated or a "typing…" indicator from sinking an otherwise
    /// perfect alignment.
    static func trimmedMeanDifference(source: GrayImage, sourceStart: Int,
                                      target: GrayImage, targetStart: Int,
                                      rows: Int, columnStride: Int, maxSamples: Int, insetX: Int) -> Double {
        guard rows > 0 else { return 0 }
        let usableRows = min(rows, min(source.height - sourceStart, target.height - targetStart))
        guard usableRows > 0, sourceStart >= 0, targetStart >= 0 else { return .greatestFiniteMagnitude }

        let probeStride = max(1, usableRows / max(1, maxSamples * 4))
        var textured = [Int]()
        var offset = 0
        while offset < usableRows {
            if source.rowStandardDeviation(sourceStart + offset, stride: 4) >= 8 {
                textured.append(offset)
            }
            offset += probeStride
        }

        let candidates: [Int]
        if textured.count >= 8 {
            candidates = textured
        } else {
            candidates = Array(Swift.stride(from: 0, to: usableRows, by: probeStride))
        }
        let sampleCount = min(candidates.count, max(1, maxSamples))
        var costs = [Double]()
        costs.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let pick = candidates.count == sampleCount
                ? candidates[index]
                : candidates[Int((Double(index) + 0.5) * Double(candidates.count) / Double(sampleCount))]
            costs.append(source.rowDifference(sourceStart + pick, to: target, row: targetStart + pick,
                                              stride: columnStride, insetX: insetX))
        }
        costs.sort()
        let kept = max(1, Int(Double(costs.count) * 0.8))
        return costs.prefix(kept).reduce(0, +) / Double(kept)
    }

    private static func clamp(_ range: Range<Int>, to limit: Int) -> Range<Int> {
        let lower = max(0, min(range.lowerBound, limit))
        let upper = max(lower, min(range.upperBound, limit))
        return lower..<upper
    }
}
