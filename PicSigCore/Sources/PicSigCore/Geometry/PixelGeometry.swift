import Foundation

/// Integer pixel size. Core code never touches CoreGraphics so that the
/// algorithms stay portable and testable outside of Apple platforms.
public struct PixelSize: Equatable, Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = PixelSize(width: 0, height: 0)

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var pixelCount: Int { max(0, width) * max(0, height) }
    public var aspectRatio: Double {
        guard height > 0 else { return 0 }
        return Double(width) / Double(height)
    }

    public func scaled(by factor: Double) -> PixelSize {
        PixelSize(width: Int((Double(width) * factor).rounded()),
                  height: Int((Double(height) * factor).rounded()))
    }
}

/// Integer pixel rectangle with a top-left origin (image coordinates).
public struct PixelRect: Equatable, Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: (x: Int, y: Int), size: PixelSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    public var size: PixelSize { PixelSize(width: width, height: height) }
    public var minX: Int { min(x, x + width) }
    public var minY: Int { min(y, y + height) }
    public var maxX: Int { max(x, x + width) }
    public var maxY: Int { max(y, y + height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { max(0, width) * max(0, height) }

    public func inset(by amount: Int) -> PixelRect {
        PixelRect(x: x + amount, y: y + amount,
                  width: width - amount * 2, height: height - amount * 2)
    }

    /// Grows the rectangle in every direction, which is what masking needs so
    /// that anti-aliased glyph edges are fully covered.
    public func expanded(byX dx: Int, byY dy: Int) -> PixelRect {
        PixelRect(x: x - dx, y: y - dy, width: width + dx * 2, height: height + dy * 2)
    }

    public func clamped(to bounds: PixelRect) -> PixelRect {
        let newMinX = max(minX, bounds.minX)
        let newMinY = max(minY, bounds.minY)
        let newMaxX = min(maxX, bounds.maxX)
        let newMaxY = min(maxY, bounds.maxY)
        return PixelRect(x: newMinX, y: newMinY,
                         width: max(0, newMaxX - newMinX),
                         height: max(0, newMaxY - newMinY))
    }

    public func clamped(to size: PixelSize) -> PixelRect {
        clamped(to: PixelRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    public func intersects(_ other: PixelRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let newMinX = min(minX, other.minX)
        let newMinY = min(minY, other.minY)
        let newMaxX = max(maxX, other.maxX)
        let newMaxY = max(maxY, other.maxY)
        return PixelRect(x: newMinX, y: newMinY,
                         width: newMaxX - newMinX, height: newMaxY - newMinY)
    }

    public func intersection(_ other: PixelRect) -> PixelRect {
        clamped(to: other)
    }

    public func offsetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// Mirrors the rectangle across the diagonal, i.e. swaps x/y and w/h.
    /// Horizontal stitching runs the vertical algorithms on transposed images and
    /// transposes the resulting geometry back.
    public var transposed: PixelRect {
        PixelRect(x: y, y: x, width: height, height: width)
    }

    /// Fraction of `self` that is also covered by `other`.
    public func overlapRatio(with other: PixelRect) -> Double {
        guard area > 0 else { return 0 }
        return Double(intersection(other).area) / Double(area)
    }
}

/// Floating point rectangle used by layout planning, where sub-pixel precision
/// matters before the final rasterisation.
public struct FloatRect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = FloatRect(x: 0, y: 0, width: 0, height: 0)

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public var rounded: PixelRect {
        let left = x.rounded()
        let top = y.rounded()
        return PixelRect(x: Int(left), y: Int(top),
                         width: Int((x + width).rounded() - left),
                         height: Int((y + height).rounded() - top))
    }
}

/// Rectangle in the unit coordinate space of an image, top-left origin.
///
/// Vision reports observations in a bottom-left origin space; conversion happens
/// once, at the platform boundary, so that every core rule can assume
/// "y grows downwards" like the rendered image does.
public struct NormalizedRect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = NormalizedRect(x: 0, y: 0, width: 0, height: 0)
    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midY: Double { y + height / 2 }
    public var midX: Double { x + width / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Creates a rect from a Vision style bottom-left origin rect.
    public static func fromBottomLeftOrigin(x: Double, y: Double, width: Double, height: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: 1.0 - y - height, width: width, height: height)
    }

    public func union(_ other: NormalizedRect) -> NormalizedRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let left = min(minX, other.minX)
        let top = min(minY, other.minY)
        let right = max(maxX, other.maxX)
        let bottom = max(maxY, other.maxY)
        return NormalizedRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public func expanded(byX dx: Double, byY dy: Double) -> NormalizedRect {
        NormalizedRect(x: x - dx, y: y - dy, width: width + dx * 2, height: height + dy * 2)
            .clampedToUnitSpace()
    }

    public func clampedToUnitSpace() -> NormalizedRect {
        let left = min(max(0, minX), 1)
        let top = min(max(0, minY), 1)
        let right = min(max(0, maxX), 1)
        let bottom = min(max(0, maxY), 1)
        return NormalizedRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    public func scaled(to size: PixelSize) -> PixelRect {
        let left = (x * Double(size.width)).rounded(.down)
        let top = (y * Double(size.height)).rounded(.down)
        let right = ((x + width) * Double(size.width)).rounded(.up)
        let bottom = ((y + height) * Double(size.height)).rounded(.up)
        return PixelRect(x: Int(left), y: Int(top),
                         width: Int(right - left), height: Int(bottom - top))
            .clamped(to: size)
    }

    public func intersects(_ other: NormalizedRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func intersectionArea(with other: NormalizedRect) -> Double {
        let w = min(maxX, other.maxX) - max(minX, other.minX)
        let h = min(maxY, other.maxY) - max(minY, other.minY)
        guard w > 0, h > 0 else { return 0 }
        return w * h
    }

    public var area: Double { max(0, width) * max(0, height) }

    /// Intersection over union, used to deduplicate detections that the OCR
    /// pass reports twice (typically at stitch seams).
    public func iou(_ other: NormalizedRect) -> Double {
        let intersection = intersectionArea(with: other)
        let unionArea = area + other.area - intersection
        guard unionArea > 0 else { return 0 }
        return intersection / unionArea
    }
}
