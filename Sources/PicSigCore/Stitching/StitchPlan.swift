import Foundation

public enum StitchAxis: String, Codable, CaseIterable, Sendable {
    case vertical
    case horizontal

    public var isVertical: Bool { self == .vertical }
}

/// One blit instruction: copy `sourceRect` of source image `sourceIndex` into
/// `destinationRect` of the canvas.
public struct StitchSegment: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Content area of a screenshot.
        case content
        /// Status bar / navigation bar kept once, taken from the first shot.
        case fixedHeader
        /// Tab bar / home indicator kept once, taken from the last shot.
        case fixedFooter
        /// A whole image placed by a manual layout (grid, row, column).
        case placement
    }

    public let sourceIndex: Int
    public let sourceRect: PixelRect
    public let destinationRect: PixelRect
    public let kind: Kind

    public init(sourceIndex: Int, sourceRect: PixelRect, destinationRect: PixelRect, kind: Kind = .content) {
        self.sourceIndex = sourceIndex
        self.sourceRect = sourceRect
        self.destinationRect = destinationRect
        self.kind = kind
    }

    public var isScaled: Bool { sourceRect.size != destinationRect.size }

    public var transposed: StitchSegment {
        StitchSegment(sourceIndex: sourceIndex,
                      sourceRect: sourceRect.transposed,
                      destinationRect: destinationRect.transposed,
                      kind: kind)
    }
}

/// How two consecutive screenshots were joined. Surfaced in the UI so the user
/// can nudge a seam when the automatic alignment is not trusted.
public struct StitchJoin: Equatable, Sendable {
    public let previousIndex: Int
    public let nextIndex: Int
    /// Rows (or columns) that the two images share.
    public var overlap: Int
    public var confidence: Double
    public var isManual: Bool
    /// Canvas coordinate of the seam, for the seam inspector.
    public var canvasPosition: Int

    public init(previousIndex: Int,
                nextIndex: Int,
                overlap: Int,
                confidence: Double,
                isManual: Bool,
                canvasPosition: Int) {
        self.previousIndex = previousIndex
        self.nextIndex = nextIndex
        self.overlap = overlap
        self.confidence = confidence
        self.isManual = isManual
        self.canvasPosition = canvasPosition
    }

    public var needsReview: Bool { !isManual && confidence < 0.5 }
}

/// Problems worth telling the user about instead of silently producing a wrong
/// long screenshot.
public enum StitchWarning: Equatable, Sendable {
    /// The alignment of a seam could not be trusted.
    case lowConfidenceJoin(nextIndex: Int, confidence: Double)
    /// Content was scrolled past faster than the sample rate could capture;
    /// `missingLength` rows are missing from the result.
    case contentGap(canvasPosition: Int, missingLength: Int)
    /// A recording that scrolled backwards for a while.
    case scrollDirectionReversed(frameIndex: Int)
    /// An input that added nothing to the canvas.
    case duplicateSource(index: Int)
    /// Inputs of differing width; the result is cropped to the narrowest one.
    case mismatchedSourceSize(index: Int)
}

public struct StitchPlan: Equatable, Sendable {
    public var axis: StitchAxis
    public var canvasSize: PixelSize
    public var segments: [StitchSegment]
    public var joins: [StitchJoin]
    public var warnings: [StitchWarning] = []
    /// Indices of source images that were dropped because they added nothing
    /// (duplicate frames, or a screenshot fully contained in its predecessor).
    public var skippedSourceIndices: [Int]
    /// Fixed bands detected at the top / bottom (left / right when horizontal).
    public var fixedHeaderLength: Int
    public var fixedFooterLength: Int

    public init(axis: StitchAxis,
                canvasSize: PixelSize,
                segments: [StitchSegment],
                joins: [StitchJoin] = [],
                warnings: [StitchWarning] = [],
                skippedSourceIndices: [Int] = [],
                fixedHeaderLength: Int = 0,
                fixedFooterLength: Int = 0) {
        self.axis = axis
        self.canvasSize = canvasSize
        self.segments = segments
        self.joins = joins
        self.warnings = warnings
        self.skippedSourceIndices = skippedSourceIndices
        self.fixedHeaderLength = fixedHeaderLength
        self.fixedFooterLength = fixedFooterLength
    }

    public static let empty = StitchPlan(axis: .vertical, canvasSize: .zero, segments: [])

    public var isEmpty: Bool { segments.isEmpty || canvasSize.isEmpty }
    public var usedSourceIndices: [Int] {
        var seen = Set<Int>()
        return segments.compactMap { seen.insert($0.sourceIndex).inserted ? $0.sourceIndex : nil }
    }

    public var lowestConfidence: Double {
        joins.filter { !$0.isManual }.map(\.confidence).min() ?? 1
    }

    public var joinsNeedingReview: [StitchJoin] { joins.filter(\.needsReview) }

    /// Mirrors a plan produced in transposed space back to image space.
    public func transposedPlan() -> StitchPlan {
        StitchPlan(axis: axis.isVertical ? .horizontal : .vertical,
                   canvasSize: PixelSize(width: canvasSize.height, height: canvasSize.width),
                   segments: segments.map(\.transposed),
                   joins: joins,
                   warnings: warnings,
                   skippedSourceIndices: skippedSourceIndices,
                   fixedHeaderLength: fixedHeaderLength,
                   fixedFooterLength: fixedFooterLength)
    }

    /// Rescales a plan that was computed on downscaled inputs so it can be
    /// rendered at full resolution. A factor of 1 leaves the plan untouched, which
    /// is the normal case: alignment runs on full size grayscale buffers.
    public func scaled(byX scaleX: Double, byY scaleY: Double) -> StitchPlan {
        guard scaleX != 1 || scaleY != 1 else { return self }
        func scale(_ rect: PixelRect) -> PixelRect {
            let left = Int((Double(rect.minX) * scaleX).rounded())
            let top = Int((Double(rect.minY) * scaleY).rounded())
            let right = Int((Double(rect.maxX) * scaleX).rounded())
            let bottom = Int((Double(rect.maxY) * scaleY).rounded())
            return PixelRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
        }
        return StitchPlan(axis: axis,
                          canvasSize: PixelSize(width: Int((Double(canvasSize.width) * scaleX).rounded()),
                                                height: Int((Double(canvasSize.height) * scaleY).rounded())),
                          segments: segments.map {
                              StitchSegment(sourceIndex: $0.sourceIndex,
                                            sourceRect: scale($0.sourceRect),
                                            destinationRect: scale($0.destinationRect),
                                            kind: $0.kind)
                          },
                          joins: joins,
                          warnings: warnings,
                          skippedSourceIndices: skippedSourceIndices,
                          fixedHeaderLength: Int((Double(fixedHeaderLength) * scaleY).rounded()),
                          fixedFooterLength: Int((Double(fixedFooterLength) * scaleY).rounded()))
    }

    /// Sanity check used by tests and by the renderer before allocating a canvas.
    public func validate(sourceSizes: [PixelSize]) -> [String] {
        var problems = [String]()
        if canvasSize.isEmpty { problems.append("canvas is empty") }
        for (index, segment) in segments.enumerated() {
            guard sourceSizes.indices.contains(segment.sourceIndex) else {
                problems.append("segment \(index) references unknown source \(segment.sourceIndex)")
                continue
            }
            let sourceBounds = PixelRect(x: 0, y: 0,
                                         width: sourceSizes[segment.sourceIndex].width,
                                         height: sourceSizes[segment.sourceIndex].height)
            if segment.sourceRect.clamped(to: sourceBounds) != segment.sourceRect {
                problems.append("segment \(index) reads outside its source image")
            }
            if segment.destinationRect.clamped(to: canvasSize) != segment.destinationRect {
                problems.append("segment \(index) writes outside the canvas")
            }
            if segment.sourceRect.isEmpty || segment.destinationRect.isEmpty {
                problems.append("segment \(index) is empty")
            }
        }
        return problems
    }
}
