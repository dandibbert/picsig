import Foundation

/// Bands at the top and bottom of a screenshot that do not move while scrolling:
/// status bar, navigation bar, search field, tab bar, home indicator.
public struct FixedRegions: Equatable, Sendable {
    public var topLength: Int
    public var bottomLength: Int

    public init(topLength: Int, bottomLength: Int) {
        self.topLength = topLength
        self.bottomLength = bottomLength
    }

    public static let none = FixedRegions(topLength: 0, bottomLength: 0)

    public func contentRange(forHeight height: Int) -> Range<Int> {
        let lower = min(max(0, topLength), height)
        let upper = max(lower, height - max(0, bottomLength))
        return lower..<upper
    }
}

/// Detects the static chrome of a scrolling screenshot sequence.
///
/// Repeating the navigation bar every 1600 rows is the single most obvious
/// artefact of a naive long screenshot, so the bands are measured on every
/// consecutive pair and the intersection (the most conservative estimate) is
/// used.
public enum FixedRegionDetector {
    public struct Options: Sendable {
        /// Mean absolute row difference below which two rows count as identical.
        public var tolerance: Double
        /// A fixed band may never take more than this fraction of the image.
        public var maxFraction: Double
        public var columnStride: Int
        /// Bands shorter than this are treated as noise and reported as zero.
        public var minLength: Int

        public init(tolerance: Double = 2.5,
                    maxFraction: Double = 0.35,
                    columnStride: Int = 3,
                    minLength: Int = 4) {
            self.tolerance = tolerance
            self.maxFraction = maxFraction
            self.columnStride = columnStride
            self.minLength = minLength
        }

        public static let `default` = Options()
    }

    public static func detect(previous: GrayImage,
                              next: GrayImage,
                              options: Options = .default) -> FixedRegions {
        guard !previous.isEmpty, !next.isEmpty else { return .none }
        let height = min(previous.height, next.height)
        let limit = max(0, Int(Double(height) * options.maxFraction))
        guard limit > 0 else { return .none }

        var top = 0
        while top < limit {
            let difference = previous.rowDifference(top, to: next, row: top, stride: options.columnStride)
            if difference > options.tolerance { break }
            top += 1
        }

        var bottom = 0
        while bottom < limit {
            let previousRow = previous.height - 1 - bottom
            let nextRow = next.height - 1 - bottom
            let difference = previous.rowDifference(previousRow, to: next, row: nextRow, stride: options.columnStride)
            if difference > options.tolerance { break }
            bottom += 1
        }

        return FixedRegions(topLength: top >= options.minLength ? top : 0,
                            bottomLength: bottom >= options.minLength ? bottom : 0)
    }

    public static func detect(images: [GrayImage], options: Options = .default) -> FixedRegions {
        guard images.count > 1 else { return .none }
        var result: FixedRegions?
        for index in 1..<images.count {
            let pair = detect(previous: images[index - 1], next: images[index], options: options)
            if let current = result {
                result = FixedRegions(topLength: min(current.topLength, pair.topLength),
                                      bottomLength: min(current.bottomLength, pair.bottomLength))
            } else {
                result = pair
            }
        }
        return result ?? .none
    }

    public static func detect(pyramids: [GrayPyramid], options: Options = .default) -> FixedRegions {
        detect(images: pyramids.map(\.full), options: options)
    }
}
