import XCTest

final class SkincareInventoryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["Test confirm"].waitForExistence(timeout: 45), "The genuine website and document-end test harness must load.")
    }

    private func status(_ text: String) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10), text)
    }

    private func tap(_ title: String) {
        let button = app.buttons[title]
        if !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 5), title)
        button.tap()
    }

    private func cancelShareSheet() {
        let close = app.buttons.matching(NSPredicate(format:"label == 'Close' OR label == '关闭' OR label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "System activity sheet should have a close control.")
        close.tap()
    }

    func testPersistentStorageSurvivesRelaunchAndBackground() {
        tap("Test persist fixture")
        status("persisted:模拟器测试面霜")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Test read persisted fixture"].waitForExistence(timeout:45))
        tap("Test read persisted fixture")
        status("persisted:模拟器测试面霜")
        XCUIDevice.shared.press(.home)
        app.activate()
        status("persisted:模拟器测试面霜")
    }

    func testConfirmAndPromptCompletionAndCancellation() {
        tap("Test confirm")
        app.alerts.buttons["取消"].tap()
        status("confirm:false")
        tap("Test confirm")
        app.alerts.buttons["确认"].tap()
        status("confirm:true")
        tap("Test prompt")
        app.alerts.buttons["取消"].tap()
        status("prompt:null")
        tap("Test prompt")
        let field=app.alerts.textFields.firstMatch
        field.tap()
        field.typeText("-edited")
        app.alerts.buttons["确认"].tap()
        status("prompt:fixture-edited")
    }

    func testJSONSharingCancelReturnsAbortAndDoesNotReopen() {
        tap("Test share JSON")
        cancelShareSheet()
        status("share:AbortError")
        XCTAssertTrue(app.buttons["Test share JSON"].isHittable)
        tap("Test share JSON")
        cancelShareSheet()
        status("share:AbortError")
    }

    func testJSONAndExcelBlobDownloadsReachSystemShare() {
        tap("Test download JSON")
        cancelShareSheet()
        tap("Test download XLSX")
        cancelShareSheet()
    }

    func testRealImportValidationAndCancellation() {
        tap("Test import fixture")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:10))
        app.alerts.buttons["取消"].tap()
        tap("Test import fixture")
        app.alerts.buttons["确认"].tap()
        tap("Test inspect inventory")
        status("inventory:模拟器测试面霜")
        tap("Test invalid import")
        status("invalid-import:stock=1")
        tap("Test inspect inventory")
        status("inventory:模拟器测试面霜")
    }

    func testWebsiteLayoutWithoutTestOverlay() {
        tap("Test hide harness")
        XCTAssertTrue(app.webViews.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["库存清单"].waitForExistence(timeout:10))
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "Inventory real website"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(app.staticTexts["inventory.error"].exists)
    }
}
