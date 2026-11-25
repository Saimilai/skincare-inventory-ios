import XCTest

final class SkincareInventoryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        waitForHarness()
    }

    private func waitForHarness() {
        let ready = app.buttons["Test confirm"].waitForExistence(timeout: 45)
        if !ready {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Website load failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            print(app.debugDescription)
        }
        XCTAssertTrue(ready, "The genuine website and document-end test harness must load.")
    }

    private func status(_ text: String) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10), text)
    }

    private func tap(_ title: String) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5), title)
        for _ in 0..<4 {
            if button.isHittable { break }
            app.webViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(button.isHittable, title)
        button.tap()
    }

    private func captureDiagnostics(_ title: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = title
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print(app.debugDescription)
    }

    private func cancelShareSheet() {
        let close = app.buttons.matching(NSPredicate(format:"label == 'Close' OR label == '关闭' OR label == 'Cancel' OR label == '取消'")).firstMatch
        let found = close.waitForExistence(timeout: 20)
        if !found { captureDiagnostics("Missing system share sheet") }
        XCTAssertTrue(found, "System activity sheet should have a close control.")
        close.tap()
    }

    func testPersistentStorageSurvivesRelaunchAndBackground() {
        tap("Test import fixture")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["确认"].tap()
        tap("Test inspect inventory")
        status("inventory:模拟器测试面霜")
        tap("Test reload page")
        waitForHarness()
        tap("Test inspect inventory")
        status("inventory:模拟器测试面霜")
        app.terminate()
        app.launch()
        waitForHarness()
        tap("Test inspect inventory")
        status("inventory:模拟器测试面霜")
        XCUIDevice.shared.press(.home)
        app.activate()
        status("inventory:模拟器测试面霜")
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
        XCTAssertEqual(field.value as? String, "fixture")
        // Put the caret after the default value before replacing it. A normal
        // tap can leave UIAlertController's default text selected or move it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
        field.typeText("fixture-edited")
        XCTAssertEqual(field.value as? String, "fixture-edited")
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
        tap("Test import fixture")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["确认"].tap()
        tap("Test download JSON")
        cancelShareSheet()
        tap("Test import empty inventory")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["确认"].tap()
        tap("Test inspect inventory")
        status("inventory:")
        tap("Test restore last JSON export")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["确认"].tap()
        tap("Test inspect inventory")
        status("inventory:模拟器测试面霜")
        tap("Test download XLSX")
        cancelShareSheet()
        status("xlsx:verified-name-stock-cost")
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
        tap("新增物品")
        tap("下一步 · 核对商品")
        let name = app.webViews.textFields["产品名称 *"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Simulator entry cream")
        XCTAssertEqual(name.value as? String, "Simulator entry cream")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["下一步 · 核对价格"].isHittable, "The entry footer must stay above the keyboard.")
        let keyboard = XCTAttachment(screenshot: app.screenshot())
        keyboard.name = "Inventory entry with keyboard"
        keyboard.lifetime = .keepAlways
        add(keyboard)
        // Keep the keyboard layout check above, then leave editing before
        // navigating so XCTest uses the footer's settled screen position.
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == '完成'")).firstMatch
        if done.exists {
            done.tap()
        } else {
            app.webViews.staticTexts["基本信息"].tap()
        }
        tap("下一步 · 核对价格")
        let save = app.buttons["确认并加入库存"]
        if !save.waitForExistence(timeout: 10) {
            captureDiagnostics("Inventory price step did not open")
        }
        tap("确认并加入库存")
        XCTAssertTrue(app.staticTexts["Simulator entry cream"].waitForExistence(timeout:10))
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "Inventory real website"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(app.staticTexts["inventory.error"].exists)
    }
}
