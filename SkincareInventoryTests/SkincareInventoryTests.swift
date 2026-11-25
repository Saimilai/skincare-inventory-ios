import XCTest
import UIKit
import WebKit
@testable import SkincareInventory

final class SkincareInventoryTests: XCTestCase {
    func testOnlyExactHTTPSOriginIsTrusted() {
        XCTAssertTrue(AppConfig.isTrusted(URL(string: "https://skincare-k-test-20261115.pages.dev/")))
        XCTAssertTrue(AppConfig.isTrusted(URL(string: "https://skincare-k-test-20261115.pages.dev:443/?v=2")))
        for address in [
            "http://skincare-k-test-20261115.pages.dev/",
            "https://skincare-k-test-20261115.pages.dev.evil.example/",
            "https://user@skincare-k-test-20261115.pages.dev/",
            "https://skincare-k-test-20261115.pages.dev:444/",
            "file:///tmp/backup.json", "about:blank"
        ] { XCTAssertFalse(AppConfig.isTrusted(URL(string: address)), address) }
        XCTAssertFalse(AppConfig.isTrusted(nil))
    }

    func testJSONBytesAndChineseFilenameSurviveValidation() throws {
        let original = Data("{\"name\":\"虚构面霜\",\"logs\":[]}".utf8)
        let result = try FileShareCoordinator.validate(filename: "库存备份.json", mimeType: "application/json", base64Data: original.base64EncodedString())
        XCTAssertEqual(result, original)
    }

    func testSpreadsheetBytesSurviveValidation() throws {
        let original = Data([0x50, 0x4b, 0x03, 0x04, 0, 255, 1])
        XCTAssertEqual(try FileShareCoordinator.validate(filename: "库存.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", base64Data: original.base64EncodedString()), original)
    }

    func testRejectsPathsMismatchedTypesAndMalformedFiles() {
        let base64 = Data("{}".utf8).base64EncodedString()
        for filename in ["../backup.json", "/backup.json", "a\\b.json", ".hidden.json", "x:y.json", "a\n.json", " backup.json", "backup.json ", "backup.exe", "", String(repeating:"中",count:90)+".json"] {
            XCTAssertThrowsError(try FileShareCoordinator.validate(filename: filename, mimeType:"application/json", base64Data:base64), filename)
        }
        XCTAssertThrowsError(try FileShareCoordinator.validate(filename:"backup.xlsx", mimeType:"application/json", base64Data:base64))
        XCTAssertThrowsError(try FileShareCoordinator.validate(filename:"backup.json", mimeType:"application/json", base64Data:""))
        XCTAssertThrowsError(try FileShareCoordinator.validate(filename:"backup.json", mimeType:"application/json", base64Data:"$invalid"))
    }

    func testRejectsOversizedExport() {
        let oversized = Data(repeating:65,count:AppConfig.maximumExportFileBytes+1).base64EncodedString()
        XCTAssertThrowsError(try FileShareCoordinator.validate(filename:"backup.json", mimeType:"application/json", base64Data:oversized))
    }

    @MainActor
    func testNetworkFailureShowsErrorAndRetryPreservesPersistentStore() throws {
        let controller = InventoryViewController()
        controller.loadViewIfNeeded()
        let webView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        webView.stopLoading()
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        let store = webView.configuration.websiteDataStore
        XCTAssertTrue(store.isPersistent)
        XCTAssertTrue(store === WKWebsiteDataStore.default())

        let delegate = try XCTUnwrap(webView.navigationDelegate)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        delegate.webView?(webView, didFailProvisionalNavigation: nil, withError: error)

        let message: UILabel = try XCTUnwrap(findView("inventory.error", in: controller.view))
        let retry: UIButton = try XCTUnwrap(findView("inventory.retry", in: controller.view))
        let loading: UILabel = try XCTUnwrap(findView("inventory.loading", in: controller.view))
        XCTAssertTrue(isVisible(message))
        XCTAssertTrue(isVisible(retry))
        XCTAssertFalse(isVisible(loading))
        XCTAssertFalse(message.text?.isEmpty ?? true)

        retry.sendActions(for: .touchUpInside)

        XCTAssertFalse(isVisible(message), "Retry should replace the error overlay with loading UI.")
        XCTAssertTrue(isVisible(loading))
        XCTAssertTrue(webView.configuration.websiteDataStore === store)
        XCTAssertTrue(webView.configuration.websiteDataStore.isPersistent)
    }

    @MainActor
    func testTerminatedWebContentProcessShowsRecoveryAndAllowsRetry() throws {
        let controller = InventoryViewController()
        controller.loadViewIfNeeded()
        let webView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        webView.stopLoading()
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        let store = webView.configuration.websiteDataStore
        let delegate = try XCTUnwrap(webView.navigationDelegate)
        delegate.webViewWebContentProcessDidTerminate?(webView)

        let message: UILabel = try XCTUnwrap(findView("inventory.error", in: controller.view))
        let retry: UIButton = try XCTUnwrap(findView("inventory.retry", in: controller.view))
        let resume: UIButton = try XCTUnwrap(findView("inventory.continue", in: controller.view))
        let loading: UILabel = try XCTUnwrap(findView("inventory.loading", in: controller.view))
        XCTAssertTrue(isVisible(message))
        XCTAssertTrue(isVisible(retry))
        XCTAssertFalse(isVisible(resume), "A terminated process cannot resume its previous live page.")
        XCTAssertFalse(isVisible(loading))
        XCTAssertFalse(message.text?.isEmpty ?? true)

        retry.sendActions(for: .touchUpInside)

        XCTAssertFalse(isVisible(message))
        XCTAssertTrue(isVisible(loading))
        XCTAssertTrue(webView.configuration.websiteDataStore === store)
        XCTAssertTrue(store === WKWebsiteDataStore.default())
        XCTAssertTrue(store.isPersistent)
    }

    @MainActor
    private func findView<T: UIView>(_ identifier: String, in root: UIView) -> T? {
        if root.accessibilityIdentifier == identifier, let match = root as? T {
            return match
        }
        for child in root.subviews {
            if let match: T = findView(identifier, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private func isVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let ancestor = current {
            if ancestor.isHidden || ancestor.alpha <= 0.01 { return false }
            current = ancestor.superview
        }
        return true
    }
}
