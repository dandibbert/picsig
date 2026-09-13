import Foundation

/// Splits a very long image into readable pages.
///
/// Cutting every N rows would slice through a line of text or a chat bubble.
/// Instead the splitter looks for the quietest row inside a window around the
/// ideal cut — the same row activity profile the stitcher already computes.
public enum PageSplitter {
    public struct Options: Equatable, Sendable {
        public var pageHeight: Int
        /// How far the cut may move to find a quiet row.
        public var searchWindow: Int
        /// Rows repeated at the top of the following page.
        public var overlap: Int
        /// A page shorter than this is merged into the previous one.
        public var minPageHeight: Int

        public init(pageHeight: Int = 4000,
                    searchWindow: Int = 160,
                    overlap: Int = 40,
                    minPageHeight: Int = 400) {
            self.pageHeight = max(64, pageHeight)
            self.searchWindow = max(0, searchWindow)
            self.overlap = max(0, overlap)
            self.minPageHeight = max(0, minPageHeight)
        }

        public static let `default` = Options()
    }

    /// Row ranges to render, in order. Consecutive ranges overlap by
    /// `options.overlap` rows.
    public static func pages(imageHeight: Int,
                             activity: [Double]? = nil,
                             options: Options = .default) -> [Range<Int>] {
        guard imageHeight > 0 else { return [] }
        guard imageHeight > options.pageHeight else { return [0..<imageHeight] }

        var pages = [Range<Int>]()
        var start = 0
        while start < imageHeight {
            let idealEnd = start + options.pageHeight
            if idealEnd >= imageHeight || imageHeight - idealEnd < options.minPageHeight {
                pages.append(start..<imageHeight)
                break
            }
            let end = quietestRow(around: idealEnd,
                                  window: options.searchWindow,
                                  lowerLimit: start + options.minPageHeight,
                                  upperLimit: imageHeight - 1,
                                  activity: activity)
            pages.append(start..<end)
            start = max(end - options.overlap, end - options.pageHeight + 1)
            if start <= pages[pages.count - 1].lowerBound { start = end } // safety
        }
        return pages
    }

    /// Row with the least visual activity inside the search window, which is
    /// where a cut is least noticeable.
    static func quietestRow(around ideal: Int,
                            window: Int,
                            lowerLimit: Int,
                            upperLimit: Int,
                            activity: [Double]?) -> Int {
        let lower = max(lowerLimit, min(ideal - window, upperLimit))
        let upper = min(upperLimit, max(ideal + window, lower))
        guard let activity, !activity.isEmpty, upper > lower else {
            return min(max(ideal, lowerLimit), upperLimit)
        }

        var bestRow = min(max(ideal, lower), upper)
        var bestScore = Double.greatestFiniteMagnitude
        for row in lower...upper where row < activity.count {
            // Prefer quiet rows, and among equally quiet rows the one closest to
            // the ideal page height.
            let distancePenalty = Double(abs(row - ideal)) / Double(max(1, window)) * 0.35
            let score = activity[row] + distancePenalty
            if score < bestScore {
                bestScore = score
                bestRow = row
            }
        }
        return bestRow
    }
}
