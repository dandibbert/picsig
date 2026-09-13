import Foundation

public struct TextFinding: Sendable {
    public var range: NSRange
    public var kind: SensitiveKind
    public var confidence: Double
}

public enum PrivacyRules {
    private struct Rule {
        let kind: SensitiveKind
        let expression: NSRegularExpression
        let capture: Int
        let confidence: Double
        init(_ kind: SensitiveKind, _ pattern: String, capture: Int = 0, confidence: Double = 0.9) {
            self.kind = kind; self.expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.capture = capture; self.confidence = confidence
        }
    }
    private static let rules: [Rule] = [
        Rule(.email, #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+"#),
        Rule(.phone, #"(?<!\d)(?:\+?86[\s-]?)?1[3-9](?:[\s-]?\d){9}(?!\d)"#),
        Rule(.phone, #"(?<!\w)(?:\+\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)[\s.-]?\d{3,4}[\s.-]?\d{4}|\d{3}[\s.-]\d{3}[\s.-]\d{4}|0\d{2,3}[\s-]\d{7,8})(?!\d)"#, confidence: 0.8),
        Rule(.phone, #"(?:电话|手机|联系电话|tel(?:ephone)?|phone)\s*[:：]?\s*(\+?[\d ()-]{7,22})"#, capture: 1, confidence: 0.85),
        Rule(.identity, #"(?<![A-Z0-9])\d{6}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[0-9X](?![A-Z0-9])"#),
        Rule(.identity, #"(?:身份证|护照|证件号|passport|SSN)\s*[:：#]?\s*([A-Z0-9-]{6,24})"#, capture: 1),
        Rule(.identity, #"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#, confidence: 0.7),
        Rule(.bankCard, #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#, confidence: 0.8),
        Rule(.bankCard, #"(?:卡号|银行卡|card\s*(?:no\.?|number))\s*[:：#]?\s*([\d -]{12,30})"#, capture: 1, confidence: 0.92),
        Rule(.name, #"(?:姓名|收件人|联系人|真实姓名|昵称|寄件人|name|recipient)\s*[:：]\s*([^\s,，;；:：]{2,24}(?: [A-Z][a-z]{1,20})?)"#, capture: 1, confidence: 0.75),
        Rule(.account, #"(?:微信号?|账号|帐号|用户名|用户ID|QQ|账户|account|username|user\s*id)\s*[:：]\s*([A-Z0-9_.@\-\p{Han}]{3,48})"#, capture: 1, confidence: 0.82),
        Rule(.address, #"(?:收货地址|收件地址|寄件地址|详细地址|住址|地址|address)\s*[:：]\s*(.{4,120})"#, capture: 1, confidence: 0.8),
        Rule(.address, #"[\p{Han}]{2,10}(?:省|自治区|市)[\p{Han}0-9A-Z\-]{2,50}(?:路|街|道|巷|弄|小区)[\p{Han}0-9A-Z\-]{0,30}"#, confidence: 0.7),
        Rule(.ipAddress, #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#),
        Rule(.ipAddress, #"(?<![A-F0-9:])(?:[A-F0-9]{0,4}:){2,7}[A-F0-9]{0,4}(?![A-F0-9:])"#, confidence: 0.7),
        Rule(.secret, #"\b(?:sk-[A-Z0-9_-]{12,}|gh[pousr]_[A-Z0-9]{16,}|github_pat_[A-Z0-9_]{16,}|AKIA[A-Z0-9]{16}|eyJ[A-Z0-9_-]{8,}\.[A-Z0-9_-]{8,}\.[A-Z0-9_-]{8,})"#, confidence: 0.98),
        Rule(.secret, #"(?:Bearer\s+)([A-Z0-9._~+/=-]{8,})"#, capture: 1, confidence: 0.98),
        Rule(.secret, #"(?:api[ _-]?key|access[ _-]?token|refresh[ _-]?token|password|passwd|secret|密钥|密码|验证码|校验码|OTP|verification\s*code)\s*[=:：是为]?\s*[\"']?([^\s\"'&,，;；]{4,160})"#, capture: 1, confidence: 0.9),
        Rule(.secret, #"[?&](?:token|key|secret|code|auth|password)=([^&#\s]{4,160})"#, capture: 1, confidence: 0.95)
    ]

    public static func findings(in text: String, options: PrivacyOptions) -> [TextFinding] {
        guard !text.isEmpty else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var output: [TextFinding] = []
        for rule in rules where options.enabledKinds.contains(rule.kind) {
            for match in rule.expression.matches(in: text, range: full) {
                let range = match.range(at: rule.capture)
                guard range.location != NSNotFound, range.length > 0, let stringRange = Range(range, in: text) else { continue }
                let value = String(text[stringRange])
                if rule.kind == .bankCard && rule.capture == 0 && !isLuhnValid(value) { continue }
                if rule.kind == .ipAddress && value.contains(".") && !isIPv4(value) { continue }
                if rule.kind == .ipAddress && value.filter({ $0 == ":" }).count < 2 && !value.contains(".") { continue }
                output.append(TextFinding(range: range, kind: rule.kind, confidence: rule.confidence))
            }
        }
        if options.enabledKinds.contains(.keyword) {
            for keyword in options.keywords.prefix(200) {
                let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty, word.utf16.count <= 256 else { continue }
                let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: word), options: [.caseInsensitive])
                for match in regex?.matches(in: text, range: full) ?? [] { output.append(TextFinding(range: match.range, kind: .keyword, confidence: 1)) }
            }
        }
        // Only collapse identical category/range results; nested findings of other categories remain reviewable.
        var seen = Set<String>()
        return output.filter { seen.insert("\($0.kind.rawValue):\($0.range.location):\($0.range.length)").inserted }
    }

    public static func isLuhnValid(_ value: String) -> Bool {
        let ascii = value.utf8.filter { $0 >= 48 && $0 <= 57 }.map { Int($0 - 48) }
        guard (13...19).contains(ascii.count), Set(ascii).count > 1 else { return false }
        let total = ascii.reversed().enumerated().reduce(0) { sum, pair in
            var digit = pair.element
            if pair.offset % 2 == 1 { digit *= 2; if digit > 9 { digit -= 9 } }
            return sum + digit
        }
        return total % 10 == 0
    }
    private static func isIPv4(_ value: String) -> Bool {
        let segments = value.split(separator: ".")
        return segments.count == 4 && segments.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}
