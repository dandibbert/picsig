import XCTest
import UIKit
@testable import PicSig
import PicSigCore

/// Stitching against real CoreGraphics rasterisation.
///
/// The Linux suite plans stitches from synthetic grayscale buffers, so it proves the
/// alignment maths. What it cannot check is the bridge either side of it: turning a
/// `CGImage` into the grayscale form the planner wants, and turning a plan back into
/// pixels without dropping or duplicating a band.
final class StitchPipelineTests: XCTestCase {
    private func rows(_ count: Int) -> [SyntheticScreenshot.Row] {
        (0..<count).map { .init(value: "第 \($0 + 1) 行内容 line \($0 + 1)") }
    }

    func testTwoOverlappingScreenshotsProduceOneTallerImage() throws {
        let pair = SyntheticScreenshot.overlappingPair(rows: rows(14), visibleRows: 8, overlapRows: 3)
        let first = try XCTUnwrap(pair.first.cgImage)
        let second = try XCTUnwrap(pair.second.cgImage)

        let grays = [first, second].compactMap { $0.grayImage(maxWidth: 1600) }
        XCTAssertEqual(grays.count, 2, "grayscale bridge failed")

        let plan = ScrollStitchPlanner.plan(images: grays)
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(plan.axis, .vertical)

        // The overlap must be found, so the result is shorter than simply appending.
        let naive = first.height + second.height
        XCTAssertLessThan(plan.canvasSize.height, naive,
                          "no overlap was removed; the two shots were just concatenated")
        XCTAssertGreaterThan(plan.canvasSize.height, first.height,
                             "the second shot added nothing at all")

        let join = try XCTUnwrap(plan.joins.first, "no seam reported")
        XCTAssertGreaterThan(join.confidence, 0.5, "alignment was not confident on a clean synthetic pair")
    }

    func testRenderedStitchMatchesThePlannedCanvas() throws {
        let pair = SyntheticScreenshot.overlappingPair(rows: rows(14), visibleRows: 8, overlapRows: 3)
        let sources = [try XCTUnwrap(pair.first.cgImage), try XCTUnwrap(pair.second.cgImage)]
        let grays = sources.compactMap { $0.grayImage(maxWidth: 1600) }
        let plan = ScrollStitchPlanner.plan(images: grays)

        XCTAssertTrue(plan.validate(sourceSizes: sources.map(\.pixelSize)).isEmpty,
                      "plan does not fit its sources: \(plan.validate(sourceSizes: sources.map(\.pixelSize)))")

        let rendered = try XCTUnwrap(StitchRenderer.render(plan: plan, sources: sources),
                                     "renderer returned nothing")
        XCTAssertEqual(Int(rendered.size.width), plan.canvasSize.width)
        XCTAssertEqual(Int(rendered.size.height), plan.canvasSize.height)
    }

    /// Every row of the original page has to appear exactly once in the stitch: a
    /// wrong overlap shows up as a repeated or missing line, which OCR can see even
    /// when the pixel dimensions look plausible.
    func testStitchedResultContainsEveryRowExactlyOnce() throws {
        let rowCount = 14
        let pair = SyntheticScreenshot.overlappingPair(rows: rows(rowCount), visibleRows: 8, overlapRows: 3)
        let sources = [try XCTUnwrap(pair.first.cgImage), try XCTUnwrap(pair.second.cgImage)]
        let grays = sources.compactMap { $0.grayImage(maxWidth: 1600) }

        // Fixed region trimming is off so a dropped row can only mean the overlap was
        // wrong, which is what this test is about. Synthetic pages have no chrome for
        // the detector to find anyway.
        var options = ScrollStitchPlanner.Options.default
        options.trimFixedRegions = false
        let plan = ScrollStitchPlanner.plan(images: grays, options: options)
        let rendered = try XCTUnwrap(StitchRenderer.render(plan: plan, sources: sources))

        var service = TextRecognitionService()
        service.options.tileHeight = 4000
        service.options.computesCharacterBoxes = false
        let text = try service.recognize(cgImage: try XCTUnwrap(rendered.cgImage)).plainText

        // The seam sits between rows, so the marker text of each row should occur once.
        for index in 1...rowCount {
            let marker = "line \(index)"
            let occurrences = text.components(separatedBy: marker).count - 1
            XCTAssertEqual(occurrences, 1,
                           "row \(index) appears \(occurrences) times instead of once. Stitched text:\n\(text)")
        }
    }

    func testManualGridLayoutPlacesEverySource() throws {
        let images = (0..<4).map { index in
            SyntheticScreenshot.make(rows: [.init(value: "格子 \(index + 1)")], rowHeight: 64)
        }
        let sources = try images.map { try XCTUnwrap($0.cgImage) }
        let plan = ManualLayoutPlanner.plan(sizes: sources.map(\.pixelSize),
                                            options: .grid(columns: 2, spacing: 8, padding: 8))

        XCTAssertEqual(plan.segments.count, 4)
        XCTAssertTrue(plan.validate(sourceSizes: sources.map(\.pixelSize)).isEmpty)

        let rendered = try XCTUnwrap(StitchRenderer.render(plan: plan, sources: sources))
        XCTAssertEqual(Int(rendered.size.width), plan.canvasSize.width)
        XCTAssertEqual(Int(rendered.size.height), plan.canvasSize.height)
    }

    /// Horizontal stitching runs the vertical algorithm on transposed images. If the
    /// geometry is not transposed back correctly the canvas comes out portrait.
    func testHorizontalStitchGrowsSideways() throws {
        let pair = SyntheticScreenshot.overlappingPair(rows: rows(14), visibleRows: 8, overlapRows: 3)
        let sources = [try XCTUnwrap(pair.first.cgImage), try XCTUnwrap(pair.second.cgImage)]
        let grays = sources.compactMap { $0.grayImage(maxWidth: 1600) }

        var options = ScrollStitchPlanner.Options.default
        options.axis = .horizontal
        let plan = ScrollStitchPlanner.plan(images: grays, options: options)

        XCTAssertEqual(plan.axis, .horizontal)
        XCTAssertGreaterThan(plan.canvasSize.width, sources[0].width,
                             "a horizontal stitch did not get wider")
        XCTAssertTrue(plan.validate(sourceSizes: sources.map(\.pixelSize)).isEmpty)
    }
}
