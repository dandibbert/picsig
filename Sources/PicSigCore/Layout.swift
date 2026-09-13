import Foundation

public struct Placement: Sendable {
    public var image: SourceImage
    public var source: Box
    public var destination: Box
}

public struct Composition: Sendable {
    public var size: Size2D
    public var placements: [Placement]
    public static func build(_ project: Project) throws -> Composition {
        guard !project.images.isEmpty else { throw PicSigError.noImages }
        let options = project.layout
        guard [options.breadth, options.gap, options.margin, options.cornerRadius].allSatisfy(\.isFinite),
              options.breadth >= 128, options.breadth <= 4096,
              options.gap >= 0, options.gap <= 240, options.margin >= 0, options.margin <= 240,
              options.cornerRadius >= 0, options.cornerRadius <= 120 else { throw PicSigError.invalidGeometry }
        let horizontal = project.kind == .horizontal
        let cross = options.breadth
        var cursor = options.margin
        var placements: [Placement] = []
        for (index, image) in project.images.enumerated() {
            guard image.size.width.isFinite, image.size.height.isFinite, image.size.area > 0,
                  image.size.width > 0, image.size.height > 0,
                  image.crop.isValid, image.leadingCut.isFinite else { throw PicSigError.invalidGeometry }
            let clamped = (image.automaticCrop ?? image.crop).intersection(.unit)
            guard clamped.width >= 0.01, clamped.height >= 0.01 else { throw PicSigError.invalidGeometry }
            var source = clamped.scaled(to: image.size)
            let cut = index == 0 ? 0 : min(0.98, max(0, image.leadingCut))
            if horizontal { let offset = source.width * cut; source.x += offset; source.width -= offset }
            else { let offset = source.height * cut; source.y += offset; source.height -= offset }
            let scale = cross / (horizontal ? source.height : source.width)
            let along = (horizontal ? source.width : source.height) * scale
            let destination = horizontal ? Box(cursor, options.margin, along, cross) : Box(options.margin, cursor, cross, along)
            placements.append(Placement(image: image, source: source, destination: destination))
            cursor += along + (index == project.images.count - 1 ? 0 : options.gap)
        }
        let size = horizontal ? Size2D(ceil(cursor + options.margin), ceil(cross + 2 * options.margin)) : Size2D(ceil(cross + 2 * options.margin), ceil(cursor + options.margin))
        guard size.width.isFinite, size.height.isFinite, size.area <= 180_000_000, max(size.width, size.height) <= 180_000 else { throw PicSigError.tooLarge }
        return Composition(size: size, placements: placements)
    }
}

public struct ExportGeometry: Sendable {
    public var crop: Box
    public var turns: Int
    public var size: Size2D
    public init(canvas: Size2D, crop: Box = .unit, turns: Int = 0) throws {
        guard crop.isValid else { throw PicSigError.invalidGeometry }
        let rect = crop.intersection(.unit).scaled(to: canvas)
        guard rect.width >= 1, rect.height >= 1 else { throw PicSigError.invalidGeometry }
        self.crop = Box(floor(rect.x), floor(rect.y), floor(rect.width), floor(rect.height))
        self.turns = ((turns % 4) + 4) % 4
        self.size = self.turns % 2 == 0 ? Size2D(self.crop.width, self.crop.height) : Size2D(self.crop.height, self.crop.width)
    }
    /// Inverse transform, useful to decode only the sources intersecting a rendered tile.
    public func sourceRegion(for output: Box) -> Box {
        switch turns {
        case 1: return Box(crop.x + output.y, crop.y + crop.height - output.maxX, output.height, output.width)
        case 2: return Box(crop.x + crop.width - output.maxX, crop.y + crop.height - output.maxY, output.width, output.height)
        case 3: return Box(crop.x + crop.width - output.maxY, crop.y + output.x, output.height, output.width)
        default: return Box(crop.x + output.x, crop.y + output.y, output.width, output.height)
        }
    }
    public func slices(maxPixels: Double = 8_000_000, preferredLength: Double = 4096) -> [Box] {
        let vertical = size.height >= size.width
        let cross = vertical ? size.width : size.height
        let total = vertical ? size.height : size.width
        let length = max(1, floor(min(preferredLength, maxPixels / max(1, cross))))
        var result: [Box] = []
        var position = 0.0
        while position < total {
            let current = min(length, total - position)
            result.append(vertical ? Box(0, position, size.width, current) : Box(position, 0, current, size.height))
            position += current
        }
        return result
    }
}
