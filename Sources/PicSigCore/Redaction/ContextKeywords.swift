import Foundation

/// Label words that appear next to private values on Chinese and English
/// screens. Context matching is what lets the scanner catch things a pure
/// pattern cannot ("余额 1,280.00", "验证码 4821", "户名 张伟").
public enum ContextKeywords {
    public static let phoneNumber = ["手机", "手机号", "电话", "联系电话", "联系方式", "号码", "尾号",
                                     "mobile", "phone", "tel", "cell"]
    public static let idCard = ["身份证", "证件号", "身份号码", "居民身份证", "实名", "id card", "id no"]
    public static let bankCard = ["银行卡", "卡号", "储蓄卡", "信用卡", "账号", "账户", "银行账号",
                                  "开户", "card no", "account"]
    public static let personName = ["姓名", "名字", "收件人", "收货人", "寄件人", "持卡人", "户名",
                                    "联系人", "真实姓名", "本人", "患者", "学生", "乘客", "旅客",
                                    "name", "holder", "recipient"]
    public static let address = ["地址", "收货地址", "住址", "详细地址", "所在地", "位置", "居住",
                                 "address", "location"]
    public static let verificationCode = ["验证码", "校验码", "动态码", "动态密码", "短信码", "一次性密码",
                                          "code", "otp", "verification"]
    public static let amount = ["余额", "金额", "资产", "总额", "合计", "收入", "工资", "薪资", "年薪",
                                "存款", "可用额度", "账单", "消费", "转账", "红包", "累计",
                                "balance", "amount", "total"]
    public static let socialAccount = ["微信", "微信号", "wechat", "qq", "q q", "抖音", "小红书",
                                       "微博", "账号", "id", "telegram", "line"]
    public static let trackingNumber = ["快递", "运单", "物流", "单号", "运单号", "快递单号", "订单号",
                                        "tracking", "waybill"]
    public static let passport = ["护照", "通行证", "签证", "港澳", "台湾居民", "passport"]
    public static let vehicleIdentification = ["车架号", "车辆识别", "vin"]
    public static let plateNumber = ["车牌", "号牌", "车辆", "plate"]
    public static let birthDate = ["出生", "生日", "出生日期", "birth", "dob"]
    public static let credential = ["密钥", "密码", "口令", "令牌", "token", "secret", "api key",
                                    "apikey", "access key", "password", "私钥"]
    public static let membership = ["会员号", "工号", "学号", "编号", "社保", "公积金", "医保", "病历号"]

    public static func keywords(for category: SensitiveCategory) -> [String] {
        switch category {
        case .phoneNumber: return phoneNumber
        case .idCard: return idCard
        case .bankCard: return bankCard
        case .personName: return personName
        case .address: return address
        case .verificationCode: return verificationCode
        case .amount: return amount
        case .socialAccount: return socialAccount
        case .trackingNumber: return trackingNumber
        case .passport: return passport
        case .vehicleIdentification: return vehicleIdentification
        case .plateNumber: return plateNumber
        case .birthDate: return birthDate
        case .credential: return credential
        default: return []
        }
    }
}

/// Looks for a rule's keywords in the value's own line and in its visual
/// neighbourhood: the text to the left on the same row, and the line above.
/// Those two layouts cover nearly every form, list row and profile card.
public struct ContextAnalyzer {
    public struct Result: Equatable, Sendable {
        public let matchedKeyword: String?
        public let isSameLine: Bool

        public var hasContext: Bool { matchedKeyword != nil }
        public static let none = Result(matchedKeyword: nil, isSameLine: false)

        public init(matchedKeyword: String?, isSameLine: Bool) {
            self.matchedKeyword = matchedKeyword
            self.isSameLine = isSameLine
        }
    }

    public let layout: TextLayout

    public init(layout: TextLayout) {
        self.layout = layout
    }

    public func analyze(keywords rawKeywords: [String],
                        line: RecognizedTextLine,
                        valueRange: Range<Int>) -> Result {
        guard !rawKeywords.isEmpty else { return .none }
        // Longest first, so the reported label is the most specific one
        // ("联系电话" rather than "电话").
        let keywords = rawKeywords.sorted { $0.count > $1.count }

        // 1. Same line, preferring a keyword that sits before the value.
        let characters = line.characters
        let prefix = String(characters[0..<min(valueRange.lowerBound, characters.count)]).lowercased()
        if let keyword = keywords.first(where: { prefix.contains($0.lowercased()) }) {
            return Result(matchedKeyword: keyword, isSameLine: true)
        }
        let whole = line.text.lowercased()
        if let keyword = keywords.first(where: { whole.contains($0.lowercased()) }) {
            return Result(matchedKeyword: keyword, isSameLine: true)
        }

        // 2. Label to the left on the same row.
        if let left = layout.line(leftOf: line) {
            let text = left.text.lowercased()
            if let keyword = keywords.first(where: { text.contains($0.lowercased()) }) {
                return Result(matchedKeyword: keyword, isSameLine: false)
            }
        }

        // 3. Label directly above.
        if let above = layout.line(above: line) {
            let text = above.text.lowercased()
            if let keyword = keywords.first(where: { text.contains($0.lowercased()) }) {
                return Result(matchedKeyword: keyword, isSameLine: false)
            }
        }

        return .none
    }
}
