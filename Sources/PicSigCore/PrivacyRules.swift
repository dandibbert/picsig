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

/// Geometry-aware address blocks. This is deliberately independent of Vision so that mixed
/// scripts, missing digits, label/value columns and wrapped lines can be regression-tested.
public enum AddressDetector {
    public struct Line: Sendable {
        public var text: String
        public var rect: Box
        public init(_ text: String, _ rect: Box) { self.text = text; self.rect = rect }
    }
    private static let labels = ["地址", "住址", "住所", "所在地", "address", "shipping to", "deliver to"]
    private static let streets = ["路", "街", "巷", "弄", "胡同", "村", "镇", "鎮", "乡", "鄉", "丁目", "町", "小区", "小區", "花园", "花園", "公寓", "大厦", "大廈", "苑", "园", "園", "里", "新城", "广场", "廣場"]
    private static let units = ["号", "號", "栋", "棟", "幢", "单元", "單元", "室", "楼", "樓", "座", "层", "層", "番地", "番", "apt", "suite", "unit", "floor", "building"]
    private static let numbers = "[0-9０-９一二三四五六七八九十百零〇两兩壹贰叁肆伍陆柒捌玖]"
    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func compact(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).lowercased()
    }
    public static func isLabel(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return labels.contains { value.contains($0) }
    }
    public static func isAddress(_ text: String) -> Bool {
        let value = compact(text)
        guard value.count >= 4, value.count <= 260 else { return false }
        if isLabel(text), value.count > 5 { return true }
        let administrative = matches("[\\p{Han}]{2,}(省|市|区|區|县|縣|自治区|自治區|都|道|府|県)[\\p{Han}]{1,}(市|区|區|县|縣|町|村|镇|鎮)", value)
        let hasStreet = streets.contains(where: value.contains)
        let hasUnit = units.contains(where: value.contains)
        let hasNumber = matches(numbers, value)
        if administrative { return true }
        if hasStreet && hasUnit && hasNumber { return true }
        if hasStreet && matches("[\\p{Han}]{2,}(花园|花園|公寓|小区|小區|大厦|大廈|新村|家园|家園)", value) { return true }
        if matches("^[A-Za-z]?" + numbers + "+(号楼|號樓|栋|棟|幢|单元|單元|座).+" + numbers, value) { return true }
        if matches("[都道府県市区町村].*" + numbers + "+[-ー－]" + numbers + "+[-ー－]" + numbers, value) { return true }
        // Latin street suffixes and apartment lines (including abbreviated addresses).
        if matches("\\b[0-9]+[A-Za-z-]*\\s+.+\\b(street|st|road|rd|avenue|ave|boulevard|blvd|lane|ln|drive|dr|court|ct|place|pl|way|highway|hwy|terrace|ter|crescent|close)\\b", text) { return true }
        return false
    }
    private static func otherField(_ text: String) -> Bool {
        matches("^(电话|電話|手机|手機|姓名|收件人|联系人|聯繫人|订单|訂單|支付|金额|金額|备注|備註|商品|合计|合計|总计|總計|email|phone|name|order|total|payment|note)\\s*[:：]", text.trimmingCharacters(in: .whitespaces))
    }
    private static func continuation(_ text: String) -> Bool {
        let value = compact(text)
        return isAddress(text) || streets.contains(where: value.contains) || units.contains(where: value.contains)
            || matches("^[A-Za-z]?" + numbers + "+([-—－/栋棟幢室号號楼樓座层層单元單元]" + numbers + "+)*[室号號楼樓]?$", value)
            || matches("^[A-Za-z .]+,?\\s+[A-Z]{2}\\s+[0-9]{5}(-[0-9]{4})?$", text)
            || matches("^〒?\\s*[0-9]{3}-[0-9]{4}", text)
    }
    public static func protectedLines(_ lines: [Line]) -> Set<Int> {
        let ordered = lines.indices.sorted {
            let a = lines[$0].rect, b = lines[$1].rect
            return abs(a.y - b.y) < min(a.height, b.height) * 0.45 ? a.x < b.x : a.y < b.y
        }
        var result = Set<Int>()
        for seed in ordered {
            let first = lines[seed]
            guard isAddress(first.text) || isLabel(first.text) else { continue }
            result.insert(seed)
            var frontier = first.rect
            var previousText = first.text
            var followed = 0
            for index in ordered where index != seed {
                let next = lines[index], r = next.rect
                let lineHeight = max(frontier.height, r.height)
                let sameRow = abs(r.y - frontier.y) < lineHeight * 0.55
                let beside = sameRow && r.x >= frontier.maxX - 2 && r.x - frontier.maxX <= max(240, lineHeight * 8)
                let below = r.y >= frontier.maxY - lineHeight * 0.2 && r.y - frontier.maxY <= max(64, lineHeight * 2.8)
                    && abs(r.x - frontier.x) <= max(64, lineHeight * 3)
                guard beside || below else { continue }
                guard followed < 5, !otherField(next.text), next.text.count >= 2, next.text.count <= 200 else { continue }
                // A label can have a value in a separate column/line. Subsequent continuations
                // need address evidence, preventing a block from swallowing the next form field.
                let isValue = isLabel(previousText) && followed == 0
                guard isValue || continuation(next.text) || (continuation(previousText) && isAddress(previousText + next.text)) else { continue }
                result.insert(index); followed += 1
                frontier = r; previousText = next.text
            }
        }
        return result
    }
}
