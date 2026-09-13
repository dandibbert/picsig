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
    private struct Score { var rows: Int; var error: Double; var texture: Double }
    public static func difference(_ a: GrayRaster, _ b: GrayRaster) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        var sum = 0.0, count = 0
        for i in stride(from: 0, to: a.pixels.count, by: max(1, a.pixels.count / 4096)) {
            sum += Double(abs(Int(a.pixels[i]) - Int(b.pixels[i]))); count += 1
        }
        return sum / Double(max(1, count))
    }
    /// Refuses low-texture and ambiguous matches instead of silently deleting content.
    public static func match(_ a: GrayRaster, _ b: GrayRaster) -> OverlapMatch? {
        guard a.width == b.width else { return nil }
        if difference(a, b) < 1.1 { return OverlapMatch(rows: b.height, confidence: 1, duplicate: true) }
        let maximum = min(a.height, b.height) - 6
        let minimum = max(16, min(64, maximum / 12))
        guard maximum > minimum else { return nil }
        let step = 1
        var coarse: [Score] = []
        for rows in stride(from: minimum, through: maximum, by: step) { coarse.append(score(a, b, rows: rows, samples: 12)) }
        let seeds = coarse.sorted { $0.error < $1.error }.prefix(8)
        var candidates = Set<Int>()
        for seed in seeds { for row in max(minimum, seed.rows - step)...min(maximum, seed.rows + step) { candidates.insert(row) } }
        let refined = candidates.map { score(a, b, rows: $0, samples: 112) }.sorted { $0.error < $1.error }
        guard let best = refined.first, best.error < 14, best.texture > 2.5 else { return nil }
        let separation = max(5, maximum / 300)
        let next = refined.first { abs($0.rows - best.rows) > separation }
        if let next = next, next.error - best.error < 0.9 { return nil }
        let certainty = max(0, 1 - best.error / 18)
        guard certainty >= 0.40 else { return nil }
        return OverlapMatch(rows: best.rows, confidence: certainty, duplicate: false)
    }
    private static func score(_ a: GrayRaster, _ b: GrayRaster, rows: Int, samples: Int) -> Score {
        let inset = max(2, a.width / 12)
        let xStep = max(1, (a.width - 2 * inset) / (samples <= 12 ? 12 : 28))
        let yStep = max(1, rows / samples)
        var weighted = 0.0, weightSum = 0.0, texture = 0.0, count = 0
        for y in stride(from: 1, to: rows - 1, by: yStep) {
            let ay = a.height - rows + y
            for x in stride(from: inset, to: a.width - inset, by: xStep) {
                let ai = ay * a.width + x, bi = y * b.width + x
                let edgeA = abs(Int(a.pixels[ai + 1]) - Int(a.pixels[ai - 1])) + abs(Int(a.pixels[ai + a.width]) - Int(a.pixels[ai - a.width]))
                let edgeB = abs(Int(b.pixels[bi + 1]) - Int(b.pixels[bi - 1])) + abs(Int(b.pixels[bi + b.width]) - Int(b.pixels[bi - b.width]))
                let edge = Double(max(edgeA, edgeB))
                let weight = 1 + min(8, edge / 24)
                weighted += Double(abs(Int(a.pixels[ai]) - Int(b.pixels[bi]))) * weight
                weightSum += weight; texture += edge; count += 1
            }
        }
        return Score(rows: rows, error: weighted / max(1, weightSum), texture: texture / Double(max(1, count)))
    }
    /// Only constant outer runs are removed; the first header and last footer are retained by the caller.
    public static func fixedInsets(_ a: GrayRaster, _ b: GrayRaster) -> (top: Int, bottom: Int) {
        guard a.width == b.width, difference(a, b) > 3 else { return (0, 0) }
        let limit = min(a.height, b.height) * 16 / 100
        func count(fromBottom: Bool) -> Int {
            var lastStable = 0, mismatches = 0
            for i in 0..<limit {
                let ay = fromBottom ? a.height - 1 - i : i, by = fromBottom ? b.height - 1 - i : i
                var total = 0
                for x in 0..<a.width { total += abs(Int(a.pixels[ay * a.width + x]) - Int(b.pixels[by * b.width + x])) }
                if Double(total) / Double(a.width) < 2.8 { lastStable = i + 1; mismatches = 0 }
                else { mismatches += 1; if mismatches >= 3 { break } }
            }
            return lastStable >= 8 ? lastStable : 0
        }
        return (count(fromBottom: false), count(fromBottom: true))
    }
}
