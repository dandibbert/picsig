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

    /// Converts a point from base space into canvas space — the exact inverse of
    /// `baseSpacePoint(x:y:)`, so the steps run in the opposite order.
    ///
    /// The result is deliberately *not* clamped: a mark that now falls outside the
    /// crop keeps its real position, so the part still inside stays where the user
    /// put it instead of being dragged to the edge.
    public func canvasSpacePoint(x: Double, y: Double) -> (x: Double, y: Double) {
        var px = crop.width > 0 ? (x - crop.x) / crop.width : 0
        var py = crop.height > 0 ? (y - crop.y) / crop.height : 0

        if isMirrored { px = 1 - px }

        switch normalizedQuarterTurns {
        case 1: (px, py) = (1 - py, px)
        case 2: (px, py) = (1 - px, 1 - py)
        case 3: (px, py) = (py, 1 - px)
        default: break
        }

        return (px, py)
    }

    /// Converts a rectangle from base space into canvas space.
    public func canvasSpaceRect(_ rect: NormalizedRect) -> NormalizedRect {
        let corner = canvasSpacePoint(x: rect.minX, y: rect.minY)
        let opposite = canvasSpacePoint(x: rect.maxX, y: rect.maxY)
        return NormalizedRect(x: min(corner.x, opposite.x),
                              y: min(corner.y, opposite.y),
                              width: abs(opposite.x - corner.x),
                              height: abs(opposite.y - corner.y))
    }
}

extension EditState {
    /// Moves everything the user drew from `previous`'s canvas space into this
    /// state's canvas space.
    ///
    /// Annotations and hand-drawn masks are stored in canvas space, so changing the
    /// crop, rotation or mirroring silently re-points them at different pixels —
    /// which for a mask means it stops covering what was hidden. Routing each mark
    /// through base space keeps it on the same content.
    ///
    /// Marks that end up completely outside the new crop are dropped rather than
    /// clamped, because a mask squashed against the edge looks deliberate and hides
    /// the wrong thing. Annotation points are left unclamped so a stroke that is
    /// only partly outside still draws its visible part correctly.
    public func remappingMarks(fromCanvasSpaceOf previous: EditState) -> EditState {
        guard previous.crop != crop
                || previous.normalizedQuarterTurns != normalizedQuarterTurns
                || previous.isMirrored != isMirrored else { return self }

        func remap(_ point: NormalizedPoint) -> NormalizedPoint {
            let base = previous.baseSpacePoint(x: point.x, y: point.y)
            let canvas = canvasSpacePoint(x: base.x, y: base.y)
            return NormalizedPoint(x: canvas.x, y: canvas.y)
        }

        var copy = self
        copy.annotations = annotations.map { annotation in
            var moved = annotation
            moved.points = annotation.points.map(remap)
            return moved
        }
        copy.redactions = redactions.compactMap { item in
            let base = previous.baseSpaceRect(item.box)
            let box = canvasSpaceRect(base).clampedToUnitSpace()
            guard !box.isEmpty else { return nil }
            var moved = item
            moved.box = box
            return moved
        }
        return copy
    }
}
