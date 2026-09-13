import Foundation

public enum RedactionStyle: String, Codable, CaseIterable, Sendable {
    /// True pixelation: the area is downsampled and the average colour is
    /// written back, so the original pixels are gone for good.
    case mosaic
    /// Gaussian blur. Looks nice but is the only style that can, in principle,
    /// be attacked; the UI says so.
    case blur
    /// Opaque rectangle.
    case solid
    /// Emoji or symbol drawn over the area.
    case sticker
    /// Replace the text with a realistic but fake value of the same shape.
    case replacement

    /// Blur keeps low frequency information; everything else destroys it.
    public var isPotentiallyReversible: Bool { self == .blur }

    public var localizationKey: String { "redaction.style.\(rawValue)" }

    public var fallbackTitle: String {
        switch self {
        case .mosaic: return "马赛克"
        case .blur: return "模糊"
        case .solid: return "色块"
        case .sticker: return "贴纸"
        case .replacement: return "脱敏替换"
        }
    }
}

/// How one category is masked.
public struct MaskingRule: Codable, Equatable, Sendable {
    public var style: RedactionStyle
    /// Characters kept readable at the start of the value.
    public var preserveLeading: Int
    /// Characters kept readable at the end of the value.
    public var preserveTrailing: Int
    /// 0...1; mosaic block size and blur radius scale with it.
    public var strength: Double
    public var stickerSymbol: String

    public init(style: RedactionStyle = .mosaic,
                preserveLeading: Int = 0,
                preserveTrailing: Int = 0,
                strength: Double = 0.7,
                stickerSymbol: String = "🙈") {
        self.style = style
        self.preserveLeading = max(0, preserveLeading)
        self.preserveTrailing = max(0, preserveTrailing)
        self.strength = min(1, max(0, strength))
        self.stickerSymbol = stickerSymbol
    }

    public var masksWholeValue: Bool { preserveLeading == 0 && preserveTrailing == 0 }
}

extension SensitiveCategory: CodingKeyRepresentable {
    public var codingKey: CodingKey {
        StringCodingKey(stringValue: rawValue)
    }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

/// Minimal `CodingKey` so category keyed dictionaries encode as readable JSON.
public struct StringCodingKey: CodingKey, Sendable {
    public var stringValue: String
    public var intValue: Int? { nil }

    public init(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
}

/// Per category masking configuration.
public struct MaskingPolicy: Codable, Equatable, Sendable {
    public var defaultRule: MaskingRule
    public var overrides: [SensitiveCategory: MaskingRule]
    /// Extra area around a box, as a fraction of the text height. Anti-aliased
    /// glyph edges leak surprisingly much, so this is never zero by default.
    public var padding: Double
    /// Snap mask rectangles to whole pixels of this size, which makes a page of
    /// masked rows look tidy instead of ragged.
    public var alignmentGrid: Int

    public init(defaultRule: MaskingRule = MaskingRule(),
                overrides: [SensitiveCategory: MaskingRule] = MaskingPolicy.recommendedOverrides,
                padding: Double = 0.18,
                alignmentGrid: Int = 2) {
        self.defaultRule = defaultRule
        self.overrides = overrides
        self.padding = padding
        self.alignmentGrid = alignmentGrid
    }

    public func rule(for category: SensitiveCategory) -> MaskingRule {
        overrides[category] ?? defaultRule
    }

    public mutating func setRule(_ rule: MaskingRule, for category: SensitiveCategory) {
        overrides[category] = rule
    }

    /// Defaults chosen to stay useful: a phone number keeps the parts people need
    /// to recognise the row, a secret is destroyed completely.
    public static let recommendedOverrides: [SensitiveCategory: MaskingRule] = [
        .phoneNumber: MaskingRule(style: .mosaic, preserveLeading: 3, preserveTrailing: 4),
        .idCard: MaskingRule(style: .mosaic, preserveLeading: 3, preserveTrailing: 4, strength: 0.85),
        .bankCard: MaskingRule(style: .mosaic, preserveLeading: 0, preserveTrailing: 4, strength: 0.85),
        .email: MaskingRule(style: .mosaic, preserveLeading: 2, preserveTrailing: 0),
        .personName: MaskingRule(style: .mosaic, preserveLeading: 1, preserveTrailing: 0),
        .address: MaskingRule(style: .mosaic, preserveLeading: 0, preserveTrailing: 0),
        .verificationCode: MaskingRule(style: .solid, strength: 1),
        .credential: MaskingRule(style: .solid, strength: 1),
        .face: MaskingRule(style: .mosaic, strength: 0.9),
        .barcode: MaskingRule(style: .solid, strength: 1),
        .amount: MaskingRule(style: .blur, strength: 0.8)
    ]

    public static let `default` = MaskingPolicy()

    /// Everything solid, nothing preserved: the safest possible output.
    public static let strict = MaskingPolicy(defaultRule: MaskingRule(style: .solid, strength: 1),
                                             overrides: [:],
                                             padding: 0.28)

    /// Keeps screenshots readable by swapping values for plausible fakes.
    public static let pseudonymised = MaskingPolicy(
        defaultRule: MaskingRule(style: .replacement),
        overrides: [
            .face: MaskingRule(style: .mosaic, strength: 0.9),
            .barcode: MaskingRule(style: .solid, strength: 1),
            .credential: MaskingRule(style: .solid, strength: 1)
        ],
        padding: 0.12)

    /// Which characters of a value are actually hidden.
    public static func maskedRanges(for match: SensitiveMatch, rule: MaskingRule) -> [Range<Int>] {
        let range = match.characterRange
        guard !range.isEmpty else { return [] }
        if rule.style == .replacement || rule.masksWholeValue { return [range] }
        let length = range.count
        let leading = min(rule.preserveLeading, length)
        let trailing = min(rule.preserveTrailing, length - leading)
        let lower = range.lowerBound + leading
        let upper = range.upperBound - trailing
        guard upper > lower else { return [range] } // nothing left to preserve
        return [lower..<upper]
    }
}
