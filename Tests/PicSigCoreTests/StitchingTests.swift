import XCTest
@testable import PicSigCore

final class OverlapDetectorTests: XCTestCase {
    func testDetectsPlainScrollOffset() {
        let first = SyntheticImage.screenshot(width: 200, height: 600, scrollOffset: 0)
        let second = SyntheticImage.screenshot(width: 200, height: 600, scrollOffset: 220)

        let match = OverlapDetector.detect(previous: first, next: second)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.overlap, 380)
        XCTAssertEqual(match?.cost ?? .infinity, 0, accuracy: 0.001)
        XCTAssertGreaterThan(match?.confidence ?? 0, 0.8)
    }

    func testDetectsOffsetWithinContentRangeOnly() {
        let first = SyntheticImage.screenshot(width: 240, height: 800, scrollOffset: 0,
                                              headerHeight: 60, footerHeight: 40)
        let second = SyntheticImage.screenshot(width: 240, height: 800, scrollOffset: 250,
                                              headerHeight: 60, footerHeight: 40)
        let content = 60..<760

        let match = OverlapDetector.detect(previous: first, next: second,
                                           previousContent: content, nextContent: content)
        XCTAssertEqual(match?.overlap, 450)
    }

    func testReturnsNilForUnrelatedImages() {
        let first = SyntheticImage.screenshot(width: 120, height: 400, scrollOffset: 0, seed: 1)
        let second = SyntheticImage.screenshot(width: 120, height: 400, scrollOffset: 999, seed: 99)

        let match = OverlapDetector.detect(previous: first, next: second)
        // Unrelated noise may still produce a "best" offset, but it must not be
        // presented as trustworthy.
        XCTAssertLessThan(match?.confidence ?? 0, 0.3)
    }

    func testFlatImagesProduceNoAnchor() {
        let flat = SyntheticImage.solid(width: 100, height: 300, value: 255)
        XCTAssertNil(OverlapDetector.detect(previous: flat, next: flat))
    }

    func testSmallScrollOnLongPageIsExact() {
        let first = SyntheticImage.screenshot(width: 320, height: 1200, scrollOffset: 0)
        let second = SyntheticImage.screenshot(width: 320, height: 1200, scrollOffset: 17)

        let match = OverlapDetector.detect(previous: first, next: second)
        XCTAssertEqual(match?.overlap, 1183)
    }
}

final class FixedRegionDetectorTests: XCTestCase {
    func testFindsHeaderAndFooter() {
        let first = SyntheticImage.screenshot(width: 200, height: 700, scrollOffset: 0,
                                              headerHeight: 64, footerHeight: 48)
        let second = SyntheticImage.screenshot(width: 200, height: 700, scrollOffset: 300,
                                              headerHeight: 64, footerHeight: 48)

        let regions = FixedRegionDetector.detect(previous: first, next: second)
        XCTAssertEqual(regions.topLength, 64)
        XCTAssertEqual(regions.bottomLength, 48)
        XCTAssertEqual(regions.contentRange(forHeight: 700), 64..<652)
    }

    func testNoChromeMeansNoFixedRegions() {
        let first = SyntheticImage.screenshot(width: 200, height: 700, scrollOffset: 0)
        let second = SyntheticImage.screenshot(width: 200, height: 700, scrollOffset: 120)

        let regions = FixedRegionDetector.detect(previous: first, next: second)
        XCTAssertEqual(regions, .none)
    }

    func testFixedBandIsCappedForIdenticalImages() {
        let image = SyntheticImage.screenshot(width: 100, height: 500, scrollOffset: 0)
        let regions = FixedRegionDetector.detect(previous: image, next: image)
        XCTAssertLessThanOrEqual(regions.topLength, 175)
        XCTAssertLessThanOrEqual(regions.bottomLength, 175)
    }

    func testSequenceUsesTheMostConservativeEstimate() {
        let images = [
            SyntheticImage.screenshot(width: 160, height: 600, scrollOffset: 0, headerHeight: 40, footerHeight: 30),
            SyntheticImage.screenshot(width: 160, height: 600, scrollOffset: 200, headerHeight: 40, footerHeight: 30),
            SyntheticImage.screenshot(width: 160, height: 600, scrollOffset: 400, headerHeight: 40, footerHeight: 30)
        ]
        let regions = FixedRegionDetector.detect(images: images)
        XCTAssertEqual(regions.topLength, 40)
        XCTAssertEqual(regions.bottomLength, 30)
    }
}

final class ScrollStitchPlannerTests: XCTestCase {
    private func screenshots(offsets: [Int],
                             width: Int = 240,
                             height: Int = 800,
                             header: Int = 60,
                             footer: Int = 40) -> [GrayImage] {
        offsets.map {
            SyntheticImage.screenshot(width: width, height: height, scrollOffset: $0,
                                      headerHeight: header, footerHeight: footer)
        }
    }

    func testKeepsChromeOnceAndTrimsOverlap() {
        let images = screenshots(offsets: [0, 300, 600])
        let plan = ScrollStitchPlanner.plan(images: images)

        XCTAssertEqual(plan.axis, .vertical)
        XCTAssertEqual(plan.fixedHeaderLength, 60)
        XCTAssertEqual(plan.fixedFooterLength, 40)
        // 60 header + 700 + 300 + 300 content + 40 footer
        XCTAssertEqual(plan.canvasSize, PixelSize(width: 240, height: 1400))
        XCTAssertEqual(plan.segments.map(\.kind), [.fixedHeader, .content, .content, .content, .fixedFooter])
        XCTAssertEqual(plan.joins.map(\.overlap), [400, 400])
        XCTAssertTrue(plan.validate(sourceSizes: images.map(\.size)).isEmpty)
        XCTAssertTrue(plan.joinsNeedingReview.isEmpty)
        XCTAssertGreaterThan(plan.lowestConfidence, 0.7)
    }

    func testCanvasIsGaplessAndOrdered() {
        let plan = ScrollStitchPlanner.plan(images: screenshots(offsets: [0, 180, 360, 540]))
        var expectedY = 0
        for segment in plan.segments {
            XCTAssertEqual(segment.destinationRect.y, expectedY)
            expectedY += segment.destinationRect.height
        }
        XCTAssertEqual(expectedY, plan.canvasSize.height)
    }

    func testDropsDuplicateScreenshot() {
        let images = screenshots(offsets: [0, 300, 300, 600])
        let plan = ScrollStitchPlanner.plan(images: images)

        XCTAssertEqual(plan.skippedSourceIndices, [2])
        XCTAssertEqual(plan.canvasSize.height, 1400)
        XCTAssertTrue(plan.warnings.contains(.duplicateSource(index: 2)))
    }

    func testManualOverlapOverridesDetection() {
        let images = screenshots(offsets: [0, 300])
        let plan = ScrollStitchPlanner.plan(images: images, manualOverlaps: [1: 100])

        XCTAssertEqual(plan.joins.first?.overlap, 100)
        XCTAssertTrue(plan.joins.first?.isManual ?? false)
        XCTAssertEqual(plan.canvasSize.height, 60 + 700 + 600 + 40)
    }

    func testChromeCanBeStrippedEntirely() {
        var options = ScrollStitchPlanner.Options.default
        options.keepHeader = false
        options.keepFooter = false
        let plan = ScrollStitchPlanner.plan(images: screenshots(offsets: [0, 300]), options: options)

        XCTAssertEqual(plan.fixedHeaderLength, 0)
        XCTAssertEqual(plan.fixedFooterLength, 0)
        XCTAssertEqual(plan.canvasSize.height, 1000)
        XCTAssertEqual(plan.segments.allSatisfy { $0.kind == .content }, true)
    }

    func testDisablingTrimKeepsEverySourceRow() {
        var options = ScrollStitchPlanner.Options.default
        options.trimFixedRegions = false
        let plan = ScrollStitchPlanner.plan(images: screenshots(offsets: [0, 300]), options: options)

        // Without trimming, the chrome takes part in the matching and the images
        // are joined on their full height.
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].sourceRect.height, 800)
    }

    func testHorizontalStitchingMirrorsVertical() {
        let vertical = screenshots(offsets: [0, 250], width: 200, height: 600, header: 50, footer: 20)
        let horizontal = vertical.map { $0.transposed() }

        let verticalPlan = ScrollStitchPlanner.plan(images: vertical)
        var options = ScrollStitchPlanner.Options.default
        options.axis = .horizontal
        let horizontalPlan = ScrollStitchPlanner.plan(images: horizontal, options: options)

        XCTAssertEqual(horizontalPlan.axis, .horizontal)
        XCTAssertEqual(horizontalPlan.canvasSize,
                       PixelSize(width: verticalPlan.canvasSize.height,
                                 height: verticalPlan.canvasSize.width))
        XCTAssertEqual(horizontalPlan.segments.map(\.destinationRect),
                       verticalPlan.segments.map { $0.destinationRect.transposed })
        XCTAssertTrue(horizontalPlan.validate(sourceSizes: horizontal.map(\.size)).isEmpty)
    }

    func testSingleImagePassesThrough() {
        let images = screenshots(offsets: [0])
        let plan = ScrollStitchPlanner.plan(images: images)
        XCTAssertEqual(plan.canvasSize, PixelSize(width: 240, height: 800))
        XCTAssertTrue(plan.joins.isEmpty)
    }

    func testEmptyInput() {
        XCTAssertTrue(ScrollStitchPlanner.plan(images: []).isEmpty)
    }
}

final class VideoScrollPlannerTests: XCTestCase {
    private func frames(offsets: [Int]) -> [GrayImage] {
        offsets.map {
            SyntheticImage.screenshot(width: 200, height: 600, scrollOffset: $0,
                                      headerHeight: 50, footerHeight: 30)
        }
    }

    func testAssemblesFramesAndDropsStaticOnes() {
        let plan = VideoScrollPlanner.plan(frames: frames(offsets: [0, 0, 60, 120, 120, 180]))

        XCTAssertEqual(plan.fixedHeaderLength, 50)
        XCTAssertEqual(plan.fixedFooterLength, 30)
        // 50 header + 520 content + 180 scrolled + 30 footer
        XCTAssertEqual(plan.canvasSize, PixelSize(width: 200, height: 780))
        XCTAssertEqual(plan.skippedSourceIndices.sorted(), [1, 4])
        XCTAssertFalse(plan.warnings.contains { warning in
            if case .contentGap = warning { return true }
            return false
        })
    }

    func testBounceBackFrameIsPlacedByPositionNotByCaptureOrder() {
        // Frame 2 scrolled back up; sorting by estimated position means it is
        // used for the rows between frame 0 and frame 1 instead of being
        // appended at the end (which would duplicate content).
        let plan = VideoScrollPlanner.plan(frames: frames(offsets: [0, 120, 60, 200]))

        XCTAssertEqual(plan.canvasSize.height, 50 + 520 + 200 + 30)
        XCTAssertEqual(plan.segments.filter { $0.kind == .content }.map(\.sourceIndex), [0, 2, 1, 3])
        XCTAssertTrue(plan.warnings.contains(.scrollDirectionReversed(frameIndex: 2)))
        XCTAssertTrue(plan.skippedSourceIndices.isEmpty)
    }

    func testStaticFrameIsReportedAsDuplicate() {
        let plan = VideoScrollPlanner.plan(frames: frames(offsets: [0, 0, 90]))
        XCTAssertEqual(plan.skippedSourceIndices, [1])
        XCTAssertTrue(plan.warnings.contains(.duplicateSource(index: 1)))
        XCTAssertEqual(plan.canvasSize.height, 50 + 520 + 90 + 30)
    }

    func testEstimatesTrackWithReverseScrolling() {
        let pyramids = frames(offsets: [0, 100, 40]).map { GrayPyramid(image: $0) }
        let offsets = VideoScrollPlanner.estimateOffsets(pyramids: pyramids,
                                                        contentRange: { _ in 50..<570 },
                                                        options: .default)
        XCTAssertEqual(offsets.map(\.position), [0, 100, 40])
        XCTAssertTrue(offsets[2].isReversed)
    }

    func testTooFastScrollingIsReportedAsGap() {
        // A jump larger than one screen cannot be recovered from the recording.
        let plan = VideoScrollPlanner.plan(frames: frames(offsets: [0, 2000]))
        XCTAssertTrue(plan.warnings.contains { warning in
            if case .lowConfidenceJoin = warning { return true }
            return false
        })
        XCTAssertEqual(plan.segments.filter { $0.kind == .content }.count, 2)
    }
}

final class ManualLayoutPlannerTests: XCTestCase {
    func testVerticalStackScalesToCommonWidth() {
        let sizes = [PixelSize(width: 200, height: 400), PixelSize(width: 100, height: 300)]
        let plan = ManualLayoutPlanner.plan(sizes: sizes, options: .verticalStack)

        XCTAssertEqual(plan.canvasSize, PixelSize(width: 200, height: 1000))
        XCTAssertEqual(plan.segments[0].destinationRect, PixelRect(x: 0, y: 0, width: 200, height: 400))
        XCTAssertEqual(plan.segments[1].destinationRect, PixelRect(x: 0, y: 400, width: 200, height: 600))
        XCTAssertEqual(plan.segments[1].sourceRect, PixelRect(x: 0, y: 0, width: 100, height: 300))
    }

    func testSpacingAndPaddingAreApplied() {
        let sizes = [PixelSize(width: 100, height: 100), PixelSize(width: 100, height: 100)]
        var options = ManualLayoutOptions.verticalStack
        options.spacing = 10
        options.padding = 20
        let plan = ManualLayoutPlanner.plan(sizes: sizes, options: options)

        XCTAssertEqual(plan.canvasSize, PixelSize(width: 140, height: 250))
        XCTAssertEqual(plan.segments[0].destinationRect, PixelRect(x: 20, y: 20, width: 100, height: 100))
        XCTAssertEqual(plan.segments[1].destinationRect, PixelRect(x: 20, y: 130, width: 100, height: 100))
    }

    func testHorizontalStripMatchesHeights() {
        let sizes = [PixelSize(width: 200, height: 400), PixelSize(width: 200, height: 200)]
        let plan = ManualLayoutPlanner.plan(sizes: sizes, options: .horizontalStrip)

        XCTAssertEqual(plan.canvasSize, PixelSize(width: 600, height: 400))
        XCTAssertEqual(plan.segments[1].destinationRect, PixelRect(x: 200, y: 0, width: 400, height: 400))
    }

    func testGridFillsUniformCells() {
        let sizes = [PixelSize(width: 100, height: 200),
                     PixelSize(width: 100, height: 100),
                     PixelSize(width: 100, height: 100)]
        let plan = ManualLayoutPlanner.plan(sizes: sizes, options: .grid(columns: 2, spacing: 10, padding: 10))

        XCTAssertEqual(plan.canvasSize.width, 10 * 2 + 100 * 2 + 10)
        XCTAssertEqual(plan.segments.count, 3)
        // Uniform cells: every destination has the same size.
        XCTAssertEqual(Set(plan.segments.map(\.destinationRect.size)).count, 1)
        // The tall image is centre-cropped instead of being squashed.
        XCTAssertEqual(plan.segments[0].sourceRect.height, 100)
        XCTAssertEqual(plan.segments[0].sourceRect.y, 50)
    }

    func testOriginalSizeAlignment() {
        let sizes = [PixelSize(width: 100, height: 50), PixelSize(width: 60, height: 50)]
        var options = ManualLayoutOptions.verticalStack
        options.scaleMode = .original
        options.alignment = .trailing
        let plan = ManualLayoutPlanner.plan(sizes: sizes, options: options)

        XCTAssertEqual(plan.canvasSize, PixelSize(width: 100, height: 100))
        XCTAssertEqual(plan.segments[1].destinationRect, PixelRect(x: 40, y: 50, width: 60, height: 50))
    }

    func testEmptyAndDegenerateInput() {
        XCTAssertTrue(ManualLayoutPlanner.plan(sizes: [], options: .verticalStack).isEmpty)
        XCTAssertTrue(ManualLayoutPlanner.plan(sizes: [.zero], options: .verticalStack).isEmpty)
    }
}
