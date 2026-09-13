import Foundation

/// Produces fake-but-plausible stand-ins for sensitive values.
///
/// Two properties make this useful rather than a gimmick:
/// * **Stable** — the same value always maps to the same replacement, so a chat
///   log stays coherent after masking instead of turning into a wall of blocks.
/// * **Well formed** — generated ID cards and bank cards carry correct check
///   digits, so the screenshot still looks like a real screenshot.
public struct PseudonymGenerator: Sendable {
    /// Changing the salt reshuffles every replacement.
    public let salt: String

    public init(salt: String = "picsig") {
        self.salt = salt
    }

    public func replacement(for match: SensitiveMatch) -> String {
        replacement(for: match.value, category: match.category)
    }

    public func replacement(for value: String, category: SensitiveCategory) -> String {
        var random = SplitMix64(seed: Self.hash(salt + "|" + category.rawValue + "|" + value))
        switch category {
        case .phoneNumber:
            return fakePhone(&random, like: value)
        case .idCard:
            return fakeIDCard(&random)
        case .bankCard:
            return fakeBankCard(&random, like: value)
        case .email:
            return "user\(random.next(digits: 4))@example.com"
        case .personName:
            return fakeName(&random)
        case .address:
            return fakeAddress(&random)
        case .plateNumber:
            return fakePlate(&random)
        case .socialAccount:
            return "user_\(random.next(digits: 6))"
        case .trackingNumber:
            return "SF\(random.next(digits: 12))"
        case .verificationCode:
            return String(repeating: "*", count: max(4, value.count))
        case .amount:
            return maskDigitsKeepingShape(value)
        case .birthDate:
            return maskDigitsKeepingShape(value)
        case .ipAddress:
            return "10.0.\(random.next(upperBound: 255)).\(random.next(upperBound: 255))"
        case .webAddress:
            return "https://example.com/…"
        case .credential:
            return String(repeating: "•", count: min(24, max(8, value.count)))
        case .passport:
            return "E\(random.next(digits: 8))"
        case .vehicleIdentification:
            return fakeVIN(&random)
        case .face, .barcode, .custom:
            return String(repeating: "•", count: max(3, value.count))
        }
    }

    // MARK: - Builders

    private func fakePhone(_ random: inout SplitMix64, like value: String) -> String {
        let prefixes = ["130", "133", "138", "139", "150", "158", "170", "186", "188", "199"]
        let prefix = prefixes[Int(random.next(upperBound: UInt64(prefixes.count)))]
        let body = random.next(digits: 8)
        let plain = prefix + body
        // Preserve the separator style of the original.
        if value.contains(" ") {
            return "\(plain.prefix(3)) \(plain.dropFirst(3).prefix(4)) \(plain.suffix(4))"
        }
        if value.contains("-") {
            return "\(plain.prefix(3))-\(plain.dropFirst(3).prefix(4))-\(plain.suffix(4))"
        }
        return plain
    }

    private func fakeIDCard(_ random: inout SplitMix64) -> String {
        let regions = ["110101", "310104", "440305", "510107", "320106", "330106"]
        let region = regions[Int(random.next(upperBound: UInt64(regions.count)))]
        let year = 1960 + Int(random.next(upperBound: 45))
        let month = 1 + Int(random.next(upperBound: 12))
        let day = 1 + Int(random.next(upperBound: 28))
        let sequence = String(format: "%03d", Int(random.next(upperBound: 1000)))
        let body = region + String(format: "%04d%02d%02d", year, month, day) + sequence
        guard let check = SensitiveValidators.chinaIDCheckCharacter(for: body) else { return body + "X" }
        return body + String(check)
    }

    private func fakeBankCard(_ random: inout SplitMix64, like value: String) -> String {
        let length = min(19, max(16, SensitiveValidators.digitsOnly(value).count))
        var digits = "62" + random.next(digits: length - 3)
        digits += String(SensitiveValidators.luhnCheckDigit(for: digits))
        if value.contains(" ") {
            return stride(from: 0, to: digits.count, by: 4).map { start in
                String(digits.dropFirst(start).prefix(4))
            }.joined(separator: " ")
        }
        return digits
    }

    private func fakeName(_ random: inout SplitMix64) -> String {
        let surnames = ["张", "李", "王", "刘", "陈", "杨", "黄", "周", "吴", "徐"]
        let given = ["伟", "芳", "娜", "敏", "静", "强", "磊", "洋", "艳", "勇", "军", "杰"]
        let surname = surnames[Int(random.next(upperBound: UInt64(surnames.count)))]
        let first = given[Int(random.next(upperBound: UInt64(given.count)))]
        let second = random.next(upperBound: 2) == 0 ? "" : given[Int(random.next(upperBound: UInt64(given.count)))]
        return surname + first + second
    }

    private func fakeAddress(_ random: inout SplitMix64) -> String {
        let cities = ["北京市朝阳区", "上海市徐汇区", "广州市天河区", "深圳市南山区", "杭州市西湖区"]
        let roads = ["建设路", "人民大道", "科技街", "文化路", "长江大道"]
        let city = cities[Int(random.next(upperBound: UInt64(cities.count)))]
        let road = roads[Int(random.next(upperBound: UInt64(roads.count)))]
        return "\(city)\(road)\(1 + random.next(upperBound: 200))号\(1 + random.next(upperBound: 30))栋\(100 + random.next(upperBound: 900))室"
    }

    private func fakePlate(_ random: inout SplitMix64) -> String {
        let provinces = ["京", "沪", "粤", "浙", "苏", "川"]
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let province = provinces[Int(random.next(upperBound: UInt64(provinces.count)))]
        let city = letters[Int(random.next(upperBound: UInt64(letters.count)))]
        var tail = ""
        for _ in 0..<5 {
            tail += random.next(upperBound: 2) == 0
                ? String(random.next(digits: 1))
                : String(letters[Int(random.next(upperBound: UInt64(letters.count)))])
        }
        return "\(province)\(city)\(tail)"
    }

    private func fakeVIN(_ random: inout SplitMix64) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
        var value = ""
        for _ in 0..<17 {
            value.append(alphabet[Int(random.next(upperBound: UInt64(alphabet.count)))])
        }
        return value
    }

    /// Keeps punctuation and length, replaces every digit with `*`.
    private func maskDigitsKeepingShape(_ value: String) -> String {
        String(value.map { $0.isNumber ? "*" : $0 })
    }

    // MARK: - Deterministic randomness

    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01b3
        }
        return value
    }

    struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func next(upperBound: UInt64) -> UInt64 {
            guard upperBound > 0 else { return 0 }
            return next() % upperBound
        }

        mutating func next(digits count: Int) -> String {
            guard count > 0 else { return "" }
            return (0..<count).map { _ in String(next(upperBound: 10)) }.joined()
        }
    }
}
