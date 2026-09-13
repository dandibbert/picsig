import Foundation

/// A detection rule: a regular expression plus the checks and context
/// requirements that turn a raw pattern hit into a trustworthy match.
public struct SensitiveRule: Identifiable {
    public let id: String
    public let category: SensitiveCategory
    public let pattern: String
    /// Capture group that carries the value to mask. 0 is the whole match, which
    /// lets a rule anchor on surrounding words without masking them.
    public let captureGroup: Int
    public let baseConfidence: Double
    /// Words that, when found near the value, make the match much more likely.
    public let contextKeywords: [String]
    public let contextBoost: Double
    /// When true the rule only fires if one of its keywords is nearby. Used for
    /// values that are indistinguishable from ordinary numbers on their own
    /// (verification codes, balances, membership ids).
    public let requiresContext: Bool
    /// Optional checksum / plausibility check applied to the captured value.
    public let validate: (@Sendable (String) -> Bool)?
    /// Whether the rule participates once its category is enabled. `false` marks
    /// rules that are noisy even inside their own category and have to be turned
    /// on explicitly; whether a whole category is on is a separate switch.
    public let isEnabledByDefault: Bool

    public init(id: String,
                category: SensitiveCategory,
                pattern: String,
                captureGroup: Int = 0,
                baseConfidence: Double = 0.75,
                contextKeywords: [String] = [],
                contextBoost: Double = 0.2,
                requiresContext: Bool = false,
                isEnabledByDefault: Bool = true,
                validate: (@Sendable (String) -> Bool)? = nil) {
        self.id = id
        self.category = category
        self.pattern = pattern
        self.captureGroup = captureGroup
        self.baseConfidence = baseConfidence
        self.contextKeywords = contextKeywords
        self.contextBoost = contextBoost
        self.requiresContext = requiresContext
        self.isEnabledByDefault = isEnabledByDefault
        self.validate = validate
    }
}

/// A rule the user typed in themselves, e.g. an internal order number format.
public struct CustomSensitiveRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var category: SensitiveCategory
    public var isEnabled: Bool
    /// Treat `pattern` as plain text instead of a regular expression.
    public var isLiteral: Bool

    public init(id: UUID = UUID(),
                name: String,
                pattern: String,
                category: SensitiveCategory = .custom,
                isEnabled: Bool = true,
                isLiteral: Bool = false) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.category = category
        self.isEnabled = isEnabled
        self.isLiteral = isLiteral
    }

    public var rule: SensitiveRule {
        SensitiveRule(id: "custom.\(id.uuidString)",
                      category: category,
                      pattern: isLiteral ? NSRegularExpression.escapedPattern(for: pattern) : pattern,
                      baseConfidence: 0.95)
    }

    /// Reports whether the pattern compiles, so the settings screen can show an
    /// error instead of silently dropping the rule.
    public var patternError: String? {
        guard !isLiteral else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// One piece of sensitive information found in an image.
public struct SensitiveMatch: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let category: SensitiveCategory
    public let ruleID: String
    /// Identifier of the text line, or `nil` for visual detections.
    public let lineID: Int?
    /// The matched value, e.g. `13812345678`.
    public let value: String
    /// Range of `value` inside the line's characters.
    public let characterRange: Range<Int>
    /// Box of the value itself.
    public var box: NormalizedRect
    public var confidence: Double
    /// The keyword that boosted this match, shown in the review list so the user
    /// understands *why* something was flagged.
    public var contextLabel: String?
    public var isEnabled: Bool

    public init(id: UUID = UUID(),
                category: SensitiveCategory,
                ruleID: String,
                lineID: Int?,
                value: String,
                characterRange: Range<Int>,
                box: NormalizedRect,
                confidence: Double,
                contextLabel: String? = nil,
                isEnabled: Bool = true) {
        self.id = id
        self.category = category
        self.ruleID = ruleID
        self.lineID = lineID
        self.value = value
        self.characterRange = characterRange
        self.box = box
        self.confidence = confidence
        self.contextLabel = contextLabel
        self.isEnabled = isEnabled
    }

    public var isVisual: Bool { lineID == nil }
}
