import Foundation

/// Turns a sequence of overlapping screenshots into a single long image plan.
public enum ScrollStitchPlanner {
    public struct Options: Sendable {
        public var axis: StitchAxis
        public var detector: OverlapDetector.Options
        public var fixedRegions: FixedRegionDetector.Options
        /// Detect the static chrome and keep it only once.
        public var trimFixedRegions: Bool
        /// Keep the detected header (status + navigation bar) at the very top.
        public var keepHeader: Bool
        /// Keep the detected footer (tab bar / home indicator) at the very bottom.
        public var keepFooter: Bool
        /// Below this confidence the detected offset is discarded in favour of
        /// `fallbackOverlap`; a clean butt joint beats a confidently wrong seam.
        public var minConfidence: Double
        /// Overlap used when no alignment could be found at all.
        public var fallbackOverlap: Int

        public init(axis: StitchAxis = .vertical,
                    detector: OverlapDetector.Options = .default,
                    fixedRegions: FixedRegionDetector.Options = .default,
                    trimFixedRegions: Bool = true,
                    keepHeader: Bool = true,
                    keepFooter: Bool = true,
                    minConfidence: Double = 0.2,
                    fallbackOverlap: Int = 0) {
            self.axis = axis
            self.detector = detector
            self.fixedRegions = fixedRegions
            self.trimFixedRegions = trimFixedRegions
            self.keepHeader = keepHeader
            self.keepFooter = keepFooter
            self.minConfidence = minConfidence
            self.fallbackOverlap = fallbackOverlap
        }

        public static let `default` = Options()
    }

    public static func plan(images: [GrayImage],
                            manualOverlaps: [Int: Int] = [:],
                            options: Options = .default) -> StitchPlan {
        let factor = max(1, options.detector.coarseFactor)
        return plan(pyramids: images.map { GrayPyramid(image: $0, factor: factor) },
                    manualOverlaps: manualOverlaps,
                    options: options)
    }

    public static func plan(pyramids: [GrayPyramid],
                            manualOverlaps: [Int: Int] = [:],
                            options: Options = .default) -> StitchPlan {
        guard !pyramids.isEmpty else { return .empty }
        if options.axis == .horizontal {
            var verticalOptions = options
            verticalOptions.axis = .vertical
            let transposedPlan = planVertical(pyramids: pyramids.map { $0.transposed() },
                                              manualOverlaps: manualOverlaps,
                                              options: verticalOptions)
            return transposedPlan.transposedPlan()
        }
        return planVertical(pyramids: pyramids, manualOverlaps: manualOverlaps, options: options)
    }

    // MARK: - Vertical implementation

    private static func planVertical(pyramids: [GrayPyramid],
                                     manualOverlaps: [Int: Int],
                                     options: Options) -> StitchPlan {
        let width = pyramids.map(\.width).min() ?? 0
        guard width > 0, let firstHeight = pyramids.first?.height, firstHeight > 0 else { return .empty }

        // Alignment runs on the whole images first. The static chrome is derived
        // from the confident alignments rather than guessed beforehand, because
        // "rows that look identical at the same position" is not a usable
        // definition of a navigation bar: translucent bars fail it, and blank
        // content rows pass it.
        var alignments = [Int: ScrollAlignment]()
        for index in 1..<pyramids.count {
            alignments[index] = ScrollAligner.align(previous: pyramids[index - 1],
                                                    next: pyramids[index],
                                                    options: options.detector)
        }

        let fixed: FixedRegions
        if options.trimFixedRegions {
            fixed = FixedRegionDetector.combine(alignments.values.filter {
                $0.scrollDelta > 0 && $0.confidence >= options.minConfidence
            }.map(\.fixedRegions))
        } else {
            fixed = .none
        }
        let headerLength = options.trimFixedRegions && options.keepHeader ? fixed.topLength : 0
        let footerLength = options.trimFixedRegions && options.keepFooter ? fixed.bottomLength : 0

        func contentRange(_ index: Int) -> Range<Int> {
            options.trimFixedRegions
                ? fixed.contentRange(forHeight: pyramids[index].height)
                : 0..<pyramids[index].height
        }

        var segments = [StitchSegment]()
        var joins = [StitchJoin]()
        var warnings = [StitchWarning]()
        var skipped = [Int]()
        var cursor = 0

        for (index, pyramid) in pyramids.enumerated() where pyramid.width != width {
            warnings.append(.mismatchedSourceSize(index: index))
        }

        if headerLength > 0 {
            segments.append(StitchSegment(sourceIndex: 0,
                                          sourceRect: PixelRect(x: 0, y: 0, width: width, height: headerLength),
                                          destinationRect: PixelRect(x: 0, y: 0, width: width, height: headerLength),
                                          kind: .fixedHeader))
            cursor += headerLength
        }

        let firstContent = contentRange(0)
        guard !firstContent.isEmpty else { return .empty }
        segments.append(StitchSegment(sourceIndex: 0,
                                      sourceRect: PixelRect(x: 0, y: firstContent.lowerBound,
                                                            width: width, height: firstContent.count),
                                      destinationRect: PixelRect(x: 0, y: cursor,
                                                                 width: width, height: firstContent.count),
                                      kind: .content))
        cursor += firstContent.count

        var previousUsed = 0
        for index in 1..<pyramids.count {
            let previousContent = contentRange(previousUsed)
            let nextContent = contentRange(index)
            guard !nextContent.isEmpty else {
                skipped.append(index)
                warnings.append(.duplicateSource(index: index))
                continue
            }

            var overlap: Int
            var confidence: Double
            var isManual = false

            // Pairs are normally consecutive; after a skipped duplicate the
            // previous *used* shot is further back and needs its own alignment.
            let alignment = previousUsed == index - 1
                ? alignments[index]
                : ScrollAligner.align(previous: pyramids[previousUsed], next: pyramids[index], options: options.detector)

            if let manual = manualOverlaps[index] {
                overlap = manual
                confidence = 1
                isManual = true
            } else if let alignment {
                confidence = alignment.confidence
                if alignment.confidence < options.minConfidence {
                    overlap = options.fallbackOverlap
                } else if alignment.scrollDelta == 0 {
                    // Nothing moved: the whole content is shared, so nothing is appended.
                    overlap = min(previousContent.count, nextContent.count)
                } else {
                    overlap = OverlapDetector.sharedRows(previous: previousContent,
                                                         next: nextContent,
                                                         scrollDelta: alignment.scrollDelta)
                }
            } else {
                overlap = options.fallbackOverlap
                confidence = 0
            }

            overlap = min(max(0, overlap), min(previousContent.count, nextContent.count))
            let appended = nextContent.count - overlap
            guard appended > 0 else {
                // The screenshot is completely contained in its predecessor.
                skipped.append(index)
                warnings.append(.duplicateSource(index: index))
                continue
            }

            if !isManual && confidence < 0.5 {
                warnings.append(.lowConfidenceJoin(nextIndex: index, confidence: confidence))
            }
            joins.append(StitchJoin(previousIndex: previousUsed,
                                    nextIndex: index,
                                    overlap: overlap,
                                    confidence: confidence,
                                    isManual: isManual,
                                    canvasPosition: cursor))
            segments.append(StitchSegment(sourceIndex: index,
                                          sourceRect: PixelRect(x: 0,
                                                                y: nextContent.lowerBound + overlap,
                                                                width: width,
                                                                height: appended),
                                          destinationRect: PixelRect(x: 0, y: cursor,
                                                                     width: width, height: appended),
                                          kind: .content))
            cursor += appended
            previousUsed = index
        }

        if footerLength > 0 {
            let last = previousUsed
            let sourceTop = pyramids[last].height - footerLength
            segments.append(StitchSegment(sourceIndex: last,
                                          sourceRect: PixelRect(x: 0, y: sourceTop,
                                                                width: width, height: footerLength),
                                          destinationRect: PixelRect(x: 0, y: cursor,
                                                                     width: width, height: footerLength),
                                          kind: .fixedFooter))
            cursor += footerLength
        }

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
