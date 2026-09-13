import Foundation

public struct ScanSettings: Codable, Equatable, Sendable {
    public var enabledCategories: Set<SensitiveCategory>
    /// Matches below this confidence are not reported.
    public var minConfidence: Double
    /// Values containing one of these terms are never masked (own company name,
    /// a test account, the user's own nickname …).
    public var allowList: [String]
    /// Literal strings that are always masked.
    public var denyList: [String]
    public var customRules: [CustomSensitiveRule]
    /// Turn off to fall back to plain pattern matching.
    public var useContext: Bool
    /// Rules the user switched off individually.
    public var disabledRuleIDs: Set<String>
    /// Rules that ship disabled but were switched on by the user.
    public var enabledRuleIDs: Set<String>
    /// When a value was confidently detected once, mask every other occurrence
    /// of it too, even where the local context is missing.
    public var propagateRepeatedValues: Bool

    public init(enabledCategories: Set<SensitiveCategory> = BuiltinRules.defaultEnabledCategories,
                minConfidence: Double = 0.6,
                allowList: [String] = [],
                denyList: [String] = [],
                customRules: [CustomSensitiveRule] = [],
                useContext: Bool = true,
                disabledRuleIDs: Set<String> = [],
                enabledRuleIDs: Set<String> = [],
                propagateRepeatedValues: Bool = true) {
        self.enabledCategories = enabledCategories
        self.minConfidence = minConfidence
        self.allowList = allowList
        self.denyList = denyList
        self.customRules = customRules
        self.useContext = useContext
        self.disabledRuleIDs = disabledRuleIDs
        self.enabledRuleIDs = enabledRuleIDs
        self.propagateRepeatedValues = propagateRepeatedValues
    }

    public static let `default` = ScanSettings()

    /// Mask everything the app knows about, including the noisy categories.
    public static let aggressive = ScanSettings(enabledCategories: Set(SensitiveCategory.allCases),
                                                minConfidence: 0.4)
}

/// Runs the rule catalogue over recognised text and returns the values that
/// should be masked.
///
/// Marked `@unchecked Sendable`: the compiled regular expressions are immutable
/// after `init`, and `NSRegularExpression` matching is documented as thread safe.
public final class SensitiveScanner: @unchecked Sendable {
    private struct CompiledRule {
        let rule: SensitiveRule
        let regex: NSRegularExpression
    }

    public let settings: ScanSettings
    private let compiled: [CompiledRule]

    public init(settings: ScanSettings = .default, extraRules: [SensitiveRule] = []) {
        self.settings = settings
        let candidates = BuiltinRules.all + extraRules + settings.customRules.filter(\.isEnabled).map(\.rule)
        self.compiled = candidates.compactMap { rule in
            guard Self.isActive(rule, settings: settings) else { return nil }
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
            return CompiledRule(rule: rule, regex: regex)
        }
    }

    private static func isActive(_ rule: SensitiveRule, settings: ScanSettings) -> Bool {
        guard settings.enabledCategories.contains(rule.category) else { return false }
        if settings.disabledRuleIDs.contains(rule.id) { return false }
        return rule.isEnabledByDefault || settings.enabledRuleIDs.contains(rule.id)
    }

    public var activeRuleIDs: [String] { compiled.map(\.rule.id) }

    // MARK: - Scanning

    public func scan(_ layout: TextLayout) -> [SensitiveMatch] {
        guard !layout.lines.isEmpty else { return [] }
        let analyzer = ContextAnalyzer(layout: layout)
        var matches = [SensitiveMatch]()

        for line in layout.lines where !line.text.isEmpty {
            var lineMatches = [SensitiveMatch]()
            for entry in compiled {
                lineMatches.append(contentsOf: evaluate(entry, in: line, analyzer: analyzer))
            }
            lineMatches.append(contentsOf: denyListMatches(in: line))
            matches.append(contentsOf: resolveConflicts(lineMatches))
        }

        if settings.propagateRepeatedValues {
            matches.append(contentsOf: propagatedMatches(from: matches, layout: layout))
        }

        return deduplicateAcrossLines(matches)
            .sorted { lhs, rhs in
                lhs.box.minY == rhs.box.minY ? lhs.box.minX < rhs.box.minX : lhs.box.minY < rhs.box.minY
            }
    }

    /// Convenience for tests and for the rule editor preview.
    public func scan(text: String) -> [SensitiveMatch] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            RecognizedTextLine(id: index,
                               text: String(line),
                               box: NormalizedRect(x: 0,
                                                   y: Double(index) * 0.05,
                                                   width: 1,
                                                   height: 0.04))
        }
        return scan(TextLayout(lines: lines, imageSize: PixelSize(width: 1000, height: 1000)))
    }

    // MARK: - Rule evaluation

    private func evaluate(_ entry: CompiledRule,
                          in line: RecognizedTextLine,
                          analyzer: ContextAnalyzer) -> [SensitiveMatch] {
        let text = line.text
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var results = [SensitiveMatch]()

        entry.regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
            guard let result else { return }
            let group = entry.rule.captureGroup < result.numberOfRanges ? entry.rule.captureGroup : 0
            let nsRange = result.range(at: group)
            guard nsRange.location != NSNotFound,
                  let range = Range(nsRange, in: text) else { return }

            let value = String(text[range])
            guard !value.isEmpty else { return }
            if let validate = entry.rule.validate, !validate(value) { return }
            if self.isAllowListed(value) { return }

            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: range.upperBound)
            let characterRange = lower..<upper

            var confidence = entry.rule.baseConfidence
            if let adjust = entry.rule.confidenceAdjustment {
                confidence += adjust(value)
            }
            var contextLabel: String?
            if self.settings.useContext {
                let keywords = entry.rule.contextKeywords.isEmpty
                    ? ContextKeywords.keywords(for: entry.rule.category)
                    : entry.rule.contextKeywords
                let context = analyzer.analyze(keywords: keywords, line: line, valueRange: characterRange)
                if entry.rule.requiresContext && !context.hasContext { return }
                if context.hasContext {
                    confidence += entry.rule.contextBoost * (context.isSameLine ? 1 : 0.75)
                    contextLabel = context.matchedKeyword
                }
            } else if entry.rule.requiresContext {
                return
            }

            if Self.placeholderProneCategories.contains(entry.rule.category),
               SensitiveValidators.looksLikePlaceholder(value) {
                confidence *= 0.5
            }
            // Vision reports line confidence coarsely — real screenshots come back
            // as 0.5 for most lines and 1.0 for a few. Multiplying by it outright
            // pulled a checksum-valid phone number from 0.88 down to 0.44 and
            // dropped it, which is how whole screens ended up with nothing found.
            // The OCR score now nudges the confidence instead of gating on it.
            let ocrFactor = 0.9 + 0.1 * min(1, max(0, line.confidence))
            confidence = min(0.99, confidence) * ocrFactor
            guard confidence >= self.settings.minConfidence else { return }

            results.append(SensitiveMatch(category: entry.rule.category,
                                          ruleID: entry.rule.id,
                                          lineID: line.id,
                                          value: value,
                                          characterRange: characterRange,
                                          box: line.box(forCharacterRange: characterRange),
                                          confidence: confidence,
                                          contextLabel: contextLabel))
        }
        return results
    }

    private static let placeholderProneCategories: Set<SensitiveCategory> = [
        .phoneNumber, .bankCard, .idCard, .trackingNumber, .verificationCode
    ]

    private func isAllowListed(_ value: String) -> Bool {
        guard !settings.allowList.isEmpty else { return false }
        let lowered = value.lowercased()
        return settings.allowList.contains { term in
            let trimmed = term.trimmingCharacters(in: .whitespaces).lowercased()
            return !trimmed.isEmpty && lowered.contains(trimmed)
        }
    }

    private func denyListMatches(in line: RecognizedTextLine) -> [SensitiveMatch] {
        guard !settings.denyList.isEmpty else { return [] }
        var results = [SensitiveMatch]()
        let characters = line.characters
        for term in settings.denyList {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 1 else { continue }
            let needle = Array(trimmed)
            guard needle.count <= characters.count else { continue }
            var index = 0
            while index + needle.count <= characters.count {
                let window = Array(characters[index..<(index + needle.count)])
                if String(window).lowercased() == trimmed.lowercased() {
                    let range = index..<(index + needle.count)
                    results.append(SensitiveMatch(category: .custom,
                                                  ruleID: "settings.denyList",
                                                  lineID: line.id,
                                                  value: String(window),
                                                  characterRange: range,
                                                  box: line.box(forCharacterRange: range),
                                                  confidence: 0.99,
                                                  contextLabel: trimmed))
                    index += needle.count
                } else {
                    index += 1
                }
            }
        }
        return results
    }

    // MARK: - Conflict resolution

    /// Two rules often claim the same characters (a 19 digit UnionPay number is
    /// also a valid "long digit run"). The more severe, more confident and longer
    /// match wins.
    private func resolveConflicts(_ candidates: [SensitiveMatch]) -> [SensitiveMatch] {
        guard candidates.count > 1 else { return candidates }
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.category.severity != rhs.category.severity {
                return lhs.category.severity > rhs.category.severity
            }
            if abs(lhs.confidence - rhs.confidence) > 0.01 {
                return lhs.confidence > rhs.confidence
            }
            return lhs.characterRange.count > rhs.characterRange.count
        }
        var accepted = [SensitiveMatch]()
        for candidate in ranked {
            let overlaps = accepted.contains { existing in
                existing.lineID == candidate.lineID
                    && existing.characterRange.overlaps(candidate.characterRange)
            }
            if !overlaps { accepted.append(candidate) }
        }
        return accepted
    }

    /// A value that was confidently identified once is masked everywhere it
    /// appears. In a chat screenshot the phone number is usually labelled only in
    /// the first bubble; without this pass the repetitions stay readable.
    private func propagatedMatches(from matches: [SensitiveMatch], layout: TextLayout) -> [SensitiveMatch] {
        let seeds = matches.filter {
            $0.confidence >= 0.7 && !$0.isVisual && $0.value.count >= Self.minimumPropagationLength(for: $0.category)
        }
        guard !seeds.isEmpty else { return [] }
        var uniqueValues = [String: SensitiveMatch]()
        for seed in seeds where uniqueValues[seed.value] == nil {
            uniqueValues[seed.value] = seed
        }

        var results = [SensitiveMatch]()
        for line in layout.lines {
            let characters = line.characters
            for (value, seed) in uniqueValues {
                let needle = Array(value)
                guard needle.count <= characters.count else { continue }
                var index = 0
                while index + needle.count <= characters.count {
                    if Array(characters[index..<(index + needle.count)]) == needle {
                        let range = index..<(index + needle.count)
                        let alreadyCovered = matches.contains { existing in
                            existing.lineID == line.id && existing.characterRange.overlaps(range)
                        }
                        if !alreadyCovered {
                            results.append(SensitiveMatch(category: seed.category,
                                                          ruleID: seed.ruleID + ".propagated",
                                                          lineID: line.id,
                                                          value: value,
                                                          characterRange: range,
                                                          box: line.box(forCharacterRange: range),
                                                          confidence: seed.confidence * 0.95,
                                                          contextLabel: seed.contextLabel))
                        }
                        index += needle.count
                    } else {
                        index += 1
                    }
                }
            }
        }
        return results
    }

    /// Chinese names are two or three characters long, so the generic "long
    /// enough to be unique" threshold would exclude exactly the values that
    /// benefit most from propagation.
    private static func minimumPropagationLength(for category: SensitiveCategory) -> Int {
        switch category {
        case .personName: return 2
        case .plateNumber, .verificationCode: return 4
        default: return 6
        }
    }

    /// Long screenshots repeat rows around a seam; identical values in nearly the
    /// same place are reported once.
    private func deduplicateAcrossLines(_ matches: [SensitiveMatch]) -> [SensitiveMatch] {
        var result = [SensitiveMatch]()
        for match in matches {
            let duplicate = result.contains { existing in
                existing.value == match.value
                    && existing.category == match.category
                    && existing.box.iou(match.box) > 0.6
            }
            if !duplicate { result.append(match) }
        }
        return result
    }
}
