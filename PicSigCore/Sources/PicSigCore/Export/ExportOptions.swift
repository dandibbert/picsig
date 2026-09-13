import Foundation

public enum ImageFileFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case heic

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    public var utType: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        }
    }

    public var supportsQuality: Bool { self != .png }
    public var fallbackTitle: String { rawValue.uppercased() }
}

public enum ExportScale: Equatable, Codable, Sendable {
    case original
    case fraction(Double)
    /// Longest edge in pixels; the main reason this exists is the 4096 px texture
    /// limit that some chat apps still impose on shared images.
    case longestEdge(Int)

    public func targetSize(for size: PixelSize) -> PixelSize {
        switch self {
        case .original:
            return size
        case .fraction(let value):
            return size.scaled(by: max(0.05, min(1, value)))
        case .longestEdge(let edge):
            let longest = max(size.width, size.height)
            guard longest > edge, longest > 0 else { return size }
            return size.scaled(by: Double(edge) / Double(longest))
        }
    }
}

public struct ExportOptions: Equatable, Codable, Sendable {
    public var format: ImageFileFormat
    /// 0...1, ignored for PNG.
    public var quality: Double
    public var scale: ExportScale
    /// Remove EXIF, GPS and maker notes. Redacting the pixels but shipping the
    /// original location in the metadata would be a pointless own goal, so this
    /// defaults to on.
    public var stripsMetadata: Bool
    /// Split a very long image into several pages.
    public var splitsIntoPages: Bool
    public var pageHeight: Int
    /// Rows repeated at the top of the next page so the reader keeps context.
    public var pageOverlap: Int
    public var includesPDF: Bool

    public init(format: ImageFileFormat = .png,
                quality: Double = 0.92,
                scale: ExportScale = .original,
                stripsMetadata: Bool = true,
                splitsIntoPages: Bool = false,
                pageHeight: Int = 4000,
                pageOverlap: Int = 40,
                includesPDF: Bool = false) {
        self.format = format
        self.quality = quality
        self.scale = scale
        self.stripsMetadata = stripsMetadata
        self.splitsIntoPages = splitsIntoPages
        self.pageHeight = pageHeight
        self.pageOverlap = pageOverlap
        self.includesPDF = includesPDF
    }

    public static let `default` = ExportOptions()

    /// Smaller JPEG for chat apps.
    public static let share = ExportOptions(format: .jpeg,
                                            quality: 0.85,
                                            scale: .longestEdge(4096))
}
