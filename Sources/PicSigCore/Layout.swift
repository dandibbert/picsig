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

/// Keep edits attached to source pixels when a seam, margin, crop or source order changes.
/// Masks crossing a join are split instead of stretched across unrelated content.
public enum EditRemapper {
    public static func remap(_ edit: EditState, from old: Composition, to new: Composition, clockwiseRotations: [UUID: Int] = [:]) -> EditState {
        var result = edit
        let newByID = Dictionary(uniqueKeysWithValues: new.placements.map { ($0.image.id, $0) })
        func sourcePoint(_ p: Point2D, _ placement: Placement) -> Point2D {
            Point2D(placement.source.x + (p.x - placement.destination.x) / placement.destination.width * placement.source.width,
                    placement.source.y + (p.y - placement.destination.y) / placement.destination.height * placement.source.height)
        }
        func map(_ point: Point2D, _ before: Placement, _ after: Placement) -> Point2D {
            var p = sourcePoint(point, before)
            var u = p.x / before.image.size.width, v = p.y / before.image.size.height
            for _ in 0..<((clockwiseRotations[before.image.id] ?? 0) % 4) { (u, v) = (1 - v, u) }
            p = Point2D(u * after.image.size.width, v * after.image.size.height)
            return Point2D(after.destination.x + (p.x - after.source.x) / after.source.width * after.destination.width,
                           after.destination.y + (p.y - after.source.y) / after.source.height * after.destination.height)
        }
        result.masks = edit.masks.flatMap { mask -> [PrivacyMask] in
            let absolute = mask.rect.scaled(to: old.size)
            var fragments: [PrivacyMask] = []
            for before in old.placements {
                let portion = absolute.intersection(before.destination)
                guard portion.isValid, let after = newByID[before.image.id] else { continue }
                let corners = [Point2D(portion.x, portion.y), Point2D(portion.maxX, portion.y), Point2D(portion.x, portion.maxY), Point2D(portion.maxX, portion.maxY)].map { map($0, before, after) }
                let xs = corners.map(\.x), ys = corners.map(\.y)
                let transformed = Box(xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!).intersection(after.destination)
                guard transformed.isValid else { continue }
                var copy = mask; copy.rect = transformed.normalized(to: new.size).intersection(.unit)
                if !fragments.isEmpty { copy.id = UUID() }
                fragments.append(copy)
            }
            // A deliberate mask over a margin/annotation has no source image anchor.
            if fragments.isEmpty && !old.placements.contains(where: { absolute.intersection($0.destination).isValid }) { return [mask] }
            return fragments
        }
        result.annotations = edit.annotations.compactMap { mark in
            guard let origin = mark.points.first else { return nil }
            let anchor = Point2D(origin.x * old.size.width, origin.y * old.size.height)
            guard let before = old.placements.first(where: { $0.destination.contains(anchor) }) else { return mark }
            guard let after = newByID[before.image.id] else { return nil }
            var copy = mark
            copy.points = mark.points.map {
                let p = map(Point2D($0.x * old.size.width, $0.y * old.size.height), before, after)
                return Point2D(p.x / new.size.width, p.y / new.size.height)
            }
            copy.width *= (after.destination.width / after.source.width) / (before.destination.width / before.source.width)
            return copy
        }
        result.scanFinished = false
        return result
    }
}
