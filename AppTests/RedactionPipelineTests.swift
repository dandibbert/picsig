import XCTest
import UIKit
@testable import PicSig
import PicSigCore

/// End-to-end tests for the masking pipeline against the *real* Vision framework.
///
/// The Linux suite covers the rule engine with hand-built text layouts, which proves
/// the rules are right but says nothing about whether OCR on a real screenshot
/// produces layouts those rules can work with. That gap is what this file closes:
/// every test here starts from rendered pixels and ends at rendered pixels.
final class RedactionPipelineTests: XCTestCase {
    /// Masking everything, preserving nothing — the right baseline for the tests that
    /// assert a value became unreadable. The shipping defaults deliberately keep some
    /// characters visible, which is tested separately.
    private var destructivePolicy: MaskingPolicy {
        MaskingPolicy(defaultRule: MaskingRule(style: .solid, strength: 1), overrides: [:])
    }

    private func coordinator(policy: MaskingPolicy? = nil) -> RedactionCoordinator {
        var coordinator = RedactionCoordinator()
        // These images are one screen tall, so tiling is not what is under test and a
        // single tile keeps the runs fast.
        coordinator.textOptions.tileHeight = 4000
        coordinator.visualOptions.detectsFaces = false
        coordinator.visualOptions.detectsBarcodes = false
        if let policy { coordinator.policy = policy }
        return coordinator
    }

    private func scan(_ image: UIImage,
                      using coordinator: RedactionCoordinator) throws -> RedactionCoordinator.ScanResult {
        let cgImage = try XCTUnwrap(image.cgImage)
        return try coordinator.scan(image: cgImage)
    }

    // MARK: - Recognition

    func testOCRReadsAChineseLabelledPhoneNumber() throws {
        let image = SyntheticScreenshot.make(rows: [
            .init(label: "收货人", value: "张伟"),
            .init(label: "联系电话", value: "13812345678"),
            .init(label: "收货地址", value: "上海市浦东新区世纪大道 100 号")
        ])

        let result = try scan(image, using: coordinator())
        XCTAssertTrue(result.layout.plainText.contains("13812345678"),
                      "OCR did not read the phone number back. Recognised:\n\(result.layout.plainText)")
    }

    func testPhoneNumberIsDetectedFromRealOCROutput() throws {
        let image = SyntheticScreenshot.make(rows: [
            .init(label: "联系电话", value: "13812345678")
        ])

        let result = try scan(image, using: coordinator())
        let match = try XCTUnwrap(result.matches.first { $0.category == .phoneNumber },
                                  "no phone number match; got \(describe(result.matches))")
        XCTAssertEqual(match.value, "13812345678")
        XCTAssertGreaterThan(match.confidence, 0.5)
        // The label is what lifts a bare 11 digit run to a confident match.
        XCTAssertEqual(match.contextLabel, "联系电话")
    }

    /// Both values below carry real checksums — a Luhn valid UnionPay number and an ID
    /// whose MOD 11-2 check digit is correct. Using invalid ones would prove nothing,
    /// because the detector is supposed to reject those.
    func testBankCardAndIDCardAreDetectedWithChecksums() throws {
        let image = SyntheticScreenshot.make(rows: [
            .init(label: "银行卡号", value: Self.luhnValidCard),
            .init(label: "身份证号", value: Self.validChinaID)
        ])

        let result = try scan(image, using: coordinator())
        let categories = Set(result.matches.map(\.category))
        XCTAssertTrue(categories.contains(.bankCard), "no bank card; got \(describe(result.matches))")
        XCTAssertTrue(categories.contains(.idCard), "no ID card; got \(describe(result.matches))")
    }

    /// The flip side: a number that looks like an ID but fails its check digit must not
    /// be reported as one. This is what keeps order numbers from being masked as IDs.
    func testIDCardWithABadCheckDigitIsNotReportedAsAnID() throws {
        let image = SyntheticScreenshot.make(rows: [
            .init(label: "订单编号", value: "11010119900307617X")
        ])
        let result = try scan(image, using: coordinator())
        XCTAssertFalse(result.matches.contains { $0.category == .idCard },
                       "an ID with a wrong check digit was accepted; got \(describe(result.matches))")
    }

    func testEmailIsDetected() throws {
        let image = SyntheticScreenshot.make(rows: [.init(value: "zhangwei@example.com")])
        let result = try scan(image, using: coordinator())
        XCTAssertTrue(result.matches.contains { $0.category == .email },
                      "no email; got \(describe(result.matches))")
    }

    // MARK: - Masking actually destroys the value

    /// The claim the whole feature rests on: after masking, the value cannot be read
    /// out of the exported pixels. This renders the mask and re-runs OCR to check.
    func testSolidMaskedPhoneNumberIsNoLongerReadable() throws {
        let image = SyntheticScreenshot.make(rows: [
            .init(label: "联系电话", value: "13812345678")
        ])
        let coordinator = self.coordinator(policy: destructivePolicy)
        let scanned = try scan(image, using: coordinator)
        XCTAssertFalse(scanned.plan.isEmpty, "nothing planned, so the rest of this test proves nothing")

        let masked = RedactionRenderer.apply(plan: scanned.plan, to: image)
        let reread = try recognisedText(in: masked)
        XCTAssertFalse(reread.contains("13812345678"),
                       "the phone number survived masking. Re-read:\n\(reread)")
    }

    /// Mosaic must be at least as destructive as a solid block, since it is the style
    /// the UI recommends for anything that must not be recoverable.
    func testMosaicMaskedIDCardIsNoLongerReadable() throws {
        let image = SyntheticScreenshot.make(rows: [
            .init(label: "身份证号", value: Self.validChinaID)
        ])
        var policy = destructivePolicy
        policy.defaultRule = MaskingRule(style: .mosaic, strength: 0.95)
        let coordinator = self.coordinator(policy: policy)

        let scanned = try scan(image, using: coordinator)
        XCTAssertFalse(scanned.plan.isEmpty, "nothing planned, so the rest of this test proves nothing")

        let masked = RedactionRenderer.apply(plan: scanned.plan, to: image)
        let reread = try recognisedText(in: masked)
        XCTAssertFalse(reread.contains(Self.validChinaID.dropLast()),
                       "the ID number survived masking. Re-read:\n\(reread)")
    }

    /// Character level masking is what keeps a masked row recognisable, and it is the
    /// shipping default for phone numbers, so it is worth pinning down on real pixels.
    ///
    /// The assertion counts surviving digits rather than looking for exact substrings:
    /// OCR reading an isolated `138` next to a black bar as `13%` is noise, not a bug,
    /// but it still tells us the digits were not destroyed. Masking the whole value is
    /// rendered as a control so the comparison means something.
    func testPreservedDigitsSurviveWhileTheMiddleDoesNot() throws {
        let image = SyntheticScreenshot.make(rows: [
            .init(label: "联系电话", value: "13812345678")
        ])

        func maskedDigitCount(preserveLeading: Int, preserveTrailing: Int) throws -> (digits: Int, text: String) {
            var policy = MaskingPolicy(defaultRule: MaskingRule(style: .solid, strength: 1), overrides: [:])
            policy.setRule(MaskingRule(style: .solid,
                                       preserveLeading: preserveLeading,
                                       preserveTrailing: preserveTrailing,
                                       strength: 1),
                           for: .phoneNumber)
            let scanned = try scan(image, using: coordinator(policy: policy))
            XCTAssertFalse(scanned.plan.isEmpty)
            let text = try recognisedText(in: RedactionRenderer.apply(plan: scanned.plan, to: image))
            return (text.filter(\.isNumber).count, text)
        }

        let everything = try maskedDigitCount(preserveLeading: 0, preserveTrailing: 0)
        let partial = try maskedDigitCount(preserveLeading: 3, preserveTrailing: 4)

        XCTAssertFalse(partial.text.contains("13812345678"),
                       "the full number is still readable:\n\(partial.text)")
        XCTAssertGreaterThan(partial.digits, everything.digits,
                             """
                             character level masking left no more digits than masking \
                             everything, so the preserve settings did nothing.
                             preserved 3+4: \(partial.text)
                             preserved none: \(everything.text)
                             """)
        XCTAssertGreaterThanOrEqual(partial.digits, 3,
                                    "expected roughly 3 leading + 4 trailing digits, got \(partial.text)")
    }

    // MARK: - Verification

    /// The audit is the app's own answer to "did the masking work", and it runs before
    /// every export. It must say yes on a properly masked image …
    func testAuditIsCleanAfterMasking() throws {
        let image = SyntheticScreenshot.make(rows: [
            .init(label: "联系电话", value: "13812345678"),
            .init(label: "银行卡号", value: Self.luhnValidCard)
        ])
        let coordinator = self.coordinator(policy: destructivePolicy)
        let scanned = try scan(image, using: coordinator)

        let masked = RedactionRenderer.apply(plan: scanned.plan, to: image)
        let maskedCG = try XCTUnwrap(masked.cgImage)

        let audit = try coordinator.verify(rendered: maskedCG,
                                           matches: scanned.matches,
                                           layout: scanned.layout,
                                           plan: scanned.plan)
        XCTAssertTrue(audit.isClean,
                      "audit reported leaks on a masked image: \(audit.residualLeaks.map(\.valuePreview))")
    }

    /// … and no on an unmasked one. Without this, a verifier hard-wired to return
    /// "clean" would sail through the test above.
    func testAuditReportsLeaksWhenNothingWasMasked() throws {
        let image = SyntheticScreenshot.make(rows: [
            .init(label: "联系电话", value: "13812345678")
        ])
        let coordinator = self.coordinator(policy: destructivePolicy)
        let scanned = try scan(image, using: coordinator)
        let original = try XCTUnwrap(image.cgImage)

        // Audit the *original* pixels against a plan that claims to have masked them.
        let audit = try coordinator.verify(rendered: original,
                                           matches: scanned.matches,
                                           layout: scanned.layout,
                                           plan: scanned.plan)
        XCTAssertFalse(audit.isClean, "the verifier called an unmasked image clean")
    }

    // MARK: - Helpers

    /// Luhn valid, UnionPay prefix, so it satisfies the strict `bank.card` rule rather
    /// than only the context-only fallback.
    private static let luhnValidCard = "6222021234567894"
    /// MOD 11-2 check digit is correct for 11010119900307617.
    private static let validChinaID = "110101199003076173"

    private func recognisedText(in image: UIImage) throws -> String {
        var service = TextRecognitionService()
        service.options.tileHeight = 4000
        service.options.computesCharacterBoxes = false
        let cgImage = try XCTUnwrap(image.cgImage)
        return try service.recognize(cgImage: cgImage).plainText
    }

    private func describe(_ matches: [SensitiveMatch]) -> String {
        matches.map { "\($0.category) '\($0.value)'" }.joined(separator: ", ")
    }
}
