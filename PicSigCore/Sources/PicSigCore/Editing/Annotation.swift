import Foundation

/// Point in unit image space, top-left origin.
public struct NormalizedPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = NormalizedPoint(x: 0, y: 0)

    public func distance(to other: NormalizedPoint) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

public struct RGBAColor: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let red = RGBAColor(red: 0.94, green: 0.27, blue: 0.24)
    public static let orange = RGBAColor(red: 1, green: 0.62, blue: 0.15)
    public static let yellow = RGBAColor(red: 1, green: 0.86, blue: 0.28)
    public static let green = RGBAColor(red: 0.29, green: 0.75, blue: 0.42)
    public static let blue = RGBAColor(red: 0.19, green: 0.53, blue: 0.96)
    public static let purple = RGBAColor(red: 0.62, green: 0.38, blue: 0.94)
    public static let paper = RGBAColor(red: 0.95, green: 0.95, blue: 0.96)

    public static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    public func withAlpha(_ value: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: value)
    }
}

public enum AnnotationTool: String, Codable, CaseIterable, Sendable {
    case pen
    case highlighter
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case numberBadge

    public var usesTwoPoints: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse: return true
        case .pen, .highlighter, .text, .numberBadge: return false
        }
    }

    public var localizationKey: String { "tool.\(rawValue)" }

    public var fallbackTitle: String {
        switch self {
        case .pen: return "画笔"
        case .highlighter: return "荧光笔"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .text: return "文字"
        case .numberBadge: return "序号"
        }
    }
}

/// One drawn mark. Coordinates are normalised so annotations survive cropping,
/// scaling and exporting at a different resolution.
public struct Annotation: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var tool: AnnotationTool
    public var points: [NormalizedPoint]
    public var color: RGBAColor
    /// Stroke width as a fraction of the image width, so a mark keeps its
    /// relative weight at any export scale.
    public var lineWidth: Double
    public var isFilled: Bool
    public var text: String
    /// Font size as a fraction of the image width.
    public var fontSize: Double
    /// PostScript name of the font for `.text`; `nil` is the system font. Any
    /// font the device knows — including ones installed through a configuration
    /// profile — can be named here; the renderer falls back to the system font
    /// when a document travels to a device that lacks it.
    public var fontName: String?
    public var number: Int?

    public init(id: UUID = UUID(),
                tool: AnnotationTool,
                points: [NormalizedPoint],
                color: RGBAColor = .red,
                lineWidth: Double = 0.006,
                isFilled: Bool = false,
                text: String = "",
                fontSize: Double = 0.035,
                fontName: String? = nil,
                number: Int? = nil) {
        self.id = id
        self.tool = tool
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.isFilled = isFilled
        self.text = text
        self.fontSize = fontSize
        self.fontName = fontName
        self.number = number
    }

    public var boundingBox: NormalizedRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Hit testing for tap-to-select in the editor.
    public func hitTest(_ point: NormalizedPoint, tolerance: Double) -> Bool {
        switch tool {
        case .text, .numberBadge:
            let box = boundingBox.expanded(byX: fontSize, byY: fontSize)
            return box.intersects(NormalizedRect(x: point.x, y: point.y, width: 0.0001, height: 0.0001))
        case .rectangle, .ellipse:
            let box = boundingBox.expanded(byX: tolerance, byY: tolerance)
            return box.intersects(NormalizedRect(x: point.x, y: point.y, width: 0.0001, height: 0.0001))
        case .pen, .highlighter, .arrow, .line:
            return points.contains { $0.distance(to: point) <= max(tolerance, lineWidth) }
        }
    }

    /// Douglas-Peucker style thinning so a freehand stroke does not carry
    /// hundreds of points into the exported document.
    public func simplified(tolerance: Double = 0.001) -> Annotation {
        guard tool == .pen || tool == .highlighter, points.count > 2 else { return self }
        var result = [points[0]]
        for point in points.dropFirst().dropLast() {
            if point.distance(to: result[result.count - 1]) >= tolerance {
                result.append(point)
            }
        }
        result.append(points[points.count - 1])
        var copy = self
        copy.points = result
        return copy
    }
}
