import XCTest
@testable import PicSigCore

final class EditDocumentTests: XCTestCase {
    private func stroke(_ x: Double) -> Annotation {
        Annotation(tool: .pen, points: [NormalizedPoint(x: x, y: 0.1), NormalizedPoint(x: x + 0.1, y: 0.2)])
    }

    func testUndoRedo() {
        var document = EditDocument()
        XCTAssertFalse(document.canUndo)

        document.add(stroke(0.1))
        document.add(stroke(0.3))
        XCTAssertEqual(document.state.annotations.count, 2)

        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.state.annotations.count, 1)
        XCTAssertTrue(document.canRedo)

        XCTAssertTrue(document.redo())
        XCTAssertEqual(document.state.annotations.count, 2)
        XCTAssertFalse(document.canRedo)
    }

    func testNewChangeClearsRedoStack() {
        var document = EditDocument()
        document.add(stroke(0.1))
        document.undo()
        document.add(stroke(0.5))
        XCTAssertFalse(document.canRedo)
    }

    func testNoOpChangeIsNotRecorded() {
        var document = EditDocument()
        document.add(stroke(0.1))
        XCTAssertFalse(document.apply { _ in })
        XCTAssertTrue(document.undo())
        XCTAssertTrue(document.state.annotations.isEmpty)
    }

    func testPreviewChangeDoesNotTouchHistory() {
        var document = EditDocument()
        document.previewChange { $0.crop = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5) }
        XCTAssertFalse(document.canUndo)
        XCTAssertEqual(document.state.crop.width, 0.5)
    }

    func testUndoLimit() {
        var document = EditDocument(undoLimit: 3)
        for index in 0..<10 { document.add(stroke(Double(index) / 20)) }
        var undone = 0
        while document.undo() { undone += 1 }
        XCTAssertEqual(undone, 3)
    }

    func testRotationWraps() {
        var document = EditDocument()
        for _ in 0..<4 { document.rotate() }
        XCTAssertEqual(document.state.quarterTurns, 0)
        document.rotate(clockwise: false)
        XCTAssertEqual(document.state.quarterTurns, 3)
    }

    func testAutomaticRedactionsAreReplacedButManualOnesSurvive() {
        var document = EditDocument()
        let manual = RedactionItem(box: NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.1),
                                   style: .solid, strength: 1, category: .custom, isManual: true)
        document.add(redaction: manual)
        document.replaceAutomaticRedactions(with: [
            RedactionItem(box: NormalizedRect(x: 0.3, y: 0, width: 0.2, height: 0.1),
                          style: .mosaic, strength: 0.7, category: .phoneNumber)
        ])
        XCTAssertEqual(document.state.redactions.count, 2)

        document.replaceAutomaticRedactions(with: [])
        XCTAssertEqual(document.state.redactions.map(\.id), [manual.id])
    }

    func testUndoLastStrokeSkipsShapes() {
        var document = EditDocument()
        document.add(stroke(0.1))
        document.add(Annotation(tool: .rectangle,
                                points: [NormalizedPoint(x: 0.4, y: 0.4), NormalizedPoint(x: 0.6, y: 0.6)]))
        document.undoLastStroke()
        XCTAssertEqual(document.state.annotations.map(\.tool), [.rectangle])
    }

    func testStateCodingRoundTrip() throws {
        var state = EditState()
        state.annotations = [stroke(0.2)]
        state.watermark = Watermark(text: "内部资料")
        state.canvas = .card
        state.redactions = [RedactionItem(box: .full, style: .mosaic, strength: 0.8, category: .idCard)]

        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(EditState.self, from: data), state)
    }
}

final class AnnotationTests: XCTestCase {
    func testBoundingBox() {
        let annotation = Annotation(tool: .pen, points: [
            NormalizedPoint(x: 0.2, y: 0.5),
            NormalizedPoint(x: 0.6, y: 0.1),
            NormalizedPoint(x: 0.4, y: 0.9)
        ])
        let box = annotation.boundingBox
        XCTAssertEqual(box.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(box.y, 0.1, accuracy: 0.0001)
        XCTAssertEqual(box.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(box.height, 0.8, accuracy: 0.0001)
    }

    func testSimplificationDropsDensePoints() {
        let points = (0..<100).map { NormalizedPoint(x: Double($0) * 0.0001, y: 0.5) }
        let simplified = Annotation(tool: .pen, points: points).simplified(tolerance: 0.001)
        XCTAssertLessThan(simplified.points.count, 20)
        XCTAssertEqual(simplified.points.first, points.first)
        XCTAssertEqual(simplified.points.last, points.last)
    }

    func testShapesAreNotSimplified() {
        let annotation = Annotation(tool: .rectangle,
                                    points: [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 0.5, y: 0.5)])
        XCTAssertEqual(annotation.simplified().points.count, 2)
    }

    func testHitTest() {
        let line = Annotation(tool: .line,
                              points: [NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 0.5, y: 0.5)])
        XCTAssertTrue(line.hitTest(NormalizedPoint(x: 0.11, y: 0.11), tolerance: 0.02))
        XCTAssertFalse(line.hitTest(NormalizedPoint(x: 0.8, y: 0.8), tolerance: 0.02))

        let box = Annotation(tool: .rectangle,
                             points: [NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 0.5, y: 0.5)])
        XCTAssertTrue(box.hitTest(NormalizedPoint(x: 0.3, y: 0.3), tolerance: 0.01))
    }

    func testBadgeNumbering() {
        var state = EditState()
        XCTAssertEqual(state.nextBadgeNumber, 1)
        state.annotations = [Annotation(tool: .numberBadge, points: [.zero], number: 3)]
        XCTAssertEqual(state.nextBadgeNumber, 4)
    }
}

final class ExportTests: XCTestCase {
    func testScaleModes() {
        let size = PixelSize(width: 1200, height: 9000)
        XCTAssertEqual(ExportScale.original.targetSize(for: size), size)
        XCTAssertEqual(ExportScale.fraction(0.5).targetSize(for: size), PixelSize(width: 600, height: 4500))
        XCTAssertEqual(ExportScale.longestEdge(4500).targetSize(for: size), PixelSize(width: 600, height: 4500))
        XCTAssertEqual(ExportScale.longestEdge(20000).targetSize(for: size), size, "never upscales")
    }

    func testShortImageIsASinglePage() {
        XCTAssertEqual(PageSplitter.pages(imageHeight: 1200, options: .init(pageHeight: 4000)), [0..<1200])
    }

    func testPagesCoverTheWholeImage() {
        let options = PageSplitter.Options(pageHeight: 1000, searchWindow: 0, overlap: 0, minPageHeight: 200)
        let pages = PageSplitter.pages(imageHeight: 3500, options: options)
        XCTAssertEqual(pages.first?.lowerBound, 0)
        XCTAssertEqual(pages.last?.upperBound, 3500)
        for (previous, next) in zip(pages, pages.dropFirst()) {
            XCTAssertEqual(previous.upperBound, next.lowerBound)
        }
    }

    func testOverlapRepeatsRows() {
        let options = PageSplitter.Options(pageHeight: 1000, searchWindow: 0, overlap: 50, minPageHeight: 200)
        let pages = PageSplitter.pages(imageHeight: 2500, options: options)
        XCTAssertEqual(pages[1].lowerBound, pages[0].upperBound - 50)
    }

    func testCutMovesToTheQuietestRow() {
        // A busy image with one blank band 30 rows before the ideal cut.
        var activity = [Double](repeating: 20, count: 3000)
        for row in 970..<980 { activity[row] = 0 }
        let options = PageSplitter.Options(pageHeight: 1000, searchWindow: 100, overlap: 0, minPageHeight: 200)
        let pages = PageSplitter.pages(imageHeight: 3000, activity: activity, options: options)
        XCTAssertTrue((970..<980).contains(pages[0].upperBound), "cut inside the blank band")
    }

    func testTailShorterThanMinimumIsMergedIntoTheLastPage() {
        let options = PageSplitter.Options(pageHeight: 1000, searchWindow: 0, overlap: 0, minPageHeight: 300)
        let pages = PageSplitter.pages(imageHeight: 1200, options: options)
        XCTAssertEqual(pages, [0..<1200])
    }
}
