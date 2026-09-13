import Foundation

/// Where a sampled video frame sits on the long canvas.
public struct FrameOffset: Equatable, Sendable {
    public let frameIndex: Int
    /// Position of the frame's content area on the (not yet compacted) canvas.
    public var position: Int
    public var confidence: Double
    /// True when the frame moved against the dominant scroll direction.
    public var isReversed: Bool

    public init(frameIndex: Int, position: Int, confidence: Double, isReversed: Bool = false) {
        self.frameIndex = frameIndex
        self.position = position
        self.confidence = confidence
        self.isReversed = isReversed
    }
}

/// Builds a long screenshot from a screen recording.
///
/// Unlike a screenshot sequence, a recording contains many frames that are
/// identical (nothing scrolled), frames that jumped further than one screen
/// (fast fling) and frames that moved backwards (rubber-band bounce at the end
/// of a list, or the user scrolling up again). The planner therefore does not
/// simply append frames: it first estimates an absolute position per frame and
/// then greedily covers the canvas with whichever frame supplies the next
/// missing rows.
public enum VideoScrollPlanner {
    public struct Options: Sendable {
        public var axis: StitchAxis
        public var detector: OverlapDetector.Options
        public var fixedRegions: FixedRegionDetector.Options
        public var trimFixedRegions: Bool
        public var keepHeader: Bool
        public var keepFooter: Bool
        /// Matches below this confidence are not trusted for positioning.
        public var minConfidence: Double
        /// Movement smaller than this counts as "nothing scrolled".
        public var minAdvance: Int
        /// Try to match in the opposite direction as well, which is what makes
        /// bounce-back and scroll-up recordings work.
        public var allowReverseDirection: Bool

        public init(axis: StitchAxis = .vertical,
                    detector: OverlapDetector.Options = .video,
                    fixedRegions: FixedRegionDetector.Options = .default,
                    trimFixedRegions: Bool = true,
                    keepHeader: Bool = true,
                    keepFooter: Bool = true,
                    minConfidence: Double = 0.25,
                    minAdvance: Int = 2,
                    allowReverseDirection: Bool = true) {
            self.axis = axis
            self.detector = detector
            self.fixedRegions = fixedRegions
            self.trimFixedRegions = trimFixedRegions
            self.keepHeader = keepHeader
            self.keepFooter = keepFooter
            self.minConfidence = minConfidence
            self.minAdvance = minAdvance
            self.allowReverseDirection = allowReverseDirection
        }

        public static let `default` = Options()
    }

    public static func plan(frames: [GrayImage], options: Options = .default) -> StitchPlan {
        let factor = max(1, options.detector.coarseFactor)
        return plan(pyramids: frames.map { GrayPyramid(image: $0, factor: factor) }, options: options)
    }

    public static func plan(pyramids: [GrayPyramid], options: Options = .default) -> StitchPlan {
        guard !pyramids.isEmpty else { return .empty }
        if options.axis == .horizontal {
            var verticalOptions = options
            verticalOptions.axis = .vertical
            return planVertical(pyramids: pyramids.map { $0.transposed() }, options: verticalOptions)
                .transposedPlan()
        }
        return planVertical(pyramids: pyramids, options: options)
    }

    /// Exposed separately so the UI can visualise the scroll track (and so it
    /// can be unit tested without building a plan).
    public static func estimateOffsets(pyramids: [GrayPyramid],
                                       contentRange: (Int) -> Range<Int>,
                                       options: Options) -> [FrameOffset] {
        guard !pyramids.isEmpty else { return [] }
        var offsets = [FrameOffset(frameIndex: 0, position: 0, confidence: 1)]
        var position = 0

        for index in 1..<pyramids.count {
            let previousContent = contentRange(index - 1)
            let nextContent = contentRange(index)
            guard !previousContent.isEmpty, !nextContent.isEmpty else {
                offsets.append(FrameOffset(frameIndex: index, position: position, confidence: 0))
                continue
            }

            let forward = OverlapDetector.detect(previous: pyramids[index - 1],
                                                 next: pyramids[index],
                                                 previousContent: previousContent,
                                                 nextContent: nextContent,
                                                 options: options.detector)
            var delta = forward.map { previousContent.count - $0.overlap } ?? previousContent.count
            var confidence = forward?.confidence ?? 0
            var reversed = false

            if options.allowReverseDirection, confidence < 0.85 {
                // Swapping the roles measures how far the *previous* frame is
                // ahead of this one, i.e. a negative advance.
                if let backward = OverlapDetector.detect(previous: pyramids[index],
                                                         next: pyramids[index - 1],
                                                         previousContent: nextContent,
                                                         nextContent: previousContent,
                                                         options: options.detector),
                   backward.confidence > confidence + 0.05 {
                    let backwardDelta = nextContent.count - backward.overlap
                    if backwardDelta >= options.minAdvance {
                        delta = -backwardDelta
                        confidence = backward.confidence
                        reversed = true
                    }
                }
            }

            if abs(delta) < options.minAdvance { delta = 0 }
            if confidence < options.minConfidence && !reversed {
                // Unknown movement: assume a full screen advance so that no
                // content is silently duplicated. The gap is reported later.
                delta = previousContent.count
            }

            position += delta
            offsets.append(FrameOffset(frameIndex: index,
                                       position: position,
                                       confidence: confidence,
                                       isReversed: reversed))
        }
        return offsets
    }

    // MARK: - Vertical implementation

    private static func planVertical(pyramids: [GrayPyramid], options: Options) -> StitchPlan {
        let width = pyramids.map(\.width).min() ?? 0
        guard width > 0 else { return .empty }

        // Chrome is measured from frame pairs that actually moved; frames where
        // nothing scrolled carry no information about what is fixed.
        var fixed = FixedRegions.none
        if options.trimFixedRegions {
            var measured = [FixedRegions]()
            for index in 1..<pyramids.count {
                if let alignment = ScrollAligner.align(previous: pyramids[index - 1],
                                                       next: pyramids[index],
                                                       options: options.detector),
                   alignment.scrollDelta >= options.minAdvance,
                   alignment.confidence >= options.minConfidence {
                    measured.append(alignment.fixedRegions)
                }
            }
            fixed = FixedRegionDetector.combine(measured)
        }
        let headerLength = options.trimFixedRegions && options.keepHeader ? fixed.topLength : 0
        let footerLength = options.trimFixedRegions && options.keepFooter ? fixed.bottomLength : 0

        let contentRange: (Int) -> Range<Int> = { index in
            options.trimFixedRegions
                ? fixed.contentRange(forHeight: pyramids[index].height)
                : 0..<pyramids[index].height
        }

        var offsets = estimateOffsets(pyramids: pyramids, contentRange: contentRange, options: options)
        guard !offsets.isEmpty else { return .empty }

        // Normalise so the top-most frame starts at zero, then order by position
        // while keeping the capture order for ties.
        let minPosition = offsets.map(\.position).min() ?? 0
        for index in offsets.indices { offsets[index].position -= minPosition }
        let ordered = offsets.enumerated()
            .sorted { lhs, rhs in
                lhs.element.position == rhs.element.position
                    ? lhs.offset < rhs.offset
                    : lhs.element.position < rhs.element.position
            }
            .map(\.element)

        var segments = [StitchSegment]()
        var joins = [StitchJoin]()
        var warnings = [StitchWarning]()
        var skipped = [Int]()
        var cursor = headerLength
        var previousPlaced: Int?

        for offset in ordered {
            let content = contentRange(offset.frameIndex)
            guard !content.isEmpty else { continue }
            var position = offset.position + headerLength

            if position > cursor {
                warnings.append(.contentGap(canvasPosition: cursor, missingLength: position - cursor))
                position = cursor
            }
            let sourceSkip = cursor - position
            let appended = content.count - sourceSkip
            guard appended > 0 else {
                skipped.append(offset.frameIndex)
                continue
            }
            if offset.isReversed {
                warnings.append(.scrollDirectionReversed(frameIndex: offset.frameIndex))
            }
            if offset.confidence < 0.5, previousPlaced != nil {
                warnings.append(.lowConfidenceJoin(nextIndex: offset.frameIndex, confidence: offset.confidence))
            }

            if let previous = previousPlaced {
                joins.append(StitchJoin(previousIndex: previous,
                                        nextIndex: offset.frameIndex,
                                        overlap: sourceSkip,
                                        confidence: offset.confidence,
                                        isManual: false,
                                        canvasPosition: cursor))
            }

            segments.append(StitchSegment(sourceIndex: offset.frameIndex,
                                          sourceRect: PixelRect(x: 0,
                                                                y: content.lowerBound + sourceSkip,
                                                                width: width,
                                                                height: appended),
                                          destinationRect: PixelRect(x: 0, y: cursor,
                                                                     width: width, height: appended),
                                          kind: .content))
            cursor += appended
            previousPlaced = offset.frameIndex
        }

        guard let firstPlaced = segments.first?.sourceIndex, let lastPlaced = previousPlaced else {
            return .empty
        }

        if headerLength > 0 {
            segments.insert(StitchSegment(sourceIndex: firstPlaced,
                                          sourceRect: PixelRect(x: 0, y: 0, width: width, height: headerLength),
                                          destinationRect: PixelRect(x: 0, y: 0, width: width, height: headerLength),
                                          kind: .fixedHeader),
                            at: 0)
        }
        if footerLength > 0 {
            segments.append(StitchSegment(sourceIndex: lastPlaced,
                                          sourceRect: PixelRect(x: 0,
                                                                y: pyramids[lastPlaced].height - footerLength,
                                                                width: width, height: footerLength),
                                          destinationRect: PixelRect(x: 0, y: cursor,
                                                                     width: width, height: footerLength),
                                          kind: .fixedFooter))
            cursor += footerLength
        }

        for index in skipped { warnings.append(.duplicateSource(index: index)) }

        return StitchPlan(axis: .vertical,
                          canvasSize: PixelSize(width: width, height: cursor),
                          segments: segments,
                          joins: joins,
                          warnings: warnings,
                          skippedSourceIndices: skipped,
                          fixedHeaderLength: headerLength,
                          fixedFooterLength: footerLength)
    }
}
