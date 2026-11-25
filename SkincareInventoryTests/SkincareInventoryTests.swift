import XCTest
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
}
