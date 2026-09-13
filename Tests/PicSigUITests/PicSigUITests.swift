import XCTest

final class PicSigUITests: XCTestCase {
    @MainActor func testQuickHomeAndDemoEditor() throws {
        continueAfterFailure = false

        let home = XCUIApplication()
        home.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        home.launch()
        XCTAssertTrue(home.buttons["quick-scroll"].waitForExistence(timeout: 15))
        XCTAssertTrue(home.buttons["create-video"].exists)
        XCTAssertTrue(home.buttons["quick-vertical"].exists)
        XCTAssertTrue(home.buttons["quick-horizontal"].exists)
        attachment("01-Home", app: home)
        home.terminate()

        let editor = XCUIApplication()
        editor.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--demo-editor"]
        editor.launch()
        let export = editor.buttons["open-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 90))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: export)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 120), .completed)
        attachment("02-PrivacyEditor", app: editor)
        editor.buttons["review-masks"].tap()
        attachment("03-PrivacyReview", app: editor)
    }

    @MainActor private func attachment(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
