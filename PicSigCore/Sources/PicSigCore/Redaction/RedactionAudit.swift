import Foundation

/// Something that is still readable in the exported image although it should
/// have been masked.
public struct ResidualLeak: Identifiable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The exact value was recognised again in the rendered result.
        case valueStillReadable
        /// Text was recognised inside an area that was supposed to be masked.
        case textInsideMaskedArea
    }

    public let id: UUID
    public let category: SensitiveCategory
    public let valuePreview: String
    public let box: NormalizedRect
    public let reason: Reason

    public init(id: UUID = UUID(),
                category: SensitiveCategory,
                valuePreview: String,
                box: NormalizedRect,
                reason: Reason) {
        self.id = id
        self.category = category
        self.valuePreview = valuePreview
        self.box = box
        self.reason = reason
    }
}

/// A match whose masked characters are not fully covered by the plan.
public struct CoverageIssue: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let matchID: UUID
    public let category: SensitiveCategory
    public let coveredFraction: Double

    public init(id: UUID = UUID(), matchID: UUID, category: SensitiveCategory, coveredFraction: Double) {
        self.id = id
        self.matchID = matchID
        self.category = category
        self.coveredFraction = coveredFraction
    }
}

/// Report shown after masking: what was hidden, how, and whether anything slipped
/// through.
public struct RedactionAudit: Equatable, Sendable {
    public struct CategoryEntry: Identifiable, Equatable, Sendable {
        public var id: SensitiveCategory { category }
        public let category: SensitiveCategory
        public let count: Int
        public let styles: [RedactionStyle]

        public init(category: SensitiveCategory, count: Int, styles: [RedactionStyle]) {
            self.category = category
            self.count = count
            self.styles = styles
        }
    }

    public var entries: [CategoryEntry]
    public var itemCount: Int
    public var manualItemCount: Int
    public var potentiallyReversibleCount: Int
    public var coverageIssues: [CoverageIssue]
    public var residualLeaks: [ResidualLeak]
    /// True when a verification pass actually ran.
    public var wasVerified: Bool

    public init(entries: [CategoryEntry] = [],
                itemCount: Int = 0,
                manualItemCount: Int = 0,
                potentiallyReversibleCount: Int = 0,
                coverageIssues: [CoverageIssue] = [],
                residualLeaks: [ResidualLeak] = [],
                wasVerified: Bool = false) {
        self.entries = entries
        self.itemCount = itemCount
        self.manualItemCount = manualItemCount
        self.potentiallyReversibleCount = potentiallyReversibleCount
        self.coverageIssues = coverageIssues
        self.residualLeaks = residualLeaks
        self.wasVerified = wasVerified
    }

    public var isClean: Bool { coverageIssues.isEmpty && residualLeaks.isEmpty }
}

/// Second pair of eyes on the masking result.
///
/// Checking geometry catches planning mistakes, and re-running OCR on the
/// *rendered* image catches everything else: a mosaic that was too weak, a value
/// the merge step clipped, text baked into a screenshot twice. No other long
/// screenshot app verifies its own output, and it is cheap to do.
public enum RedactionVerifier {
    /// Fraction of each match's masked area that the plan really covers.
    public static func coverageIssues(matches: [SensitiveMatch],
                                      layout: TextLayout,
                                      policy: MaskingPolicy,
                                      plan: RedactionPlan,
                                      minimumCoverage: Double = 0.9) -> [CoverageIssue] {
        var lineByID = [Int: RecognizedTextLine]()
        for line in layout.lines { lineByID[line.id] = line }

        var issues = [CoverageIssue]()
        for match in matches where match.isEnabled {
            let rule = policy.rule(for: match.category)
            let expected: [NormalizedRect]
            if let lineID = match.lineID, let line = lineByID[lineID] {
                expected = MaskingPolicy.maskedRanges(for: match, rule: rule)
                    .map { line.box(forCharacterRange: $0) }
            } else {
                expected = [match.box]
            }

            let expectedArea = expected.reduce(0) { $0 + $1.area }
            guard expectedArea > 0 else { continue }
            let covered = expected.reduce(0.0) { total, box in
                let intersection = plan.items.reduce(0.0) { $0 + box.intersectionArea(with: $1.box) }
                return total + min(box.area, intersection)
            }
            let fraction = covered / expectedArea
            if fraction < minimumCoverage {
                issues.append(CoverageIssue(matchID: match.id,
                                            category: match.category,
                                            coveredFraction: fraction))
            }
        }
        return issues
    }

    /// Compares what should be gone against what a fresh scan of the rendered
    /// image still finds.
    public static func residualLeaks(originalMatches: [SensitiveMatch],
                                     rescanned: [SensitiveMatch],
                                     plan: RedactionPlan) -> [ResidualLeak] {
        let maskedValues = Set(originalMatches.filter(\.isEnabled).map(\.value))
        var leaks = [ResidualLeak]()

        for match in rescanned {
            if maskedValues.contains(match.value) {
                leaks.append(ResidualLeak(category: match.category,
                                          valuePreview: RedactionPlanner.preview(of: match.value),
                                          box: match.box,
                                          reason: .valueStillReadable))
                continue
            }
            // Text found inside a masked rectangle means the mask did not do its
            // job (too weak a mosaic, or a replacement drawn under the original).
            let insideMask = plan.items.contains { item in
                item.style != .replacement && match.box.overlapRatio(with: item.box) > 0.6
            }
            if insideMask {
                leaks.append(ResidualLeak(category: match.category,
                                          valuePreview: RedactionPlanner.preview(of: match.value),
                                          box: match.box,
                                          reason: .textInsideMaskedArea))
            }
        }
        return leaks
    }

    public static func audit(plan: RedactionPlan,
                             matches: [SensitiveMatch],
                             layout: TextLayout,
                             policy: MaskingPolicy,
                             rescanned: [SensitiveMatch]? = nil) -> RedactionAudit {
        var grouped = [SensitiveCategory: [RedactionItem]]()
        for item in plan.items {
            grouped[item.category, default: []].append(item)
        }
        let entries = grouped
            .map { category, items in
                RedactionAudit.CategoryEntry(category: category,
                                             count: items.count,
                                             styles: Array(Set(items.map(\.style))).sorted { $0.rawValue < $1.rawValue })
            }
            .sorted { lhs, rhs in
                lhs.category.severity == rhs.category.severity
                    ? lhs.count > rhs.count
                    : lhs.category.severity > rhs.category.severity
            }

        return RedactionAudit(entries: entries,
                              itemCount: plan.count,
                              manualItemCount: plan.items.filter(\.isManual).count,
                              potentiallyReversibleCount: plan.potentiallyReversibleCount,
                              coverageIssues: coverageIssues(matches: matches,
                                                             layout: layout,
                                                             policy: policy,
                                                             plan: plan),
                              residualLeaks: rescanned.map {
                                  residualLeaks(originalMatches: matches, rescanned: $0, plan: plan)
                              } ?? [],
                              wasVerified: rescanned != nil)
    }
}

extension NormalizedRect {
    /// Fraction of `self` covered by `other`.
    func overlapRatio(with other: NormalizedRect) -> Double {
        guard area > 0 else { return 0 }
        return intersectionArea(with: other) / area
    }
}
