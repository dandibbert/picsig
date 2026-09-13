import Foundation

/// A narrow grayscale raster can retain full vertical resolution without retaining a full bitmap.
public struct GrayRaster: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width >= 8, height >= 8, width <= 1024, height <= 16384,
              pixels.count == width * height else { throw PicSigError.invalidImage }
        self.width = width; self.height = height; self.pixels = pixels
    }
    public func removing(top: Int, bottom: Int) throws -> GrayRaster {
        let start = max(0, top), end = height - max(0, bottom)
        guard end - start >= 8 else { throw PicSigError.invalidGeometry }
        return try GrayRaster(width: width, height: end - start, pixels: Array(pixels[(start * width)..<(end * width)]))
    }
}

public struct OverlapMatch: Sendable {
    public var rows: Int
    public var confidence: Double
    public var duplicate: Bool
}

public enum OverlapDetector {

    public static func difference(_ a: GrayRaster, _ b: GrayRaster) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        var sum = 0.0, count = 0
        for i in stride(from: 0, to: a.pixels.count, by: max(1, a.pixels.count / 4096)) {
            sum += Double(abs(Int(a.pixels[i]) - Int(b.pixels[i]))); count += 1
        }
        return sum / Double(max(1, count))
    }

    /// Anchor matching uses actual horizontal detail, not a mean of predominantly white rows.
    /// Each independently matched text/image strip votes for a vertical translation. A second,
    /// dense pass checks that translation before any source pixels are removed.
    public static func match(_ a: GrayRaster, _ b: GrayRaster) -> OverlapMatch? {
        translatedMatch(a, b, chrome: false)
    }

    /// Fallback on the ORIGINAL viewports. Browser bars must not destroy the evidence needed
    /// to find the scrolling displacement. `rows` includes chrome; subtract crop insets later.
    public static func viewportMatch(_ a: GrayRaster, _ b: GrayRaster) -> OverlapMatch? {
        translatedMatch(a, b, chrome: true)
    }

    private struct AnchorVote { var count = 0; var error = 0.0 }
    private struct Verified { var rows: Int; var error: Double; var support: Double; var good: Int }

    private static func translatedMatch(_ a: GrayRaster, _ b: GrayRaster, chrome: Bool) -> OverlapMatch? {
        guard a.width == b.width else { return nil }
        if difference(a, b) < 1.1 { return OverlapMatch(rows: b.height, confidence: 1, duplicate: true) }
        let w = a.width, lanes = 24, patch = 8
        let inset = max(1, w / 32)
        let xs = (0..<lanes).map { inset + $0 * (w - inset * 2 - 1) / (lanes - 1) }
        func signatures(_ raster: GrayRaster) -> [Int] {
            var result = [Int](); result.reserveCapacity(raster.height * lanes)
            for y in 0..<raster.height {
                for x in xs { result.append(Int(raster.pixels[y * w + x])) }
            }
            return result
        }
        let ap = signatures(a), bp = signatures(b)
        // More than one anchor per typical text line; blank/flat bands do not get a vote.
        let bin = max(8, b.height / 64)
        var anchors: [Int] = []
        for low in stride(from: 1, to: min(b.height, a.height) - patch, by: bin) {
            var best = low, strength = 0
            for y in low..<min(low + bin, b.height - patch) {
                var texture = 0
                for lane in 1..<lanes {
                    texture += abs(bp[y * lanes + lane] - bp[y * lanes + lane - 1])
                    texture += abs(bp[y * lanes + lane] - bp[(y + 3) * lanes + lane])
                }
                if texture > strength { best = y; strength = texture }
            }
            if strength > lanes * 3 { anchors.append(best) }
        }
        guard anchors.count >= 2 else { return nil }
        var votes: [Int: AnchorVote] = [:]
        for by in anchors {
            if Task.isCancelled { return nil }
            var bestError = Double.infinity, bestShift = 0
            guard a.height - patch > by else { continue }
            for ay in (by + 1)..<(a.height - patch) {
                var error = 0
                // Full-resolution vertical samples avoid aliasing small text and thin separators.
                for dy in [0, 2, 4, 7] {
                    let ai = (ay + dy) * lanes, bi = (by + dy) * lanes
                    for lane in 0..<lanes { error += abs(ap[ai + lane] - bp[bi + lane]) }
                }
                let value = Double(error) / Double(lanes * 4)
                if value < bestError { bestError = value; bestShift = ay - by }
            }
            if bestError < 12 {
                var vote = votes[bestShift] ?? AnchorVote()
                vote.count += 1; vote.error += bestError; votes[bestShift] = vote
            }
        }
        let seeds = votes.keys.sorted {
            let l = votes[$0]!, r = votes[$1]!
            return l.count == r.count ? l.error / Double(l.count) < r.error / Double(r.count) : l.count > r.count
        }.prefix(16)
        var shifts = Set<Int>()
        for seed in seeds { for shift in max(1, seed - 2)...(seed + 2) { shifts.insert(shift) } }
        var verified: [Verified] = []
        for shift in shifts {
            let rows = min(a.height - shift, b.height)
            guard rows >= 24 else { continue }
            var good = 0, informative = 0, errors: [Double] = [], first = rows, last = 0
            let yStep = max(1, rows / 600)
            for y in stride(from: 1, to: rows - 1, by: yStep) {
                let ai = (y + shift) * lanes, bi = y * lanes
                var error = 0, texture = 0
                for lane in 1..<lanes {
                    error += abs(ap[ai + lane] - bp[bi + lane])
                    texture += max(abs(ap[ai + lane] - ap[ai + lane - 1]), abs(bp[bi + lane] - bp[bi + lane - 1]))
                    texture += max(abs(ap[ai + lane] - ap[ai - lanes + lane]), abs(bp[bi + lane] - bp[bi - lanes + lane]))
                }
                guard texture > (lanes - 1) * 3 else { continue }
                informative += 1
                let e = Double(error) / Double(lanes - 1)
                errors.append(e)
                if e < 10 { good += 1; first = min(first, y); last = y }
            }
            guard informative >= 12, good >= 12, last - first >= 16 else { continue }
            let support = Double(good) / Double(informative)
            guard support >= (chrome ? 0.48 : 0.82) else { continue }
            errors.sort()
            let kept = max(1, Int(Double(errors.count) * (chrome ? 0.55 : 0.90)))
            let error = errors.prefix(kept).reduce(0, +) / Double(kept)
            guard error < 9 else { continue }
            verified.append(Verified(rows: a.height - shift, error: error, support: support, good: good))
        }
        verified.sort { l, r in
            let ls = l.support - l.error / 30, rs = r.support - r.error / 30
            return abs(ls - rs) < 0.005 ? l.good > r.good : ls > rs
        }
        guard let best = verified.first else { return nil }
        if let other = verified.first(where: { abs($0.rows - best.rows) > 5 }),
           abs(other.error - best.error) < max(0.08, best.error * 0.12), abs(other.support - best.support) < 0.04,
           Double(min(other.good, best.good)) / Double(max(other.good, best.good)) > 0.8 { return nil }
        return OverlapMatch(rows: min(best.rows, b.height), confidence: min(1, max(0.45, best.support * (1 - best.error / 24))), duplicate: best.rows >= b.height)
    }

    /// Detects UI chrome that stays pinned to the outer edge while the page content moves.
    /// A trimmed row metric deliberately ignores a minority of changing pixels (clock text,
    /// loading indicators, translucent chrome) instead of requiring every pixel to be identical.
    public static func fixedInsets(_ a: GrayRaster, _ b: GrayRaster) -> (top: Int, bottom: Int) {
        guard a.width == b.width, difference(a, b) > 0.35 else { return (0, 0) }
        let limit = min(a.height, b.height) * 18 / 100
        let xInset = max(1, a.width / 5)

        func rowIsStable(_ ay: Int, _ by: Int) -> Bool {
            var diffs: [Int] = []
            diffs.reserveCapacity(max(1, a.width - xInset * 2))
            for x in xInset..<(a.width - xInset) {
                diffs.append(abs(Int(a.pixels[ay * a.width + x]) - Int(b.pixels[by * b.width + x])))
            }
            guard !diffs.isEmpty else { return false }
            diffs.sort()
            let kept = max(4, diffs.count * 9 / 10)
            let trimmedMean = Double(diffs.prefix(kept).reduce(0, +)) / Double(kept)
            let q75 = diffs[min(diffs.count - 1, kept - 1)]
            return trimmedMean < 5.0 && q75 < 15
        }

        func count(fromBottom: Bool) -> Int {
            var lastStable = 0
            var mismatches = 0
            for i in 0..<limit {
                let ay = fromBottom ? a.height - 1 - i : i
                let by = fromBottom ? b.height - 1 - i : i
                if rowIsStable(ay, by) {
                    lastStable = i + 1
                    mismatches = 0
                } else {
                    mismatches += 1
                    if mismatches >= 4 { break }
                }
            }
            return lastStable >= 8 ? lastStable : 0
        }

        return (count(fromBottom: false), count(fromBottom: true))
    }
}
