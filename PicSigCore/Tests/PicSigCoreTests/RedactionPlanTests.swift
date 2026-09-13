import XCTest
@testable import PicSigCore

final class MaskingPolicyTests: XCTestCase {
    private func match(value: String, category: SensitiveCategory, range: Range<Int>) -> SensitiveMatch {
        SensitiveMatch(category: category,
                       ruleID: "test",
                       lineID: 0,
                       value: value,
                       characterRange: range,
                       box: NormalizedRect(x: 0, y: 0, width: 1, height: 0.05),
                       confidence: 0.9)
    }

    func testPartialMaskingKeepsHeadAndTail() {
        let rule = MaskingRule(style: .mosaic, preserveLeading: 3, preserveTrailing: 4)
        let ranges = MaskingPolicy.maskedRanges(for: match(value: "13812345678",
                                                           category: .phoneNumber,
                                                           range: 4..<15),
                                                rule: rule)
        XCTAssertEqual(ranges, [7..<11], "138 and 5678 stay readable")
    }

    func testWholeValueIsMaskedWhenNothingIsPreserved() {
        let ranges = MaskingPolicy.maskedRanges(for: match(value: "abcdef", category: .credential, range: 0..<6),
                                                rule: MaskingRule(style: .solid))
        XCTAssertEqual(ranges, [0..<6])
    }

    func testPreservingMoreThanTheValueStillMasksEverything() {
        let rule = MaskingRule(style: .mosaic, preserveLeading: 4, preserveTrailing: 4)
        let ranges = MaskingPolicy.maskedRanges(for: match(value: "1234", category: .phoneNumber, range: 0..<4),
                                                rule: rule)
        XCTAssertEqual(ranges, [0..<4])
    }

    func testReplacementAlwaysCoversTheWholeValue() {
        let rule = MaskingRule(style: .replacement, preserveLeading: 3, preserveTrailing: 4)
        let ranges = MaskingPolicy.maskedRanges(for: match(value: "13812345678",
                                                           category: .phoneNumber,
                                                           range: 0..<11),
                                                rule: rule)
        XCTAssertEqual(ranges, [0..<11])
    }

    func testPolicyCodingRoundTrip() throws {
        var policy = MaskingPolicy.default
        policy.setRule(MaskingRule(style: .sticker, stickerSymbol: "🐱"), for: .face)
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(MaskingPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
        XCTAssertEqual(decoded.rule(for: .face).stickerSymbol, "🐱")
        // Category keyed dictionaries should encode as readable JSON.
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("\"phoneNumber\"") ?? false)
    }
}

final class RedactionPlannerTests: XCTestCase {
    private let line = RecognizedTextLine(id: 0,
                                          text: "手机 13812345678",
                                          box: NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.04))
    private var layout: TextLayout {
        TextLayout(lines: [line], imageSize: PixelSize(width: 1000, height: 2000))
    }

    private func phoneMatch(enabled: Bool = true) -> SensitiveMatch {
        var match = SensitiveMatch(category: .phoneNumber,
                                   ruleID: "phone.cn.mobile",
                                   lineID: 0,
                                   value: "13812345678",
                                   characterRange: 3..<14,
                                   box: line.box(forCharacterRange: 3..<14),
                                   confidence: 0.95)
        match.isEnabled = enabled
        return match
    }

    func testPlanMasksOnlyTheMiddleOfAPhoneNumber() {
        let match = phoneMatch()
        let plan = RedactionPlanner.plan(matches: [match], layout: layout, policy: .default)
        XCTAssertEqual(plan.count, 1)
        let item = plan.items[0]
        let valueBox = line.box(forCharacterRange: 3..<14)
        XCTAssertGreaterThan(item.box.minX, valueBox.minX, "the leading digits stay visible")
        XCTAssertLessThan(item.box.maxX, valueBox.maxX, "the trailing digits stay visible")
        XCTAssertEqual(item.style, .mosaic)
        XCTAssertEqual(item.category, .phoneNumber)
        XCTAssertEqual(item.matchID, match.id)
    }

    func testDisabledMatchIsSkipped() {
        let plan = RedactionPlanner.plan(matches: [phoneMatch(enabled: false)], layout: layout)
        XCTAssertTrue(plan.isEmpty)
    }

    func testPaddingGrowsTheBoxBeyondTheGlyphs() {
        var policy = MaskingPolicy.default
        policy.setRule(MaskingRule(style: .solid), for: .phoneNumber)
        policy.padding = 0.5
        policy.alignmentGrid = 1
        let plan = RedactionPlanner.plan(matches: [phoneMatch()], layout: layout, policy: policy)
        let valueBox = line.box(forCharacterRange: 3..<14)
        XCTAssertLessThan(plan.items[0].box.minY, valueBox.minY)
        XCTAssertGreaterThan(plan.items[0].box.maxY, valueBox.maxY)
    }

    func testReplacementCarriesFakeText() {
        let plan = RedactionPlanner.plan(matches: [phoneMatch()],
                                         layout: layout,
                                         policy: .pseudonymised)
        XCTAssertEqual(plan.items[0].style, .replacement)
        let replacement = plan.items[0].replacementText ?? ""
        XCTAssertEqual(replacement.count, 11)
        XCTAssertNotEqual(replacement, "13812345678")
        XCTAssertTrue(SensitiveValidators.isValidChinaMobile(replacement))
    }

    func testPreviewNeverContainsTheFullValue() {
        let plan = RedactionPlanner.plan(matches: [phoneMatch()], layout: layout)
        XCTAssertFalse(plan.items[0].valuePreview.contains("13812345678"))
        XCTAssertEqual(RedactionPlanner.preview(of: "13812345678"), "1******8")
    }

    func testAdjacentBoxesOfTheSameStyleMerge() {
        let items = [
            RedactionItem(box: NormalizedRect(x: 0.1, y: 0.2, width: 0.1, height: 0.03),
                          style: .mosaic, strength: 0.7, category: .phoneNumber),
            RedactionItem(box: NormalizedRect(x: 0.205, y: 0.2, width: 0.1, height: 0.03),
                          style: .mosaic, strength: 0.7, category: .email)
        ]
        let merged = RedactionPlanner.merge(items, gap: 0.012)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].box.width, 0.205, accuracy: 0.0001)
    }

    func testDistantBoxesDoNotMerge() {
        let items = [
            RedactionItem(box: NormalizedRect(x: 0.1, y: 0.2, width: 0.1, height: 0.03),
                          style: .mosaic, strength: 0.7, category: .phoneNumber),
            RedactionItem(box: NormalizedRect(x: 0.6, y: 0.2, width: 0.1, height: 0.03),
                          style: .mosaic, strength: 0.7, category: .phoneNumber),
            RedactionItem(box: NormalizedRect(x: 0.1, y: 0.5, width: 0.1, height: 0.03),
                          style: .mosaic, strength: 0.7, category: .phoneNumber)
        ]
        XCTAssertEqual(RedactionPlanner.merge(items, gap: 0.012).count, 3)
    }

    func testReplacementItemsAreNeverMerged() {
        let items = (0..<2).map { index in
            RedactionItem(box: NormalizedRect(x: 0.1 + Double(index) * 0.105, y: 0.2, width: 0.1, height: 0.03),
                          style: .replacement, strength: 0.7,
                          replacementText: "fake", category: .phoneNumber)
        }
        XCTAssertEqual(RedactionPlanner.merge(items, gap: 0.012).count, 2)
    }

    func testVisualDetectionsUseTheirOwnBox() {
        let faceBox = NormalizedRect(x: 0.4, y: 0.05, width: 0.2, height: 0.1)
        let face = SensitiveMatch(category: .face,
                                  ruleID: "vision.face",
                                  lineID: nil,
                                  value: "face",
                                  characterRange: 0..<0,
                                  box: faceBox,
                                  confidence: 0.9)
        let plan = RedactionPlanner.plan(matches: [face], layout: layout)
        XCTAssertEqual(plan.count, 1)
        // The face box is used as it is, only grown by the safety padding.
        let box = plan.items[0].box
        XCTAssertLessThanOrEqual(box.minX, faceBox.minX)
        XCTAssertLessThanOrEqual(box.minY, faceBox.minY)
        XCTAssertGreaterThanOrEqual(box.maxX, faceBox.maxX)
        XCTAssertGreaterThanOrEqual(box.maxY, faceBox.maxY)
        XCTAssertGreaterThan(box.iou(faceBox), 0.6)
    }
}

final class PseudonymGeneratorTests: XCTestCase {
    private let generator = PseudonymGenerator(salt: "test")

    func testStableForTheSameValue() {
        let first = generator.replacement(for: "13812345678", category: .phoneNumber)
        let second = generator.replacement(for: "13812345678", category: .phoneNumber)
        XCTAssertEqual(first, second)
    }

    func testDifferentValuesGetDifferentReplacements() {
        XCTAssertNotEqual(generator.replacement(for: "13812345678", category: .phoneNumber),
                          generator.replacement(for: "13998765432", category: .phoneNumber))
    }

    func testSaltChangesTheOutcome() {
        XCTAssertNotEqual(generator.replacement(for: "13812345678", category: .phoneNumber),
                          PseudonymGenerator(salt: "other").replacement(for: "13812345678", category: .phoneNumber))
    }

    func testGeneratedIDCardIsWellFormed() {
        let fake = generator.replacement(for: "11010519491231002X", category: .idCard)
        XCTAssertEqual(fake.count, 18)
        XCTAssertTrue(SensitiveValidators.isValidChinaID(fake), "a fake ID should still pass validation")
    }

    func testGeneratedBankCardPassesLuhn() {
        let fake = generator.replacement(for: "6222021234567890", category: .bankCard)
        XCTAssertTrue(SensitiveValidators.isLuhnValid(fake))
        XCTAssertTrue(fake.hasPrefix("62"))
    }

    func testSeparatorStyleIsPreserved() {
        let fake = generator.replacement(for: "138 1234 5678", category: .phoneNumber)
        XCTAssertEqual(fake.filter { $0 == " " }.count, 2)
    }

    func testAmountKeepsItsShape() {
        XCTAssertEqual(generator.replacement(for: "¥1,280.00", category: .amount), "¥*,***.**")
    }

    func testGeneratedPlateAndVINLookValid() {
        let plate = generator.replacement(for: "沪A12345", category: .plateNumber)
        XCTAssertEqual(plate.count, 7)
        let vin = generator.replacement(for: "1M8GDM9AXKP042788", category: .vehicleIdentification)
        XCTAssertEqual(vin.count, 17)
        XCTAssertFalse(vin.contains("I"))
    }
}

final class RedactionVerifierTests: XCTestCase {
    private let line = RecognizedTextLine(id: 0,
                                          text: "身份证 11010519491231002X",
                                          box: NormalizedRect(x: 0.05, y: 0.3, width: 0.8, height: 0.04))
    private var layout: TextLayout {
        TextLayout(lines: [line], imageSize: PixelSize(width: 1200, height: 3000))
    }
    private var match: SensitiveMatch {
        SensitiveMatch(category: .idCard,
                       ruleID: "id.cn.resident18",
                       lineID: 0,
                       value: "11010519491231002X",
                       characterRange: 4..<22,
                       box: line.box(forCharacterRange: 4..<22),
                       confidence: 0.97)
    }

    func testCleanPlanHasNoCoverageIssues() {
        let plan = RedactionPlanner.plan(matches: [match], layout: layout, policy: .strict)
        XCTAssertTrue(RedactionVerifier.coverageIssues(matches: [match],
                                                       layout: layout,
                                                       policy: .strict,
                                                       plan: plan).isEmpty)
    }

    func testMissingItemIsReported() {
        let issues = RedactionVerifier.coverageIssues(matches: [match],
                                                      layout: layout,
                                                      policy: .strict,
                                                      plan: RedactionPlan(items: [], imageSize: layout.imageSize))
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].category, .idCard)
        XCTAssertEqual(issues[0].coveredFraction, 0, accuracy: 0.0001)
    }

    func testReadableValueAfterRenderingIsALeak() {
        let plan = RedactionPlanner.plan(matches: [match], layout: layout, policy: .strict)
        let leaks = RedactionVerifier.residualLeaks(originalMatches: [match],
                                                    rescanned: [match],
                                                    plan: plan)
        XCTAssertEqual(leaks.map(\.reason), [.valueStillReadable])
        XCTAssertFalse(leaks[0].valuePreview.contains("11010519491231002X"))
    }

    func testTextFoundInsideAMaskedAreaIsALeak() {
        let plan = RedactionPlanner.plan(matches: [match], layout: layout, policy: .strict)
        let other = SensitiveMatch(category: .phoneNumber,
                                   ruleID: "phone.cn.mobile",
                                   lineID: 9,
                                   value: "13812345678",
                                   characterRange: 0..<11,
                                   box: plan.items[0].box,
                                   confidence: 0.9)
        let leaks = RedactionVerifier.residualLeaks(originalMatches: [match], rescanned: [other], plan: plan)
        XCTAssertEqual(leaks.map(\.reason), [.textInsideMaskedArea])
    }

    func testPseudonymisedOutputIsNotAFalseAlarm() {
        let plan = RedactionPlanner.plan(matches: [match], layout: layout, policy: .pseudonymised)
        let fake = SensitiveMatch(category: .idCard,
                                  ruleID: "id.cn.resident18",
                                  lineID: 0,
                                  value: plan.items[0].replacementText ?? "",
                                  characterRange: 4..<22,
                                  box: match.box,
                                  confidence: 0.97)
        XCTAssertTrue(RedactionVerifier.residualLeaks(originalMatches: [match], rescanned: [fake], plan: plan).isEmpty)
    }

    func testAuditSummarisesByCategory() {
        let plan = RedactionPlanner.plan(matches: [match], layout: layout, policy: .default)
        let audit = RedactionVerifier.audit(plan: plan,
                                            matches: [match],
                                            layout: layout,
                                            policy: .default,
                                            rescanned: [])
        XCTAssertEqual(audit.itemCount, 1)
        XCTAssertEqual(audit.entries.map(\.category), [.idCard])
        XCTAssertTrue(audit.wasVerified)
        XCTAssertTrue(audit.isClean)
        XCTAssertEqual(audit.potentiallyReversibleCount, 0)
    }

    func testAuditFlagsReversibleStyles() {
        var policy = MaskingPolicy.default
        policy.setRule(MaskingRule(style: .blur), for: .idCard)
        let plan = RedactionPlanner.plan(matches: [match], layout: layout, policy: policy)
        let audit = RedactionVerifier.audit(plan: plan, matches: [match], layout: layout, policy: policy)
        XCTAssertEqual(audit.potentiallyReversibleCount, 1)
        XCTAssertFalse(audit.wasVerified)
    }
}
