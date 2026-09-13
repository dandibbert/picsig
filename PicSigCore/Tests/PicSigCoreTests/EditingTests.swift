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

    func testUpdatingAnnotationIsOneUndoStep() {
        var document = EditDocument()
        let mark = Annotation(tool: .text, points: [NormalizedPoint(x: 0.2, y: 0.2)], text: "hi")
        document.add(mark)
        XCTAssertTrue(document.updateAnnotation(id: mark.id) { $0.text = "hello"; $0.fontName = "Courier"; $0.lineWidth = 0.02 })
        XCTAssertEqual(document.state.annotations.first?.text, "hello")
        XCTAssertEqual(document.state.annotations.first?.fontName, "Courier")
        XCTAssertFalse(document.updateAnnotation(id: UUID()) { $0.text = "x" }, "unknown ids are rejected")
        XCTAssertFalse(document.updateAnnotation(id: mark.id) { _ in }, "a no-op does not fill the stack")
        document.undo()
        XCTAssertEqual(document.state.annotations.first?.text, "hi")
        XCTAssertNil(document.state.annotations.first?.fontName)
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

/// The canvas → base space conversion is what keeps a second crop from jumping,
/// so every combination of crop, rotation and mirroring is pinned down here.
final class CanvasSpaceTests: XCTestCase {
    private func assertRect(_ rect: NormalizedRect,
                            _ expected: NormalizedRect,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(rect.x, expected.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(rect.y, expected.y, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.0001, file: file, line: line)
    }

    func testUntouchedStateIsIdentity() {
        let rect = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1)
        assertRect(EditState().baseSpaceRect(rect), rect)
    }

    func testSecondCropIsRelativeToTheFirst() {
        var state = EditState()
        state.crop = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

        // Selecting the whole canvas must reproduce the existing crop …
        assertRect(state.baseSpaceRect(.full), state.crop)
        // … and selecting its top-left quarter must land inside it.
        assertRect(state.baseSpaceRect(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)),
                   NormalizedRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))
    }

    func testClockwiseTurnMovesTopLeftOfCanvasToBottomLeftOfSource() {
        var state = EditState()
        state.quarterTurns = 1
        // A wide strip at the top of the rotated view is a tall strip up the left
        // hand side of the original.
        assertRect(state.baseSpaceRect(NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.1)),
                   NormalizedRect(x: 0, y: 0.8, width: 0.1, height: 0.2))
    }

    func testAllTurnsMapTheCanvasOntoTheWholeSource() {
        for turns in 0..<4 {
            var state = EditState()
            state.quarterTurns = turns
            assertRect(state.baseSpaceRect(.full), .full)
        }
    }

    func testMirroringFlipsHorizontally() {
        var state = EditState()
        state.isMirrored = true
        assertRect(state.baseSpaceRect(NormalizedRect(x: 0, y: 0.4, width: 0.2, height: 0.2)),
                   NormalizedRect(x: 0.8, y: 0.4, width: 0.2, height: 0.2))
    }

    func testMirroringIsUndoneAfterRotation() {
        var state = EditState()
        state.quarterTurns = 1
        state.isMirrored = true
        // Undo the turn first: (0,0)-(0.2,0.1) becomes x 0…0.1, y 0.8…1.
        // Then unmirror, which moves it to the right hand side.
        assertRect(state.baseSpaceRect(NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.1)),
                   NormalizedRect(x: 0.9, y: 0.8, width: 0.1, height: 0.2))
    }

    func testCropAndRotationCombine() {
        var state = EditState()
        state.crop = NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5)
        state.quarterTurns = 2
        assertRect(state.baseSpaceRect(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)),
                   NormalizedRect(x: 0.5, y: 0.75, width: 0.5, height: 0.25))
    }

    func testCanvasSizeFollowsCropAndRotation() {
        var state = EditState()
        let source = PixelSize(width: 1200, height: 8000)
        XCTAssertEqual(state.canvasSize(for: source), source)

        state.crop = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.25)
        XCTAssertEqual(state.canvasSize(for: source), PixelSize(width: 600, height: 2000))

        state.quarterTurns = 1
        XCTAssertEqual(state.canvasSize(for: source), PixelSize(width: 2000, height: 600))

        state.quarterTurns = 2
        XCTAssertEqual(state.canvasSize(for: source), PixelSize(width: 600, height: 2000))
    }

    func testCanvasSizeOfEmptySourceIsEmpty() {
        XCTAssertEqual(EditState().canvasSize(for: .zero), .zero)
    }

    /// `canvasSpacePoint` is the inverse used to move marks when the geometry
    /// changes, so a round trip has to come back to where it started for every
    /// combination — an asymmetry here would drift marks a little on each edit.
    func testCanvasSpacePointIsTheInverseOfBaseSpacePoint() {
        let probes = [(0.0, 0.0), (1.0, 1.0), (0.13, 0.77), (0.5, 0.5), (0.9, 0.05)]
        for turns in 0..<4 {
            for mirrored in [false, true] {
                for crop in [NormalizedRect.full,
                             NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)] {
                    var state = EditState()
                    state.quarterTurns = turns
                    state.isMirrored = mirrored
                    state.crop = crop

                    for (x, y) in probes {
                        let base = state.baseSpacePoint(x: x, y: y)
                        let back = state.canvasSpacePoint(x: base.x, y: base.y)
                        XCTAssertEqual(back.x, x, accuracy: 0.0001,
                                       "turns \(turns) mirrored \(mirrored) crop \(crop)")
                        XCTAssertEqual(back.y, y, accuracy: 0.0001,
                                       "turns \(turns) mirrored \(mirrored) crop \(crop)")
                    }
                }
            }
        }
    }
}

/// Cropping or rotating changes what canvas space means, and marks are stored in
/// canvas space — so without remapping, a mask silently stops covering the thing
/// it was drawn over. These tests pin the mark down to the same content.
final class MarkRemappingTests: XCTestCase {
    private func mask(_ box: NormalizedRect) -> RedactionItem {
        RedactionItem(box: box, style: .mosaic, strength: 0.8, category: .custom, isManual: true)
    }

    func testMaskStaysOnTheSameContentAfterRotation() {
        var document = EditDocument()
        // Covers the top-left corner of the unrotated image.
        document.add(redaction: mask(NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.1)))
        document.rotate()

        // One clockwise turn moves the source's top-left corner to the top-right.
        let box = document.state.redactions[0].box
        XCTAssertEqual(box.x, 0.9, accuracy: 0.0001)
        XCTAssertEqual(box.y, 0, accuracy: 0.0001)
        XCTAssertEqual(box.width, 0.1, accuracy: 0.0001)
        XCTAssertEqual(box.height, 0.2, accuracy: 0.0001)
    }

    func testAnnotationStaysOnTheSameContentAfterMirroring() {
        var document = EditDocument()
        document.add(Annotation(tool: .line, points: [NormalizedPoint(x: 0.1, y: 0.4),
                                                     NormalizedPoint(x: 0.3, y: 0.4)]))
        document.mirror()

        let points = document.state.annotations[0].points
        XCTAssertEqual(points[0].x, 0.9, accuracy: 0.0001)
        XCTAssertEqual(points[1].x, 0.7, accuracy: 0.0001)
        XCTAssertEqual(points[0].y, 0.4, accuracy: 0.0001)
    }

    func testCroppingRescalesMarksIntoTheNewCanvas() {
        var document = EditDocument()
        // A mask over the middle of the image.
        document.add(redaction: mask(NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))
        // Crop to the centre half; the mask now fills the middle of a smaller canvas.
        document.setCrop(NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))

        let box = document.state.redactions[0].box
        XCTAssertEqual(box.x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(box.y, 0.3, accuracy: 0.0001)
        XCTAssertEqual(box.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(box.height, 0.4, accuracy: 0.0001)
    }

    func testMaskCroppedCompletelyAwayIsDropped() {
        var document = EditDocument()
        document.add(redaction: mask(NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)))
        document.setCrop(NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertTrue(document.state.redactions.isEmpty)
    }

    func testRoundTripThroughRotationRestoresTheOriginalBox() {
        let original = NormalizedRect(x: 0.15, y: 0.6, width: 0.2, height: 0.05)
        var document = EditDocument()
        document.add(redaction: mask(original))
        for _ in 0..<4 { document.rotate() }

        let box = document.state.redactions[0].box
        XCTAssertEqual(box.x, original.x, accuracy: 0.0001)
        XCTAssertEqual(box.y, original.y, accuracy: 0.0001)
        XCTAssertEqual(box.width, original.width, accuracy: 0.0001)
        XCTAssertEqual(box.height, original.height, accuracy: 0.0001)
    }

    /// The geometry change and the mark remap must be one undo step, or the first
    /// Undo tap lands on a state the user never saw: marks moved back, image still
    /// rotated.
    func testGeometryChangeIsASingleUndoStep() {
        var document = EditDocument()
        document.add(redaction: mask(NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.1)))
        let before = document.state

        document.rotate()
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.state, before)
    }

    /// Clearing the automatic masks alongside a crop is what the workbench does, and
    /// it also has to stay inside the one step.
    func testGeometryChangeCombinedWithClearingIsStillOneStep() {
        var document = EditDocument()
        document.add(redaction: mask(NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.1)))
        document.replaceAutomaticRedactions(with: [
            RedactionItem(box: NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1),
                          style: .mosaic, strength: 0.7, category: .phoneNumber)
        ])
        let before = document.state

        document.applyGeometryChange { state in
            state.quarterTurns = 1
            state.redactions.removeAll { !$0.isManual }
        }
        XCTAssertEqual(document.state.redactions.count, 1)
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.state, before)
    }

    func testNonGeometryStateIsLeftAlone() {
        var document = EditDocument()
        document.add(Annotation(tool: .pen, points: [NormalizedPoint(x: 0.2, y: 0.2)]))
        let annotations = document.state.annotations
        // Setting the same crop again is a no-op and must not move anything.
        XCTAssertFalse(document.setCropReturningChange(.full))
        XCTAssertEqual(document.state.annotations, annotations)
    }
}

private extension EditDocument {
    mutating func setCropReturningChange(_ crop: NormalizedRect) -> Bool {
        applyGeometryChange { $0.crop = crop.clampedToUnitSpace() }
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
