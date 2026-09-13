import Foundation

/// Checksum and plausibility checks. They are what keeps the detector from
/// masking every 16 digit order number as a bank card.
public enum SensitiveValidators {
    /// Removes the separators humans put into numbers.
    public static func digitsOnly(_ text: String) -> String {
        text.filter { $0.isNumber }
    }

    public static func stripSeparators(_ text: String) -> String {
        text.filter { !" -–—\u{00A0}".contains($0) }
    }

    /// Luhn check used by bank cards.
    public static func isLuhnValid(_ text: String) -> Bool {
        let digits = digitsOnly(text).compactMap { $0.wholeNumberValue }
        guard digits.count >= 12 else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    public static func isPlausibleBankCard(_ text: String) -> Bool {
        let digits = digitsOnly(text)
        guard (13...19).contains(digits.count) else { return false }
        guard let first = digits.first else { return false }
        // Visa/Master/UnionPay/JCB/Amex/Discover all start with 3-6; 9 is used by
        // some domestic issuers.
        guard "3456789".contains(first) else { return false }
        return isLuhnValid(digits)
    }

    /// Mainland China resident ID: 17 digits + ISO 7064 MOD 11-2 check character.
    public static func isValidChinaID(_ text: String) -> Bool {
        let value = stripSeparators(text).uppercased()
        guard value.count == 18 else { return isValidLegacyChinaID(value) }
        let characters = Array(value)
        guard characters.dropLast().allSatisfy({ $0.isNumber }) else { return false }
        guard isPlausibleBirthDate(String(characters[6..<14])) else { return false }
        guard isValidRegionCode(String(characters[0..<6])) else { return false }

        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        var sum = 0
        for index in 0..<17 {
            guard let digit = characters[index].wholeNumberValue else { return false }
            sum += digit * weights[index]
        }
        let checkTable = Array("10X98765432")
        return characters[17] == checkTable[sum % 11]
    }

    /// The 15 digit format issued before 1999 has no check digit.
    public static func isValidLegacyChinaID(_ text: String) -> Bool {
        let value = stripSeparators(text)
        guard value.count == 15, value.allSatisfy({ $0.isNumber }) else { return false }
        let characters = Array(value)
        guard isValidRegionCode(String(characters[0..<6])) else { return false }
        return isPlausibleBirthDate("19" + String(characters[6..<12]))
    }

    /// `yyyyMMdd`
    public static func isPlausibleBirthDate(_ text: String) -> Bool {
        guard text.count == 8, text.allSatisfy({ $0.isNumber }) else { return false }
        let characters = Array(text)
        guard let year = Int(String(characters[0..<4])),
              let month = Int(String(characters[4..<6])),
              let day = Int(String(characters[6..<8])) else { return false }
        guard (1900...2100).contains(year), (1...12).contains(month) else { return false }
        let daysPerMonth = [31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...daysPerMonth[month - 1]).contains(day)
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// First two digits of an ID card are the province code.
    public static func isValidRegionCode(_ text: String) -> Bool {
        guard text.count == 6, let province = Int(text.prefix(2)) else { return false }
        let valid: Set<Int> = [11, 12, 13, 14, 15, 21, 22, 23, 31, 32, 33, 34, 35, 36, 37,
                               41, 42, 43, 44, 45, 46, 50, 51, 52, 53, 54, 61, 62, 63, 64,
                               65, 71, 81, 82, 91]
        return valid.contains(province)
    }

    /// Mainland mobile numbers: 11 digits starting with 1 and a valid second digit.
    public static func isValidChinaMobile(_ text: String) -> Bool {
        let digits = digitsOnly(text)
        guard digits.count == 11, digits.hasPrefix("1") else { return false }
        guard let second = digits.dropFirst().first, "3456789".contains(second) else { return false }
        // A run of one repeated digit is almost always a placeholder in a mock-up.
        return Set(digits).count > 2
    }

    /// Vehicle identification numbers exclude I, O and Q and carry a check digit
    /// in position nine.
    public static func isValidVIN(_ text: String) -> Bool {
        let value = stripSeparators(text).uppercased()
        guard value.count == 17 else { return false }
        guard value.allSatisfy({ $0.isNumber || ($0.isLetter && !"IOQ".contains($0)) }) else { return false }
        let transliteration: [Character: Int] = [
            "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8,
            "J": 1, "K": 2, "L": 3, "M": 4, "N": 5, "P": 7, "R": 9,
            "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9
        ]
        let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
        var sum = 0
        for (index, character) in value.enumerated() {
            let value: Int
            if let digit = character.wholeNumberValue {
                value = digit
            } else if let mapped = transliteration[character] {
                value = mapped
            } else {
                return false
            }
            sum += value * weights[index]
        }
        let remainder = sum % 11
        let expected: Character = remainder == 10 ? "X" : Character(String(remainder))
        return Array(value)[8] == expected
    }

    /// Check digit that makes `digits + result` pass the Luhn test. Used to build
    /// fake card numbers that still look real to the eye and to any validator.
    public static func luhnCheckDigit(for digits: String) -> Int {
        let values = digitsOnly(digits).compactMap { $0.wholeNumberValue }
        var sum = 0
        for (offset, digit) in values.reversed().enumerated() {
            if offset % 2 == 0 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return (10 - sum % 10) % 10
    }

    /// ISO 7064 MOD 11-2 check character for the first 17 digits of a China ID.
    public static func chinaIDCheckCharacter(for seventeenDigits: String) -> Character? {
        let characters = Array(seventeenDigits)
        guard characters.count == 17 else { return nil }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        var sum = 0
        for index in 0..<17 {
            guard let digit = characters[index].wholeNumberValue else { return nil }
            sum += digit * weights[index]
        }
        return Array("10X98765432")[sum % 11]
    }

    /// Guards against masking obviously synthetic numbers such as 000 000 or
    /// 1234 5678, which appear in tutorials and placeholder screenshots.
    public static func looksLikePlaceholder(_ text: String) -> Bool {
        let digits = digitsOnly(text)
        guard digits.count >= 6 else { return false }
        if Set(digits).count <= 1 { return true }
        let ascending = digits.enumerated().allSatisfy { index, character in
            guard index > 0 else { return true }
            let previous = Array(digits)[index - 1].wholeNumberValue ?? 0
            return (character.wholeNumberValue ?? 0) == (previous + 1) % 10
        }
        return ascending
    }
}
