import XCTest
@testable import PicSigCore

final class SensitiveScannerTests: XCTestCase {
    private let validID: String = {
        let body = "11010519491231002"
        return body + String(SensitiveValidators.chinaIDCheckCharacter(for: body) ?? "X")
    }()

    private let validCard: String = {
        let body = "622202123456789"
        return body + String(SensitiveValidators.luhnCheckDigit(for: body))
    }()

    private func scan(_ text: String, settings: ScanSettings = .default) -> [SensitiveMatch] {
        SensitiveScanner(settings: settings).scan(text: text)
    }

    // MARK: Phone numbers

    func testFindsMobileNumberInsideChineseSentence() {
        let matches = scan("联系电话13812345678，请及时查收")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.category, .phoneNumber)
        XCTAssertEqual(matches.first?.value, "13812345678")
        XCTAssertEqual(matches.first?.contextLabel, "联系电话")
        XCTAssertGreaterThan(matches.first?.confidence ?? 0, 0.9)
    }

    func testFindsGroupedMobileNumber() {
        let matches = scan("手机 138 1234 5678")
        XCTAssertEqual(matches.map(\.category), [.phoneNumber])
        XCTAssertEqual(matches.first?.value, "138 1234 5678")
    }

    func testIgnoresInvalidMobilePrefix() {
        XCTAssertTrue(scan("订单编号 12812345678").isEmpty)
    }

    func testPlaceholderNumberIsNotMasked() {
        // 11111111111 and 12345678901 appear in mock-ups, not in real life.
        XCTAssertTrue(scan("客服热线 11111111111").isEmpty)
    }

    // MARK: Documents

    func testFindsIDCardWithValidChecksum() {
        let matches = scan("身份证号 \(validID)")
        XCTAssertEqual(matches.map(\.category), [.idCard])
        XCTAssertEqual(matches.first?.value, validID)
    }

    func testRejectsIDCardWithBrokenChecksum() {
        let broken = String(validID.dropLast()) + (validID.hasSuffix("1") ? "2" : "1")
        XCTAssertFalse(scan("身份证号 \(broken)").contains { $0.category == .idCard })
    }

    func testFindsGroupedBankCardOnce() {
        let formatted = stride(from: 0, to: validCard.count, by: 4)
            .map { String(validCard.dropFirst($0).prefix(4)) }
            .joined(separator: " ")
        let matches = scan("银行卡号 \(formatted)")
        XCTAssertEqual(matches.count, 1, "the card and the long-digit rules must not both report it")
        XCTAssertEqual(matches.first?.category, .bankCard)
        XCTAssertEqual(SensitiveValidators.digitsOnly(matches.first?.value ?? ""), validCard)
    }

    func testEmail() {
        let matches = scan("邮箱：zhang.wei+dev@example.com.cn")
        XCTAssertEqual(matches.map(\.category), [.email])
        XCTAssertEqual(matches.first?.value, "zhang.wei+dev@example.com.cn")
    }

    // MARK: Context driven rules

    func testVerificationCodeNeedsItsLabel() {
        let matches = scan("验证码 8321，5分钟内有效")
        XCTAssertEqual(matches.map(\.category), [.verificationCode])
        XCTAssertEqual(matches.first?.value, "8321", "only the digits are masked, not the label")

        XCTAssertTrue(scan("房号 8321").isEmpty)
    }

    func testNameOnlyMatchesWithNearbyLabel() {
        let withLabel = scan("收件人 张伟")
        XCTAssertEqual(withLabel.map(\.category), [.personName])
        XCTAssertEqual(withLabel.first?.value, "张伟")

        XCTAssertTrue(scan("张伟").isEmpty, "a bare name is below the default confidence")
    }

    /// Vision reports most real lines at confidence 0.5. That used to halve every
    /// match's score and drop even checksum-valid phone numbers.
    func testLowOCRConfidenceDoesNotDropAValidPhoneNumber() {
        let layout = TextLayout(lines: [
            RecognizedTextLine(id: 0, text: "13812345678",
                               box: NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.03),
                               confidence: 0.5)
        ], imageSize: PixelSize(width: 1000, height: 2000))
        let matches = SensitiveScanner().scan(layout)
        XCTAssertEqual(matches.map(\.category), [.phoneNumber])
        XCTAssertGreaterThan(matches.first?.confidence ?? 0, 0.7)
    }

    func testLabelGluedToTheNameIsStillFound() {
        XCTAssertEqual(scan("收货人张伟").map(\.value), ["张伟"])
        XCTAssertEqual(scan("姓名:欧阳娜娜").map(\.value), ["欧阳娜娜"])
        XCTAssertEqual(scan("收件人：李强 13812345678").map(\.category), [.personName, .phoneNumber])
    }

    func testTitledNamesNeedNoLabel() {
        XCTAssertEqual(scan("请联系张先生确认").map(\.value), ["张先生"])
        XCTAssertEqual(scan("联系小李").map(\.value), ["小李"])
        XCTAssertEqual(scan("老陈：好的").map(\.value), ["老陈"])
        XCTAssertTrue(scan("两小时后").isEmpty, "小时 is a word, not a person")
        XCTAssertEqual(scan("王总说可以").map(\.value), ["王总"])
    }

    func testBareNameLineIsListedOnlyBelowTheDefaultThreshold() {
        XCTAssertTrue(scan("张伟").isEmpty)
        let relaxed = ScanSettings(minConfidence: 0.45)
        let matches = scan("张伟", settings: relaxed)
        XCTAssertEqual(matches.map(\.value), ["张伟"])
        XCTAssertLessThan(matches.first?.confidence ?? 1, 0.6, "a bare name must start unchecked")
        XCTAssertTrue(scan("设置", settings: relaxed).isEmpty, "UI words without a surname are not names")
    }

    func testAddressesWithoutProvinceOrWithOCRSpaces() {
        XCTAssertEqual(scan("浦东新区张江路123号").map(\.category), [.address])
        XCTAssertEqual(scan("上海市 浦东新区 张江路 123号").map(\.category), [.address])
        XCTAssertEqual(scan("张江路123号").map(\.category), [.address])
        XCTAssertEqual(scan("阳光花园3栋2单元501室").map(\.category), [.address])
        XCTAssertEqual(scan("收货地址：北京市朝阳区建国路88号SOHO现代城A座1203").map(\.category), [.address])
    }

    func testLabelOnTheLineAboveCounts() {
        let layout = TextLayout(lines: [
            RecognizedTextLine(id: 0, text: "持卡人", box: NormalizedRect(x: 0.1, y: 0.10, width: 0.2, height: 0.03)),
            RecognizedTextLine(id: 1, text: "李强", box: NormalizedRect(x: 0.1, y: 0.14, width: 0.2, height: 0.03))
        ], imageSize: PixelSize(width: 1000, height: 2000))

        let matches = SensitiveScanner().scan(layout)
        XCTAssertEqual(matches.map(\.category), [.personName])
        XCTAssertEqual(matches.first?.contextLabel, "持卡人")
    }

    func testLabelToTheLeftCounts() {
        let layout = TextLayout(lines: [
            RecognizedTextLine(id: 0, text: "户名", box: NormalizedRect(x: 0.08, y: 0.30, width: 0.12, height: 0.03)),
            RecognizedTextLine(id: 1, text: "王芳", box: NormalizedRect(x: 0.55, y: 0.301, width: 0.14, height: 0.03))
        ], imageSize: PixelSize(width: 1000, height: 2000))

        let matches = SensitiveScanner().scan(layout)
        XCTAssertEqual(matches.map(\.value), ["王芳"])
    }

    func testAmountRequiresContextAndItsCategory() {
        let settings = ScanSettings(enabledCategories: [.amount], minConfidence: 0.6)
        let matches = scan("账户余额 ¥1,280.00", settings: settings)
        XCTAssertEqual(matches.map(\.category), [.amount])

        XCTAssertTrue(scan("累计里程 1,280.00", settings: ScanSettings(enabledCategories: [.amount],
                                                                  minConfidence: 0.9)).isEmpty)
        XCTAssertTrue(scan("账户余额 ¥1,280.00").isEmpty, "amounts are off by default")
    }

    func testContextCanBeDisabled() {
        var settings = ScanSettings.default
        settings.useContext = false
        let matches = scan("验证码 8321", settings: settings)
        XCTAssertEqual(matches.map(\.category), [.verificationCode],
                       "rules whose keyword is part of the pattern still work")
    }

    // MARK: Secrets

    func testSecrets() {
        XCTAssertEqual(scan("token: sk-abcdefghijklmnopqrstuvwx").map(\.category), [.credential])
        XCTAssertEqual(scan("Authorization: Bearer abcdefghijklmnopqrst").map(\.category), [.credential])
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP"
        XCTAssertEqual(scan(jwt).map(\.category), [.credential])
    }

    func testLabelledPasswordMasksOnlyTheValue() {
        let matches = scan("password: hunter2000")
        XCTAssertEqual(matches.first?.value, "hunter2000")
    }

    // MARK: Lists and propagation

    func testAllowListWins() {
        var settings = ScanSettings.default
        settings.allowList = ["13812345678"]
        XCTAssertTrue(scan("联系电话13812345678", settings: settings).isEmpty)
    }

    func testDenyListAddsLiterals() {
        var settings = ScanSettings.default
        settings.denyList = ["ProjectFalcon"]
        let matches = scan("内部代号 ProjectFalcon 已上线", settings: settings)
        XCTAssertEqual(matches.map(\.category), [.custom])
        XCTAssertEqual(matches.first?.value, "ProjectFalcon")
    }

    func testConfidentValueIsMaskedWhereverItAppears() {
        let matches = scan("收件人 张伟\n张伟已签收")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(Set(matches.map(\.value)), ["张伟"])
        XCTAssertTrue(matches.contains { $0.ruleID.hasSuffix(".propagated") })
    }

    func testPropagationCanBeSwitchedOff() {
        var settings = ScanSettings.default
        settings.propagateRepeatedValues = false
        XCTAssertEqual(scan("收件人 张伟\n张伟已签收", settings: settings).count, 1)
    }

    func testDuplicateAcrossASeamIsReportedOnce() {
        // The same row captured twice at nearly the same place: a stitch seam.
        let layout = TextLayout(lines: [
            RecognizedTextLine(id: 0, text: "手机 13812345678",
                               box: NormalizedRect(x: 0.1, y: 0.500, width: 0.5, height: 0.02)),
            RecognizedTextLine(id: 1, text: "手机 13812345678",
                               box: NormalizedRect(x: 0.1, y: 0.502, width: 0.5, height: 0.02))
        ], imageSize: PixelSize(width: 1000, height: 4000))

        XCTAssertEqual(SensitiveScanner().scan(layout).count, 1)
    }

    // MARK: Rule administration

    func testDisablingARule() {
        var settings = ScanSettings.default
        settings.disabledRuleIDs = ["phone.cn.mobile", "phone.cn.mobile.international"]
        XCTAssertTrue(scan("联系电话13812345678", settings: settings).isEmpty)
    }

    func testCustomLiteralRule() {
        var settings = ScanSettings.default
        settings.enabledCategories.insert(.custom)
        settings.customRules = [CustomSensitiveRule(name: "工号", pattern: "EMP-[0-9]{4}")]
        let matches = scan("工号 EMP-2048", settings: settings)
        XCTAssertEqual(matches.map(\.value), ["EMP-2048"])
    }

    func testInvalidCustomRuleIsReportedAndIgnored() {
        let rule = CustomSensitiveRule(name: "broken", pattern: "([0-9")
        XCTAssertNotNil(rule.patternError)
        var settings = ScanSettings.default
        settings.customRules = [rule]
        XCTAssertNoThrow(SensitiveScanner(settings: settings))
    }

    func testOptionalRulesStayOffUntilEnabled() {
        let scanner = SensitiveScanner()
        XCTAssertFalse(scanner.activeRuleIDs.contains("phone.masked.tail"))

        var settings = ScanSettings.default
        settings.enabledRuleIDs = ["phone.masked.tail"]
        XCTAssertTrue(SensitiveScanner(settings: settings).activeRuleIDs.contains("phone.masked.tail"))
    }

    func testEnabledCategoryActivatesItsRules() {
        var settings = ScanSettings.default
        settings.enabledCategories.insert(.ipAddress)
        XCTAssertEqual(scan("服务器 192.168.31.24", settings: settings).map(\.category), [.ipAddress])
    }

    // MARK: Geometry

    func testBoxCoversOnlyTheValue() {
        let line = RecognizedTextLine(id: 0,
                                      text: "联系电话13812345678",
                                      box: NormalizedRect(x: 0, y: 0, width: 1, height: 0.05))
        let layout = TextLayout(lines: [line], imageSize: PixelSize(width: 1000, height: 1000))
        guard let match = SensitiveScanner().scan(layout).first else { return XCTFail("no match") }

        // "联系电话" is four full width characters (weight 2) and the number is 11
        // narrow ones, so the value starts a bit after a third of the line.
        XCTAssertGreaterThan(match.box.minX, 0.3)
        XCTAssertLessThan(match.box.minX, 0.5)
        XCTAssertEqual(match.box.maxX, 1, accuracy: 0.01)
        XCTAssertEqual(match.box.height, 0.05, accuracy: 0.0001)
    }

    func testUsesCharacterBoxesWhenAvailable() {
        let text = "手机13812345678"
        let characters = Array(text)
        let boxes = characters.indices.map { index in
            NormalizedRect(x: Double(index) * 0.05, y: 0.2, width: 0.05, height: 0.03)
        }
        let line = RecognizedTextLine(id: 0,
                                      text: text,
                                      box: NormalizedRect(x: 0, y: 0.2, width: Double(characters.count) * 0.05, height: 0.03),
                                      characterBoxes: boxes)
        let layout = TextLayout(lines: [line], imageSize: PixelSize(width: 1000, height: 1000))
        guard let match = SensitiveScanner().scan(layout).first else { return XCTFail("no match") }

        XCTAssertEqual(match.box.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(match.box.maxX, 0.65, accuracy: 0.0001)
    }

    func testEmptyInput() {
        XCTAssertTrue(SensitiveScanner().scan(.empty).isEmpty)
        XCTAssertTrue(SensitiveScanner().scan(text: "").isEmpty)
    }
}
