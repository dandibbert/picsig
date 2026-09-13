import XCTest

final class PicSigUITests: XCTestCase {
    @MainActor func testCanvasTextRedactionAndReeditableAnnotation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--demo-editor"]
        app.launch()
        let canvas = app.scrollViews["editor-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 90))
        XCTAssertTrue(app.buttons["open-export"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["review-masks"].exists)
        attachment("01-Editor-NoReviewStep", app: app)

        app.buttons["text-redaction"].tap()
        let target = app.buttons["canvas-text-target-0"]
        XCTAssertTrue(target.waitForExistence(timeout: 120))
        XCTAssertFalse(app.navigationBars["文字打码"].exists, "Text redaction must stay ON the image, not open a list")
        let count = app.staticTexts["selection-count"]
        target.tap()
        XCTAssertTrue(count.label.contains("1 处打码"), count.label)
        attachment("02-TapActualImageText", app: app)
        target.tap()
        XCTAssertTrue(count.label.contains("0 处打码"), count.label)
        target.tap()
        app.buttons["撤销"].tap()
        XCTAssertTrue(count.label.contains("0 处打码"), count.label)

        app.buttons["tool-text"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).tap()
        let field = app.descendants(matching: .any)["annotation-text-input"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Editable note")
        app.buttons["save-annotation-text"].tap()
        let annotation = app.buttons["canvas-annotation-0"]
        XCTAssertTrue(annotation.waitForExistence(timeout: 10))
        XCTAssertTrue(count.label.contains("1 个标注"), count.label)
        let oldFrame = annotation.frame
        let start = annotation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 35, dy: 25)))
        XCTAssertGreaterThan(annotation.frame.minX - oldFrame.minX, 15, "Existing annotation must move, not draw a new one")
        app.buttons["edit-selected-text"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(" revised")
        attachment("03-NativeTextEditing", app: app)
        app.buttons["save-annotation-text"].tap()
        XCTAssertTrue(count.label.contains("1 个标注"), "Editing must not append a duplicate")
        attachment("04-EditableAnnotationHandles", app: app)

        app.buttons["open-export"].tap()
        XCTAssertTrue(app.buttons["save-export"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.switches["我已检查画面，了解自动识别可能遗漏"].exists)
        attachment("05-DirectExport", app: app)
    }

    @MainActor func testHomeHasDirectImportNotProjectCreation() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["quick-scroll"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["quick-horizontal"].exists)
        XCTAssertFalse(app.textFields["项目名称"].exists)
        attachment("00-Home", app: app)
    }
    @MainActor private func attachment(_ name: String, app: XCUIApplication) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
}
