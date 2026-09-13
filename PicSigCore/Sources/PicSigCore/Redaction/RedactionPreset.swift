import Foundation

/// Ready-made combinations of "what to look for" and "how to hide it" for the
/// screenshots people actually share.
public struct RedactionPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let fallbackTitle: String
    public let fallbackSubtitle: String
    public let symbolName: String
    public let scanSettings: ScanSettings
    public let policy: MaskingPolicy

    public init(id: String,
                fallbackTitle: String,
                fallbackSubtitle: String,
                symbolName: String,
                scanSettings: ScanSettings,
                policy: MaskingPolicy) {
        self.id = id
        self.fallbackTitle = fallbackTitle
        self.fallbackSubtitle = fallbackSubtitle
        self.symbolName = symbolName
        self.scanSettings = scanSettings
        self.policy = policy
    }

    public var titleKey: String { "redaction.preset.\(id).title" }
    public var subtitleKey: String { "redaction.preset.\(id).subtitle" }

    public static let chat = RedactionPreset(
        id: "chat",
        fallbackTitle: "聊天记录",
        fallbackSubtitle: "昵称、头像、手机号、二维码",
        symbolName: "bubble.left.and.bubble.right",
        scanSettings: ScanSettings(enabledCategories: [.phoneNumber, .personName, .idCard, .bankCard,
                                                       .email, .socialAccount, .address, .verificationCode,
                                                       .face, .barcode],
                                   minConfidence: 0.55),
        policy: MaskingPolicy(defaultRule: MaskingRule(style: .mosaic, strength: 0.8),
                              overrides: [
                                  .personName: MaskingRule(style: .mosaic, preserveLeading: 1),
                                  .phoneNumber: MaskingRule(style: .mosaic, preserveLeading: 3, preserveTrailing: 4),
                                  .face: MaskingRule(style: .mosaic, strength: 0.95),
                                  .barcode: MaskingRule(style: .solid, strength: 1)
                              ]))

    public static let order = RedactionPreset(
        id: "order",
        fallbackTitle: "订单 / 快递",
        fallbackSubtitle: "收件人、地址、电话、单号",
        symbolName: "shippingbox",
        scanSettings: ScanSettings(enabledCategories: [.phoneNumber, .personName, .address,
                                                       .trackingNumber, .barcode, .idCard],
                                   minConfidence: 0.5),
        policy: MaskingPolicy(defaultRule: MaskingRule(style: .mosaic, strength: 0.85),
                              overrides: [
                                  .address: MaskingRule(style: .solid, strength: 1),
                                  .trackingNumber: MaskingRule(style: .mosaic, preserveTrailing: 4),
                                  .phoneNumber: MaskingRule(style: .mosaic, preserveLeading: 3, preserveTrailing: 4)
                              ]))

    public static let finance = RedactionPreset(
        id: "finance",
        fallbackTitle: "账单 / 银行",
        fallbackSubtitle: "卡号、余额、姓名、身份证",
        symbolName: "creditcard",
        scanSettings: ScanSettings(enabledCategories: [.bankCard, .amount, .personName, .idCard,
                                                       .phoneNumber, .barcode],
                                   minConfidence: 0.5),
        policy: MaskingPolicy(defaultRule: MaskingRule(style: .solid, strength: 1),
                              overrides: [
                                  .bankCard: MaskingRule(style: .mosaic, preserveTrailing: 4, strength: 0.9),
                                  .amount: MaskingRule(style: .blur, strength: 0.85),
                                  .personName: MaskingRule(style: .mosaic, preserveLeading: 1)
                              ],
                              padding: 0.22))

    public static let identity = RedactionPreset(
        id: "identity",
        fallbackTitle: "证件照片",
        fallbackSubtitle: "证件号、姓名、地址、人脸",
        symbolName: "person.text.rectangle",
        scanSettings: ScanSettings(enabledCategories: [.idCard, .personName, .address, .birthDate,
                                                       .passport, .face, .barcode, .vehicleIdentification],
                                   minConfidence: 0.45),
        policy: .strict)

    public static let readable = RedactionPreset(
        id: "readable",
        fallbackTitle: "脱敏替换",
        fallbackSubtitle: "换成同格式的假信息，截图依旧可读",
        symbolName: "text.badge.checkmark",
        scanSettings: ScanSettings(minConfidence: 0.55),
        policy: .pseudonymised)

    public static let developer = RedactionPreset(
        id: "developer",
        fallbackTitle: "开发调试",
        fallbackSubtitle: "Token、密钥、邮箱、IP、URL",
        symbolName: "chevron.left.forwardslash.chevron.right",
        scanSettings: ScanSettings(enabledCategories: [.credential, .email, .ipAddress, .webAddress,
                                                       .phoneNumber, .barcode],
                                   minConfidence: 0.5),
        policy: MaskingPolicy(defaultRule: MaskingRule(style: .solid, strength: 1),
                              overrides: [.webAddress: MaskingRule(style: .mosaic, strength: 0.8)]))

    public static let all: [RedactionPreset] = [chat, order, finance, identity, readable, developer]
}
