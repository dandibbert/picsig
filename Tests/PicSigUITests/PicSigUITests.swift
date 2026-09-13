import XCTest

final class PicSigUITests: XCTestCase {
    @MainActor func testHomeAndDemoEditor() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["create-scroll"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["create-video"].exists)
        attachment("01-Home", app: app)
        let demo = app.buttons["open-demo"]
        for _ in 0..<5 where !demo.isHittable { app.swipeUp() }
        XCTAssertTrue(demo.waitForExistence(timeout: 5)); demo.tap()
        let next = app.buttons["enter-editor"]
        XCTAssertTrue(next.waitForExistence(timeout: 60))
        attachment("02-Composer", app: app)
        next.tap()
        let export = app.buttons["open-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 90))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: export)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 120), .completed)
        attachment("03-PrivacyEditor", app: app)
        app.buttons["review-masks"].tap()
        attachment("04-PrivacyReview", app: app)
    }
    @MainActor private func attachment(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
