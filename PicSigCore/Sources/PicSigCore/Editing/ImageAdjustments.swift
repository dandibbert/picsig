import Foundation

/// Basic tone controls. Values are neutral at their defaults, which lets the
/// renderer skip the whole filter chain when nothing was touched.
public struct ImageAdjustments: Equatable, Codable, Sendable {
    /// -1...1
    public var brightness: Double
    /// 0...2, 1 is neutral
    public var contrast: Double
    /// 0...2, 1 is neutral
    public var saturation: Double
    /// -1...1, warm to cool
    public var temperature: Double
    /// 0...1
    public var sharpness: Double
    /// 0...1
    public var vignette: Double

    public init(brightness: Double = 0,
                contrast: Double = 1,
                saturation: Double = 1,
                temperature: Double = 0,
                sharpness: Double = 0,
                vignette: Double = 0) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.sharpness = sharpness
        self.vignette = vignette
    }

    public static let neutral = ImageAdjustments()

    public var isNeutral: Bool { self == .neutral }

    public mutating func reset() { self = .neutral }
}

/// Frame, background and rounded corners applied to the finished canvas.
public struct CanvasStyle: Equatable, Codable, Sendable {
    public var backgroundColor: RGBAColor
    /// Outer margin, as a fraction of the canvas width.
    public var margin: Double
    /// Corner radius of each stitched image, as a fraction of its width.
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: RGBAColor
    public var shadowRadius: Double
    public var shadowOpacity: Double

    public init(backgroundColor: RGBAColor = .white,
                margin: Double = 0,
                cornerRadius: Double = 0,
                borderWidth: Double = 0,
                borderColor: RGBAColor = RGBAColor(red: 0.8, green: 0.8, blue: 0.82),
                shadowRadius: Double = 0,
                shadowOpacity: Double = 0) {
        self.backgroundColor = backgroundColor
        self.margin = margin
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
    }

    public static let plain = CanvasStyle()

    public static let card = CanvasStyle(backgroundColor: .paper,
                                         margin: 0.03,
                                         cornerRadius: 0.02,
                                         shadowRadius: 0.012,
                                         shadowOpacity: 0.18)

    public var isPlain: Bool { self == .plain }
}

public enum WatermarkPosition: String, Codable, CaseIterable, Sendable {
    case bottomTrailing
    case bottomLeading
    case topTrailing
    case topLeading
    case center
    /// Repeated diagonally across the whole image.
    case tiled

    public var localizationKey: String { "watermark.position.\(rawValue)" }
}

public struct Watermark: Equatable, Codable, Sendable {
    public var text: String
    public var position: WatermarkPosition
    public var color: RGBAColor
    public var opacity: Double
    /// Font size as a fraction of the image width.
    public var fontSize: Double

    public init(text: String,
                position: WatermarkPosition = .bottomTrailing,
                color: RGBAColor = .white,
                opacity: Double = 0.5,
                fontSize: Double = 0.03) {
        self.text = text
        self.position = position
        self.color = color
        self.opacity = opacity
        self.fontSize = fontSize
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
