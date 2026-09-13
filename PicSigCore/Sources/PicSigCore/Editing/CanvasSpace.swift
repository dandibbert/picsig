import Foundation

/// Mapping between the two coordinate spaces the editor deals with.
///
/// * **Base space** — the untouched stitched image. The crop rectangle is stored
///   in it, and it is what the renderer starts from.
/// * **Canvas space** — what the user actually sees and draws on: cropped,
///   rotated and mirrored, but not yet masked or annotated.
///
/// Masks, annotations and recognised text all live in canvas space, because the
/// renderer applies them after the geometry steps. Only the crop has to travel
/// the other way, and getting that conversion wrong is invisible until someone
/// crops a second time and the image jumps.
extension EditState {
    /// Rotation reduced to 0...3 clockwise quarter turns.
    public var normalizedQuarterTurns: Int { ((quarterTurns % 4) + 4) % 4 }

    /// Pixel size of the canvas space image for a given base image size.
    public func canvasSize(for size: PixelSize) -> PixelSize {
        guard !size.isEmpty else { return .zero }
        let cropped = PixelSize(width: max(1, Int((Double(size.width) * crop.width).rounded())),
                                height: max(1, Int((Double(size.height) * crop.height).rounded())))
        return normalizedQuarterTurns % 2 == 0
            ? cropped
            : PixelSize(width: cropped.height, height: cropped.width)
    }

    /// Converts a point from canvas space to base space.
    public func baseSpacePoint(x: Double, y: Double) -> (x: Double, y: Double) {
        var px = x
        var py = y

        // Undoing a clockwise turn means turning counter-clockwise.
        switch normalizedQuarterTurns {
        case 1: (px, py) = (y, 1 - x)
        case 2: (px, py) = (1 - x, 1 - y)
        case 3: (px, py) = (1 - y, x)
        default: break
        }

        // The renderer mirrors the source before rotating it, so unmirroring is
        // the last step on the way back.
        if isMirrored { px = 1 - px }

        return (crop.x + px * crop.width, crop.y + py * crop.height)
    }

    /// Converts a rectangle from canvas space to base space. Rotation can swap
    /// which corner is which, so both are mapped and re-ordered.
    public func baseSpaceRect(_ rect: NormalizedRect) -> NormalizedRect {
        let corner = baseSpacePoint(x: rect.minX, y: rect.minY)
        let opposite = baseSpacePoint(x: rect.maxX, y: rect.maxY)
        return NormalizedRect(x: min(corner.x, opposite.x),
                              y: min(corner.y, opposite.y),
                              width: abs(opposite.x - corner.x),
                              height: abs(opposite.y - corner.y))
            .clampedToUnitSpace()
    }
}
