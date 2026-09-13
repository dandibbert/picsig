import Foundation

/// Kinds of private information the scanner knows about.
public enum SensitiveCategory: String, Codable, CaseIterable, Sendable {
    case phoneNumber
    case idCard
    case bankCard
    case email
    case address
    case personName
    case plateNumber
    case socialAccount
    case trackingNumber
    case verificationCode
    case amount
    case birthDate
    case ipAddress
    case webAddress
    case credential
    case passport
    case vehicleIdentification
    case face
    case barcode
    case custom

    public enum Severity: Int, Codable, Comparable, Sendable {
        case low = 0
        case medium = 1
        case high = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Drives ordering in the review list and which category wins when two rules
    /// match the same characters.
    public var severity: Severity {
        switch self {
        case .idCard, .bankCard, .credential, .passport, .verificationCode:
            return .high
        case .phoneNumber, .address, .email, .personName, .plateNumber,
             .socialAccount, .amount, .vehicleIdentification, .face, .barcode:
            return .medium
        case .trackingNumber, .birthDate, .ipAddress, .webAddress, .custom:
            return .low
        }
    }

    /// Categories that are masked without asking. Names, amounts, dates and web
    /// addresses are noisy enough that they are opt-in.
    public var isEnabledByDefault: Bool {
        switch self {
        case .birthDate, .webAddress, .ipAddress, .amount, .custom:
            return false
        default:
            return true
        }
    }

    /// Localisation key; the app bundle provides zh-Hans and en strings.
    public var localizationKey: String { "redaction.category.\(rawValue)" }

    /// Used by audit reports and by tests, so a category always has a readable
    /// name even outside the app bundle.
    public var fallbackTitle: String {
        switch self {
        case .phoneNumber: return "手机号"
        case .idCard: return "身份证号"
        case .bankCard: return "银行卡号"
        case .email: return "邮箱"
        case .address: return "详细地址"
        case .personName: return "姓名"
        case .plateNumber: return "车牌号"
        case .socialAccount: return "社交账号"
        case .trackingNumber: return "快递单号"
        case .verificationCode: return "验证码"
        case .amount: return "金额"
        case .birthDate: return "出生日期"
        case .ipAddress: return "IP 地址"
        case .webAddress: return "网址"
        case .credential: return "密钥/令牌"
        case .passport: return "证件号"
        case .vehicleIdentification: return "车架号"
        case .face: return "人脸/头像"
        case .barcode: return "二维码/条码"
        case .custom: return "自定义规则"
        }
    }

    /// Categories detected from pixels instead of from text.
    public var isVisual: Bool { self == .face || self == .barcode }
}
