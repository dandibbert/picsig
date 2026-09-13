import Foundation

public struct Size2D: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
    public var area: Double { width * height }
}

/// All persisted editing coordinates use top-left-origin, normalized canvas space.
public struct Box: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let unit = Box(0, 0, 1, 1)
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }
    public var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    public func intersection(_ other: Box) -> Box {
        let left = max(x, other.x), top = max(y, other.y)
        return Box(left, top, max(0, min(maxX, other.maxX) - left), max(0, min(maxY, other.maxY) - top))
    }
    public func scaled(to size: Size2D) -> Box {
        Box(x * size.width, y * size.height, width * size.width, height * size.height)
    }
    public func normalized(to size: Size2D) -> Box {
        Box(x / size.width, y / size.height, width / size.width, height / size.height)
    }
    public func expanded(dx: Double, dy: Double) -> Box { Box(x - dx, y - dy, width + 2 * dx, height + 2 * dy) }
    public func contains(_ point: Point2D) -> Bool { point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY }
}

public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public enum ProjectKind: String, Codable, CaseIterable, Sendable {
    case scroll, video, vertical, horizontal
    public var title: String {
        switch self { case .scroll: return "截图长拼"; case .video: return "录屏长图"; case .vertical: return "竖向拼图"; case .horizontal: return "横向拼图" }
    }
    public var symbol: String {
        switch self { case .scroll: return "rectangle.stack"; case .video: return "record.circle"; case .vertical: return "rectangle.split.1x2"; case .horizontal: return "rectangle.split.2x1" }
    }
    public var isScroll: Bool { self == .scroll || self == .video }
}

public struct SourceImage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var file: String
    public var size: Size2D
    public var crop: Box = .unit
    public var automaticCrop: Box?
    /// Fraction of the cropped leading edge to omit, not of the original image.
    public var leadingCut: Double = 0
    public var matchConfidence: Double?
    public var timestamp: Double?
    public init(id: UUID = UUID(), file: String, size: Size2D) { self.id = id; self.file = file; self.size = size }
}

public enum PaperColor: String, Codable, CaseIterable, Sendable {
    case white, ivory, midnight, lavender
    public var title: String { switch self { case .white: return "纯白"; case .ivory: return "暖纸"; case .midnight: return "深色"; case .lavender: return "浅紫" } }
}

public struct LayoutOptions: Codable, Hashable, Sendable {
    public var breadth: Double = 1440
    public var gap: Double = 0
    public var margin: Double = 0
    public var cornerRadius: Double = 0
    public var paper: PaperColor = .white
    public init() {}
}

public enum SensitiveKind: String, Codable, CaseIterable, Sendable {
    case phone, email, identity, bankCard, address, name, account, secret, ipAddress, face, code, keyword, manual
    public var title: String {
        switch self {
        case .phone: return "电话号码"; case .email: return "邮箱"; case .identity: return "证件号码"
        case .bankCard: return "银行卡"; case .address: return "地址"; case .name: return "姓名 / 昵称"
        case .account: return "账号"; case .secret: return "密钥 / 验证码"; case .ipAddress: return "IP 地址"
        case .face: return "人脸"; case .code: return "二维码 / 条码"; case .keyword: return "自定义关键词"; case .manual: return "手动遮挡"
        }
    }
    public var symbol: String {
        switch self {
        case .phone: return "phone"; case .email: return "envelope"; case .identity: return "person.text.rectangle"
        case .bankCard: return "creditcard"; case .address: return "mappin"; case .name: return "person"
        case .account: return "at"; case .secret: return "key"; case .ipAddress: return "network"
        case .face: return "face.smiling"; case .code: return "qrcode"; case .keyword: return "text.magnifyingglass"; case .manual: return "hand.draw"
        }
    }
}

public struct PrivacyOptions: Codable, Hashable, Sendable {
    public var enabledKinds: Set<SensitiveKind> = Set(SensitiveKind.allCases.filter { $0 != .manual })
    public var wholeLine: Bool = true
    public var padding: Double = 8
    public var keywords: [String] = []
    public var linkRepeated: Bool = true
    public init() {}
    public static func preset(_ name: String) -> PrivacyOptions {
        var options = PrivacyOptions()
        if name == "开发日志" { options.enabledKinds = [.email, .phone, .ipAddress, .secret, .account, .keyword] }
        if name == "订单票据" { options.enabledKinds = [.phone, .email, .identity, .bankCard, .address, .name, .code, .keyword] }
        return options
    }
}

public enum MaskStyle: String, Codable, CaseIterable, Sendable {
    case ink, paper, mosaic
    public var title: String { switch self { case .ink: return "墨色"; case .paper: return "纸白"; case .mosaic: return "隐私像素块" } }
}

public struct PrivacyMask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var rect: Box
    public var kind: SensitiveKind
    public var confidence: Double
    /// An opaque per-scan group identifier. Recognized strings are never persisted.
    public var groupID: String
    public var enabled: Bool = true
    public var reviewed: Bool = false
    public var style: MaskStyle = .ink
    public init(rect: Box, kind: SensitiveKind, confidence: Double = 1, groupID: String = UUID().uuidString) {
        self.rect = rect; self.kind = kind; self.confidence = confidence; self.groupID = groupID
    }
}

public enum MarkKind: String, Codable, Sendable { case pen, arrow, rectangle, text }
public struct Annotation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var kind: MarkKind
    public var points: [Point2D]
    public var text: String = ""
    public var width: Double = 5
    public var color: String = "coral"
    public init(kind: MarkKind, points: [Point2D], text: String = "", width: Double = 5, color: String = "coral") {
        self.kind = kind; self.points = points; self.text = text; self.width = width; self.color = color
    }
}

public struct EditState: Codable, Hashable, Sendable {
    public var masks: [PrivacyMask] = []
    public var annotations: [Annotation] = []
    public var crop: Box = .unit
    public var quarterTurns: Int = 0
    public var scanFinished: Bool = false
    public var scanWarnings: [String] = []
    public init() {}
    public var hasChanges: Bool { !masks.isEmpty || !annotations.isEmpty || crop != .unit || quarterTurns != 0 }
}

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var schemaVersion: Int = 1
    public var id: UUID = UUID()
    public var title: String
    public var kind: ProjectKind
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var images: [SourceImage] = []
    public var layout: LayoutOptions = LayoutOptions()
    public var edit: EditState = EditState()
    public var privacy: PrivacyOptions = PrivacyOptions()
    public init(title: String, kind: ProjectKind) {
        self.title = title; self.kind = kind
        if !kind.isScroll { layout.gap = 20; layout.margin = 32; layout.cornerRadius = 16; layout.paper = .ivory }
    }
}

public enum PicSigError: LocalizedError {
    case invalidImage, invalidGeometry, tooLarge, noImages, unsupportedVideo, storage(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取这张图片。请尝试导出为 PNG 或 JPEG 后重新选择。"
        case .invalidGeometry: return "图片尺寸或裁剪范围无效，请调整后重试。"
        case .tooLarge: return "画布过大。请降低输出宽度、分批处理，或使用分段导出。"
        case .noImages: return "请至少添加一张图片。"
        case .unsupportedVideo: return "未能读取视频画面。请使用正常播放的系统录屏文件。"
        case .storage(let message): return message
        case .cancelled: return "操作已取消，原项目未被更改。"
        }
    }
}
