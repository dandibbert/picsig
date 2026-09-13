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
    private func grays(_ sources: [CGImage]) throws -> [GrayImage] {
        let grays = sources.compactMap { $0.grayImage(maxWidth: 1600) }
        XCTAssertEqual(grays.count, sources.count, "the grayscale bridge dropped an image")
        return grays
    }

    func testTwoOverlappingScreenshotsProduceOneTallerImage() throws {
        let pair = SyntheticScreenshot.verticalPair(visibleRows: 8, overlapRows: 3)
        let sources = [try XCTUnwrap(pair.first.cgImage), try XCTUnwrap(pair.second.cgImage)]

        let plan = ScrollStitchPlanner.plan(images: try grays(sources))
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(plan.axis, .vertical)

        // The overlap must be found, so the result is shorter than simply appending.
        XCTAssertLessThan(plan.canvasSize.height, sources[0].height + sources[1].height,
                          "no overlap was removed; the two shots were just concatenated")
        XCTAssertGreaterThan(plan.canvasSize.height, sources[0].height,
                             "the second shot added nothing at all")

        let join = try XCTUnwrap(plan.joins.first, "no seam reported")
        XCTAssertGreaterThan(join.confidence, 0.5, "alignment was not confident on a clean synthetic pair")
    }

    func testRenderedStitchMatchesThePlannedCanvas() throws {
        let pair = SyntheticScreenshot.verticalPair(visibleRows: 8, overlapRows: 3)
        let sources = [try XCTUnwrap(pair.first.cgImage), try XCTUnwrap(pair.second.cgImage)]
        let plan = ScrollStitchPlanner.plan(images: try grays(sources))

        let problems = plan.validate(sourceSizes: sources.map(\.pixelSize))
        XCTAssertTrue(problems.isEmpty, "plan does not fit its sources: \(problems)")

        let rendered = try XCTUnwrap(StitchRenderer.render(plan: plan, sources: sources),
                                     "renderer returned nothing")
        XCTAssertEqual(Int(rendered.size.width), plan.canvasSize.width)
        XCTAssertEqual(Int(rendered.size.height), plan.canvasSize.height)
    }

    /// Every row of the original page has to appear exactly once, in order. A wrong
    /// overlap shows up as a duplicated or missing row even when the pixel dimensions
    /// look plausible, so this is the assertion that actually pins alignment down.
    func testStitchedResultContainsEveryRowExactlyOnceInOrder() throws {
        let pair = SyntheticScreenshot.verticalPair(visibleRows: 8, overlapRows: 3)
        let sources = [try XCTUnwrap(pair.first.cgImage), try XCTUnwrap(pair.second.cgImage)]

        // Fixed region trimming is off so a dropped row can only mean the overlap was
        // wrong. Synthetic pages have no chrome for the detector to find anyway.
        var options = ScrollStitchPlanner.Options.default
        options.trimFixedRegions = false
        let plan = ScrollStitchPlanner.plan(images: try grays(sources), options: options)
        let rendered = try XCTUnwrap(StitchRenderer.render(plan: plan, sources: sources))

        let text = try recognisedText(in: rendered)
        var lastPosition = text.startIndex
        for index in 1...pair.rowCount {
            let marker = SyntheticScreenshot.marker(index)
            let occurrences = text.components(separatedBy: marker).count - 1
            XCTAssertEqual(occurrences, 1,
                           "row \(index) appears \(occurrences) times instead of once:\n\(text)")

            if let found = text.range(of: marker) {
                XCTAssertGreaterThanOrEqual(found.lowerBound, lastPosition,
                                            "row \(index) is out of order:\n\(text)")
                lastPosition = found.lowerBound
            }
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
    /// geometry is not transposed back correctly the canvas comes out the wrong shape.
    func testHorizontalStitchGrowsSidewaysAndKeepsHeight() throws {
        let pair = SyntheticScreenshot.horizontalPair()
        let sources = [try XCTUnwrap(pair.first.cgImage), try XCTUnwrap(pair.second.cgImage)]

        var options = ScrollStitchPlanner.Options.default
        options.axis = .horizontal
        options.trimFixedRegions = false
        let plan = ScrollStitchPlanner.plan(images: try grays(sources), options: options)

        XCTAssertEqual(plan.axis, .horizontal)
        XCTAssertGreaterThan(plan.canvasSize.width, sources[0].width,
                             "a horizontal stitch did not get wider")
        XCTAssertLessThan(plan.canvasSize.width, sources[0].width + sources[1].width,
                          "no horizontal overlap was removed")
        XCTAssertEqual(plan.canvasSize.height, sources[0].height,
                       "a horizontal stitch changed the height")
        XCTAssertTrue(plan.validate(sourceSizes: sources.map(\.pixelSize)).isEmpty)
    }

    private func recognisedText(in image: UIImage) throws -> String {
        var service = TextRecognitionService()
        service.options.tileHeight = 4000
        service.options.computesCharacterBoxes = false
        return try service.recognize(cgImage: try XCTUnwrap(image.cgImage)).plainText
    }
}
