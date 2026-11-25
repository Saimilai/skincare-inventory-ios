import XCTest
import Foundation
@testable import SkincareInventory

private final class UpdateURLProtocol: URLProtocol {
    struct Reply {
        var data = Data()
        var status = 200
        var declaredLength: Int?
        var error: Error?
        var stall = false
    }
    static var reply: ((URLRequest) -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let respond = Self.reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = respond(request)
        if response.stall { return }
        var headers: [String: String] = [:]
        if let length = response.declaredLength { headers["Content-Length"] = String(length) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers
        )!, cacheStoragePolicy: .notAllowed)
        if !response.data.isEmpty { client?.urlProtocol(self, didLoad: response.data) }
        if let error = response.error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

final class AppUpdateServiceTests: XCTestCase {
    private let package = Data([0x50, 0x4b, 0x03, 0x04, 1, 2, 3, 4])
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("InventoryUpdateTest-" + UUID().uuidString, isDirectory: true)
        UpdateURLProtocol.reply = nil
    }

    override func tearDownWithError() throws {
        UpdateURLProtocol.reply = nil
        if let folder = folder, FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private func metadata() -> [String: Any] {
        let prefix = "https://github.com/Saimilai/skincare-inventory-ios/releases/"
        return [
            "id": 42, "tag_name": "v1.0.1", "html_url": prefix + "tag/v1.0.1",
            "draft": false, "prerelease": false, "published_at": "2026-11-25T12:00:00Z",
            "assets": [
                ["name": "SkincareInventory-1.0.1-TrollStore.ipa", "state": "uploaded",
                 "size": package.count, "digest": "sha256:" + AppUpdateService.sha256(package),
                 "browser_download_url": prefix + "download/v1.0.1/SkincareInventory-1.0.1-TrollStore.ipa"],
                ["name": "SHA256SUMS.txt", "state": "uploaded", "size": 120,
                 "browser_download_url": prefix + "download/v1.0.1/SHA256SUMS.txt"]
            ]
        ]
    }

    private func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func release() throws -> AppUpdateRelease {
        try XCTUnwrap(AppUpdateService.parseRelease(encoded(metadata()), currentVersion: "1.0.0"))
    }

    private func service(currentVersion: String = "1.0.0") -> AppUpdateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        return AppUpdateService(currentVersion: currentVersion, configuration: configuration, directory: folder)
    }

    private func checksum(for release: AppUpdateRelease) -> Data {
        Data((AppUpdateService.sha256(package) + "  " + release.filename + "\n").utf8)
    }

    private func assertNoDownloadedFile(file: StaticString = #filePath, line: UInt = #line) {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
        XCTAssertTrue(files.isEmpty, "A rejected or cancelled operation must not leave a package", file: file, line: line)
    }

    func testVersionComparisonIsNumericStableAndRejectsAmbiguousVersions() throws {
        XCTAssertTrue(try AppUpdateService.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertTrue(try AppUpdateService.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertFalse(try AppUpdateService.isNewer("1.0.1", than: "1.0.1"))
        XCTAssertFalse(try AppUpdateService.isNewer("1.0.0", than: "1.0.1"))
        for value in ["1.0", "1.0.1-beta", "1.0.1.4", "01.0.1", "1.-1.0", "1.０.2", "v1.0.2", "999999999999999999.0.0"] {
            XCTAssertThrowsError(try AppUpdateService.isNewer(value, than: "1.0.0"), value)
        }
    }

    func testReleaseParsingBindsExactRepositoryVersionAndAsset() throws {
        let release = try self.release()
        XCTAssertEqual(release.version, "1.0.1")
        XCTAssertEqual(release.id, 42)
        XCTAssertEqual(release.expectedSize, package.count)
        XCTAssertEqual(release.assetDigest, AppUpdateService.sha256(package))
        XCTAssertNil(try AppUpdateService.parseRelease(encoded(metadata()), currentVersion: "1.0.1"))
        XCTAssertNil(try AppUpdateService.parseRelease(encoded(metadata()), currentVersion: "2.0.0"))
    }

    func testReleaseParsingRejectsDraftForeignAndAmbiguousOrOversizedAssets() throws {
        var variants: [[String: Any]] = []
        var altered = metadata(); altered["draft"] = true; variants.append(altered)
        altered = metadata(); altered["prerelease"] = true; variants.append(altered)
        altered = metadata(); altered["id"] = 0; variants.append(altered)
        altered = metadata(); altered["html_url"] = "https://github.com/other/project/releases/tag/v1.0.1"; variants.append(altered)
        altered = metadata()
        var assets = altered["assets"] as! [[String: Any]]
        assets.append(assets[0]); altered["assets"] = assets; variants.append(altered)
        for address in [
            "http://github.com/Saimilai/skincare-inventory-ios/releases/download/v1.0.1/SkincareInventory-1.0.1-TrollStore.ipa",
            "https://github.com.evil.example/Saimilai/skincare-inventory-ios/releases/download/v1.0.1/SkincareInventory-1.0.1-TrollStore.ipa",
            "https://github.com/other/project/releases/download/v1.0.1/SkincareInventory-1.0.1-TrollStore.ipa"
        ] {
            altered = metadata(); assets = altered["assets"] as! [[String: Any]]
            assets[0]["browser_download_url"] = address; altered["assets"] = assets; variants.append(altered)
        }
        altered = metadata(); assets = altered["assets"] as! [[String: Any]]
        assets[0]["size"] = AppUpdateService.maximumPackageBytes + 1
        altered["assets"] = assets; variants.append(altered)
        altered = metadata(); assets = altered["assets"] as! [[String: Any]]
        assets[0]["digest"] = "sha256:bad"; altered["assets"] = assets; variants.append(altered)
        for fixture in variants {
            XCTAssertThrowsError(try AppUpdateService.parseRelease(encoded(fixture), currentVersion: "1.0.0"))
        }
    }

    func testChecksumRejectsMissingDuplicateMalformedAndPathEntries() throws {
        let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(AppUpdateService.sha256(Data("abc".utf8)), hash)
        XCTAssertEqual(try AppUpdateService.parseChecksum(Data((hash.uppercased() + " *app.ipa\r\n").utf8), filename: "app.ipa"), hash)
        for value in ["", hash + "  other.ipa", "bad  app.ipa", hash + "  app.ipa\n" + hash + "  app.ipa", hash + "  ../app.ipa", hash + "  app.ipa extra"] {
            XCTAssertThrowsError(try AppUpdateService.parseChecksum(Data(value.utf8), filename: "app.ipa"))
        }
    }

    @MainActor
    func testCheckUsesPublicMetadataAndReportsNewerVersionOnMainThread() throws {
        let bytes = try encoded(metadata())
        UpdateURLProtocol.reply = { request in
            XCTAssertEqual(request.url, AppUpdateService.latestURL)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return .init(data: bytes)
        }
        let done = expectation(description: "checked")
        let service = self.service()
        service.check { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get()?.version, "1.0.1")
            XCTAssertFalse(service.isBusy)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testHTTPFailureAndMalformedMetadataNeverReportUpdate() {
        UpdateURLProtocol.reply = { _ in .init(status: 503) }
        let done = expectation(description: "http failed")
        let service = self.service()
        service.check { result in
            if case .success = result { XCTFail("HTTP error was accepted") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        UpdateURLProtocol.reply = { _ in .init(data: Data("not JSON".utf8)) }
        let malformed = expectation(description: "malformed failed")
        service.check { result in
            if case .success = result { XCTFail("Malformed metadata was accepted") }
            malformed.fulfill()
        }
        wait(for: [malformed], timeout: 5)
        assertNoDownloadedFile()
    }

    @MainActor
    func testDownloadChecksBothDigestsBeforeWritingLocalPackage() throws {
        let release = try self.release()
        let package = self.package
        let sums = checksum(for: release)
        UpdateURLProtocol.reply = { request in
            if request.url == release.checksumURL { return .init(data: sums) }
            XCTAssertEqual(request.url, release.assetURL)
            return .init(data: package)
        }
        let done = expectation(description: "verified package")
        let service = self.service()
        service.download(release, progress: { value in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue((0...1).contains(value))
        }) { result in
            do {
                let verified = try result.get()
                let file = verified.fileURL
                XCTAssertTrue(file.isFileURL)
                XCTAssertEqual(try Data(contentsOf: file), package)
                XCTAssertEqual(file.lastPathComponent, release.filename)
                XCTAssertEqual(verified.sha256, AppUpdateService.sha256(package))
                XCTAssertEqual(verified.version, release.version)
                XCTAssertEqual(verified.size, package.count)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o444)
                XCTAssertTrue(file.path.hasPrefix(self.folder.path + "/"))
                service.cancel()
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Cancelling after completion must preserve the file being handed to TrollStore")
            } catch { XCTFail("Expected a verified package: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testChangedPackageBytesFailWithoutLeavingDownloadedFile() throws {
        let release = try self.release()
        let sums = checksum(for: release)
        var changed = package; changed[7] ^= 0xff
        UpdateURLProtocol.reply = { request in
            .init(data: request.url == release.checksumURL ? sums : changed)
        }
        let done = expectation(description: "digest failed")
        let service = self.service()
        service.download(release, progress: { _ in }) { result in
            if case .success = result { XCTFail("Modified package was accepted") }
            self.assertNoDownloadedFile()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testConflictingChecksumNeverStartsPackageDownload() throws {
        let release = try self.release()
        let wrong = Data((String(repeating: "0", count: 64) + "  " + release.filename).utf8)
        UpdateURLProtocol.reply = { request in
            XCTAssertEqual(request.url, release.checksumURL, "Digest disagreement must stop before requesting the IPA")
            return .init(data: wrong)
        }
        let done = expectation(description: "manifest disagreement")
        let service = self.service()
        service.download(release, progress: { _ in }) { result in
            if case .success = result { XCTFail("Conflicting manifest was accepted") }
            self.assertNoDownloadedFile()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    @MainActor
    func testInterruptedOrOversizedResponsesCannotProduceInstallableFile() throws {
        let release = try self.release()
        let sums = checksum(for: release)
        let package = self.package
        let service = self.service()
        for oversized in [false, true] {
            UpdateURLProtocol.reply = { request in
                if request.url == release.checksumURL { return .init(data: sums) }
                if oversized { return .init(data: package + package) }
                return .init(data: Data(package.prefix(4)), error: URLError(.networkConnectionLost))
            }
            let done = expectation(description: oversized ? "size failed" : "interrupted failed")
            service.download(release, progress: { _ in }) { result in
                if case .success = result { XCTFail("Incomplete or oversized bytes were accepted") }
                self.assertNoDownloadedFile()
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
    }

    @MainActor
    func testCancellationCompletesOnceAndRejectsParallelCheck() throws {
        let started = expectation(description: "started")
        UpdateURLProtocol.reply = { _ in
            started.fulfill()
            return .init(stall: true)
        }
        let done = expectation(description: "cancelled")
        let service = self.service()
        var completions = 0
        service.check { result in
            completions += 1
            switch result {
            case .success: XCTFail("A cancelled check reported success")
            case .failure(let error): XCTAssertEqual((error as? URLError)?.code, .cancelled)
            }
            done.fulfill()
        }
        service.check { result in
            if case .success = result { XCTFail("A parallel check was accepted") }
        }
        wait(for: [started], timeout: 5)
        service.cancel()
        service.cancel()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(service.isBusy)
        assertNoDownloadedFile()

        let release = try self.release()
        let sums = checksum(for: release)
        let packageStarted = expectation(description: "package started")
        UpdateURLProtocol.reply = { request in
            if request.url == release.checksumURL { return .init(data: sums) }
            packageStarted.fulfill()
            return .init(stall: true)
        }
        let downloadCancelled = expectation(description: "download cancelled")
        var downloadCompletions = 0
        service.download(release, progress: { _ in }) { result in
            downloadCompletions += 1
            switch result {
            case .success: XCTFail("A cancelled download reported a ready-to-install file")
            case .failure(let error): XCTAssertEqual((error as? URLError)?.code, .cancelled)
            }
            downloadCancelled.fulfill()
        }
        wait(for: [packageStarted], timeout: 5)
        service.cancel()
        service.cancel()
        wait(for: [downloadCancelled], timeout: 5)
        XCTAssertEqual(downloadCompletions, 1)
        XCTAssertFalse(service.isBusy)
        assertNoDownloadedFile()
    }

    @MainActor
    func testDirectDownloadRejectsDowngradeAndInvalidReleaseWithoutNetwork() throws {
        let original = try release()
        UpdateURLProtocol.reply = { _ in
            XCTFail("An invalid or older release must not reach the network")
            return .init(status: 500)
        }
        let service = self.service(currentVersion: "1.0.1")
        let done = expectation(description: "downgrade refused")
        service.download(original, progress: { _ in }) { result in
            if case .success = result { XCTFail("A same-version package was accepted") }
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        let invalid = AppUpdateRelease(
            version: original.version, id: 0, assetURL: original.assetURL,
            releaseURL: original.releaseURL, expectedSize: original.expectedSize,
            filename: original.filename, checksumURL: original.checksumURL, assetDigest: original.assetDigest
        )
        let newService = self.service()
        let rejected = expectation(description: "invalid id refused")
        newService.download(invalid, progress: { _ in }) { result in
            if case .success = result { XCTFail("An invalid release identifier was accepted") }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)
        assertNoDownloadedFile()
    }
}
