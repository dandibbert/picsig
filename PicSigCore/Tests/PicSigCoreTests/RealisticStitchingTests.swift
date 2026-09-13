import XCTest
@testable import PicSigCore

/// Stitching on screenshots that behave like real iPhone captures.
///
/// Each test renders a scroll sequence with `RealisticScreenshot`, plans a stitch,
/// paints the plan back into a grayscale canvas and compares it against the ideal
/// long page pixel by pixel. That catches every way a stitch can go wrong: a wrong
/// overlap, a repeated navigation bar, a missing band, a duplicated row.
final class RealisticStitchingTests: XCTestCase {
    typealias Device = RealisticScreenshot.Device

    // MARK: - The bug the user hit

    func testListWithTranslucentBarsStitchesAtTheRightOffsets() {
        assertStitches(style: .list, scrolls: [0, 1400, 2700, 3900])
    }

    func testChatWithTranslucentBars() {
        assertStitches(style: .chat, scrolls: [0, 1100, 2300])
    }

    func testRepetitiveRowsPickTheTrueOffsetNotThePeriod() {
        // Row period is 176px; a detector that locks onto "any row looks like any
        // other row" lands on a multiple of 176 instead of the real scroll.
        assertStitches(style: .repetitiveList, scrolls: [0, 1500, 2900])
    }

    // MARK: - Overlap extremes

    func testSmallScrollLeavesMostOfTheScreenOverlapping() {
        assertStitches(style: .list, scrolls: [0, 300])
    }

    func testLargeScrollLeavesLittleOverlap() {
        // Content area is 2010px; scrolling 1850 leaves 160px in common.
        assertStitches(style: .list, scrolls: [0, 1850])
    }

    // MARK: - Variations

    func testOpaqueBarsStillWork() {
        assertStitches(style: .list, scrolls: [0, 1300, 2500], translucentBars: false)
    }

    func testSmallerDevice() {
        assertStitches(style: .list, device: .iPhoneSE, scrolls: [0, 700, 1300])
    }

    func testEveryJoinIsConfident() {
        let shots = RealisticScreenshot.sequence(style: .list, scrolls: [0, 1400, 2700, 3900])
        let plan = ScrollStitchPlanner.plan(images: shots)
        XCTAssertEqual(plan.joins.count, 3)
        for join in plan.joins {
            XCTAssertGreaterThan(join.confidence, 0.6, "join \(join.previousIndex)→\(join.nextIndex) confidence \(join.confidence)")
        }
        XCTAssertFalse(plan.warnings.contains { if case .lowConfidenceJoin = $0 { return true } else { return false } },
                       "warnings: \(plan.warnings)")
    }

    func testDuplicateScreenshotIsSkippedNotAppended() {
        let shots = RealisticScreenshot.sequence(style: .list, scrolls: [0, 1400, 1400, 2700])
        let plan = ScrollStitchPlanner.plan(images: shots)
        XCTAssertEqual(plan.skippedSourceIndices, [2])
        assertMatchesIdeal(plan: plan, sources: shots, style: .list, device: .iPhone13, scrolls: [0, 1400, 2700])
    }

    // MARK: - Helpers

    private func assertStitches(style: RealisticScreenshot.Style,
                                device: Device = .iPhone13,
                                scrolls: [Int],
                                translucentBars: Bool = true,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        let shots = RealisticScreenshot.sequence(style: style, device: device, scrolls: scrolls,
                                                 translucentBars: translucentBars)
        let plan = ScrollStitchPlanner.plan(images: shots)

        let expectedHeight = device.header + (scrolls.last ?? 0) + device.contentHeight + device.footer
        XCTAssertEqual(plan.canvasSize.height, expectedHeight, accuracy: 3,
                       "canvas height off by \(plan.canvasSize.height - expectedHeight)px; " +
                       "joins: \(plan.joins.map { "\($0.overlap)@\(String(format: "%.2f", $0.confidence))" }) " +
                       "warnings: \(plan.warnings)",
                       file: file, line: line)
        XCTAssertTrue(plan.skippedSourceIndices.isEmpty, "skipped \(plan.skippedSourceIndices)", file: file, line: line)

        assertMatchesIdeal(plan: plan, sources: shots, style: style, device: device, scrolls: scrolls,
                           translucentBars: translucentBars, file: file, line: line)
    }

    /// Paints the plan and compares every row with the ideal page: the first shot's
    /// bars at the top, the last shot's at the bottom, and the content plane in
    /// between. The scroll indicator columns are excluded.
    ///
    /// The comparison deliberately uses the *device's* bar heights, not the plan's
    /// detected ones. Whether a blank gap under the navigation bar is labelled
    /// "header" or "content" changes nothing visible, so the plan is free to draw
    /// that line anywhere inside the gap — what must hold is that the finished page
    /// looks right.
    private func assertMatchesIdeal(plan: StitchPlan,
                                    sources: [GrayImage],
                                    style: RealisticScreenshot.Style,
                                    device: Device,
                                    scrolls: [Int],
                                    translucentBars: Bool = true,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        guard plan.canvasSize.height > 0 else {
            XCTFail("empty plan", file: file, line: line)
            return
        }
        let canvas = paint(plan: plan, sources: sources)
        let usableWidth = device.width - 24 // drop the scroll indicator gutter
        let last = sources[plan.segments.last?.sourceIndex ?? sources.count - 1]

        var worstRow = 0
        var worstDifference = 0.0
        var badRows = 0
        for y in 0..<canvas.height {
            let ideal: (Int) -> UInt8
            if y < device.header {
                ideal = { x in sources[0].pixel(x: x, y: y) }
            } else if y >= canvas.height - device.footer {
                ideal = { x in last.pixel(x: x, y: last.height - (canvas.height - y)) }
            } else {
                ideal = { x in RealisticScreenshot.content(style: style, x: x, absoluteY: y, width: device.width, seed: 11) }
            }
            var total = 0
            for x in 0..<usableWidth {
                total += abs(Int(canvas.pixel(x: x, y: y)) - Int(ideal(x)))
            }
            let mean = Double(total) / Double(usableWidth)
            if mean > worstDifference { worstDifference = mean; worstRow = y }
            if mean > 4 { badRows += 1 }
        }
        XCTAssertLessThanOrEqual(badRows, 3,
                                 "\(badRows) rows differ from the ideal page (worst: row \(worstRow), mean diff \(String(format: "%.1f", worstDifference))). " +
                                 "joins: \(plan.joins.map { "\($0.overlap)@\(String(format: "%.2f", $0.confidence))" }) " +
                                 "chrome: header \(plan.fixedHeaderLength) (true \(device.header)), footer \(plan.fixedFooterLength) (true \(device.footer))",
                                 file: file, line: line)
    }

    private func paint(plan: StitchPlan, sources: [GrayImage]) -> GrayImage {
        var canvas = GrayImage(width: plan.canvasSize.width, height: plan.canvasSize.height, repeating: 0)
        for segment in plan.segments {
            let source = sources[segment.sourceIndex]
            for dy in 0..<segment.destinationRect.height {
                let sy = segment.sourceRect.y + dy
                let ty = segment.destinationRect.y + dy
                guard sy < source.height, ty < canvas.height else { continue }
                for dx in 0..<min(segment.destinationRect.width, source.width) {
                    canvas.setPixel(x: segment.destinationRect.x + dx, y: ty,
                                    value: source.pixel(x: segment.sourceRect.x + dx, y: sy))
                }
            }
        }
        return canvas
    }
}
