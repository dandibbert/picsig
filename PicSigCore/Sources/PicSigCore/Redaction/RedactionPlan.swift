import Foundation

/// One area of the image to be modified.
public struct RedactionItem: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var box: NormalizedRect
    public var style: RedactionStyle
    public var strength: Double
    public var stickerSymbol: String
    /// Text drawn instead of the original, for `.replacement`.
    public var replacementText: String?
    public var category: SensitiveCategory
    /// Match this item came from, `nil` for hand drawn areas.
    public var matchID: UUID?
    public var isManual: Bool
    /// Partly masked copy of the value, safe to show in a report or store in a
    /// project file. The full value never leaves the scanner.
    public var valuePreview: String
    /// Recognised line a tap-to-mask item covers, so a second tap on the same
    /// line finds and removes it.
    public var sourceLineID: Int?

    public init(id: UUID = UUID(),
                box: NormalizedRect,
                style: RedactionStyle,
                strength: Double,
                stickerSymbol: String = "🙈",
                replacementText: String? = nil,
                category: SensitiveCategory,
                matchID: UUID? = nil,
                isManual: Bool = false,
                valuePreview: String = "",
                sourceLineID: Int? = nil) {
        self.id = id
        self.box = box
        self.style = style
        self.strength = strength
        self.stickerSymbol = stickerSymbol
        self.replacementText = replacementText
        self.category = category
        self.matchID = matchID
        self.isManual = isManual
        self.valuePreview = valuePreview
        self.sourceLineID = sourceLineID
    }
}

public struct RedactionPlan: Equatable, Codable, Sendable {
    public var items: [RedactionItem]
    public var imageSize: PixelSize

    public init(items: [RedactionItem] = [], imageSize: PixelSize = .zero) {
        self.items = items
        self.imageSize = imageSize
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public func items(for category: SensitiveCategory) -> [RedactionItem] {
        items.filter { $0.category == category }
    }

    /// Number of areas masked with a style that is not information destroying.
    public var potentiallyReversibleCount: Int {
        items.filter { $0.style.isPotentiallyReversible }.count
    }

    public func pixelRects() -> [PixelRect] {
        items.map { $0.box.scaled(to: imageSize) }
    }
}

public enum RedactionPlanner {
    public struct Options: Sendable {
        public var pseudonyms: PseudonymGenerator
        /// Merge neighbouring boxes of the same style into one rectangle, which
        /// avoids the "dotted line of little mosaics" look and speeds rendering.
        public var mergeAdjacent: Bool
        /// Horizontal gap (unit space) still considered adjacent.
        public var mergeGap: Double

        public init(pseudonyms: PseudonymGenerator = PseudonymGenerator(),
                    mergeAdjacent: Bool = true,
                    mergeGap: Double = 0.012) {
            self.pseudonyms = pseudonyms
            self.mergeAdjacent = mergeAdjacent
            self.mergeGap = mergeGap
        }

        public static let `default` = Options()
    }

    public static func plan(matches: [SensitiveMatch],
                            layout: TextLayout,
                            policy: MaskingPolicy = .default,
                            imageSize: PixelSize? = nil,
                            manualItems: [RedactionItem] = [],
                            options: Options = .default) -> RedactionPlan {
        let canvas = imageSize ?? layout.imageSize
        var lineByID = [Int: RecognizedTextLine]()
        for line in layout.lines { lineByID[line.id] = line }

        var items = [RedactionItem]()
        for match in matches where match.isEnabled {
            let rule = policy.rule(for: match.category)
            let boxes: [NormalizedRect]
            if let lineID = match.lineID, let line = lineByID[lineID] {
                boxes = MaskingPolicy.maskedRanges(for: match, rule: rule)
                    .map { line.box(forCharacterRange: $0) }
            } else {
                boxes = [match.box]
            }

            for box in boxes where !box.isEmpty {
                let reference = max(box.height, 0.001)
                let padded = box
                    .expanded(byX: reference * policy.padding * 0.6, byY: reference * policy.padding)
                    .clampedToUnitSpace()
                let snapped = snap(padded, to: policy.alignmentGrid, canvas: canvas)
                items.append(RedactionItem(box: snapped,
                                           style: rule.style,
                                           strength: rule.strength,
                                           stickerSymbol: rule.stickerSymbol,
                                           replacementText: rule.style == .replacement
                                               ? options.pseudonyms.replacement(for: match)
                                               : nil,
                                           category: match.category,
                                           matchID: match.id,
                                           valuePreview: preview(of: match.value)))
            }
        }

        items.append(contentsOf: manualItems)
        if options.mergeAdjacent {
            items = merge(items, gap: options.mergeGap)
        }
        return RedactionPlan(items: items, imageSize: canvas)
    }

    /// Shows enough for the user to recognise the row without printing the value.
    public static func preview(of value: String) -> String {
        let characters = Array(value)
        guard characters.count > 2 else { return String(repeating: "*", count: characters.count) }
        let hidden = String(repeating: "*", count: min(6, characters.count - 2))
        return String(characters.first!) + hidden + String(characters.last!)
    }

    private static func snap(_ box: NormalizedRect, to grid: Int, canvas: PixelSize) -> NormalizedRect {
        guard grid > 1, !canvas.isEmpty else { return box }
        let rect = box.scaled(to: canvas)
        func floorTo(_ value: Int) -> Int { (value / grid) * grid }
        func ceilTo(_ value: Int) -> Int { ((value + grid - 1) / grid) * grid }
        let left = floorTo(rect.minX)
        let top = floorTo(rect.minY)
        let right = min(canvas.width, ceilTo(rect.maxX))
        let bottom = min(canvas.height, ceilTo(rect.maxY))
        guard right > left, bottom > top else { return box }
        return NormalizedRect(x: Double(left) / Double(canvas.width),
                             y: Double(top) / Double(canvas.height),
                             width: Double(right - left) / Double(canvas.width),
                             height: Double(bottom - top) / Double(canvas.height))
    }

    /// Unions boxes that share a style and sit next to each other on the same
    /// text row. Replacement items are never merged because each carries its own
    /// text.
    static func merge(_ items: [RedactionItem], gap: Double) -> [RedactionItem] {
        var result = [RedactionItem]()
        for item in items {
            guard item.style != .replacement, !item.isManual else {
                result.append(item)
                continue
            }
            let index = result.firstIndex { candidate in
                candidate.style == item.style
                    && candidate.style != .replacement
                    && !candidate.isManual
                    && abs(candidate.strength - item.strength) < 0.01
                    && verticallyAligned(candidate.box, item.box)
                    && horizontalGap(candidate.box, item.box) <= gap
            }
            if let index {
                result[index].box = result[index].box.union(item.box)
                if result[index].category != item.category {
                    result[index].category = result[index].category.severity >= item.category.severity
                        ? result[index].category
                        : item.category
                }
                result[index].valuePreview = [result[index].valuePreview, item.valuePreview]
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
            } else {
                result.append(item)
            }
        }
        return result
    }

    private static func verticallyAligned(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        guard overlap > 0 else { return false }
        return overlap >= min(lhs.height, rhs.height) * 0.6
    }

    private static func horizontalGap(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        if lhs.maxX >= rhs.minX && rhs.maxX >= lhs.minX { return 0 }
        return lhs.maxX < rhs.minX ? rhs.minX - lhs.maxX : lhs.minX - rhs.maxX
    }
}
