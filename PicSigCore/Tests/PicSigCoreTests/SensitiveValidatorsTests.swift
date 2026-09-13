import XCTest
@testable import PicSigCore

final class SensitiveValidatorsTests: XCTestCase {
    func testLuhn() {
        XCTAssertTrue(SensitiveValidators.isLuhnValid("4111111111111111"))
        XCTAssertFalse(SensitiveValidators.isLuhnValid("4111111111111112"))
        XCTAssertTrue(SensitiveValidators.isLuhnValid("4111 1111 1111 1111"))
    }

    func testLuhnCheckDigitProducesValidNumbers() {
        let body = "622202123456789"
        let card = body + String(SensitiveValidators.luhnCheckDigit(for: body))
        XCTAssertTrue(SensitiveValidators.isLuhnValid(card))
        XCTAssertTrue(SensitiveValidators.isPlausibleBankCard(card))
    }

    func testBankCardPlausibility() {
        XCTAssertFalse(SensitiveValidators.isPlausibleBankCard("1234"), "too short")
        // 18 digit ID cards start with 1..9 but never pass as a card because of
        // the issuer prefix check.
        XCTAssertFalse(SensitiveValidators.isPlausibleBankCard("110105194912310021"))
    }

    func testChinaIDChecksum() {
        let body = "11010519491231002"
        guard let check = SensitiveValidators.chinaIDCheckCharacter(for: body) else {
            return XCTFail("no check character")
        }
        let id = body + String(check)
        XCTAssertTrue(SensitiveValidators.isValidChinaID(id))
        XCTAssertEqual(id.count, 18)

        // A single wrong digit must fail.
        let broken = "11010519491231003" + String(check)
        XCTAssertFalse(SensitiveValidators.isValidChinaID(broken))
    }

    func testChinaIDRejectsImpossibleValues() {
        XCTAssertFalse(SensitiveValidators.isValidChinaID("99010519491231002X"), "unknown province")
        XCTAssertFalse(SensitiveValidators.isValidChinaID("11010519491331002X"), "month 13")
        XCTAssertFalse(SensitiveValidators.isValidChinaID("11010519490231002X"), "31 February")
        XCTAssertFalse(SensitiveValidators.isValidChinaID("1101051949123100"), "too short")
    }

    func testLegacyChinaID() {
        XCTAssertTrue(SensitiveValidators.isValidLegacyChinaID("310104800101001"))
        XCTAssertFalse(SensitiveValidators.isValidLegacyChinaID("310104801301001"))
    }

    func testMobileValidation() {
        XCTAssertTrue(SensitiveValidators.isValidChinaMobile("13812345678"))
        XCTAssertTrue(SensitiveValidators.isValidChinaMobile("138 1234 5678"))
        XCTAssertFalse(SensitiveValidators.isValidChinaMobile("12812345678"), "second digit out of range")
        XCTAssertFalse(SensitiveValidators.isValidChinaMobile("1381234567"), "too short")
        XCTAssertFalse(SensitiveValidators.isValidChinaMobile("11111111111"), "single repeated digit")
    }

    func testVIN() {
        XCTAssertTrue(SensitiveValidators.isValidVIN("1M8GDM9AXKP042788"))
        XCTAssertFalse(SensitiveValidators.isValidVIN("1M8GDM9A_KP042788"))
        XCTAssertFalse(SensitiveValidators.isValidVIN("1M8GDM9AXKP04278"))
    }

    func testPlaceholderDetection() {
        XCTAssertTrue(SensitiveValidators.looksLikePlaceholder("00000000"))
        XCTAssertTrue(SensitiveValidators.looksLikePlaceholder("12345678"))
        XCTAssertFalse(SensitiveValidators.looksLikePlaceholder("13812345678"))
    }

    func testLeapYear() {
        XCTAssertTrue(SensitiveValidators.isPlausibleBirthDate("20000229"))
        XCTAssertFalse(SensitiveValidators.isPlausibleBirthDate("19000229"))
    }
}
