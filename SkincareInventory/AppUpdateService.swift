import Foundation
import CryptoKit

struct AppUpdateRelease {
    let version: String
    let id: Int
    let assetURL: URL
    let releaseURL: URL
    let expectedSize: Int
    let filename: String
    let checksumURL: URL
    let assetDigest: String?
}

/// A downloaded package and the metadata used to verify it. The installer must
/// copy and independently hash the file again before handing it to roothelper;
/// a URL alone is never sufficient authority to install an arbitrary file.
struct AppUpdatePackage {
    let fileURL: URL
    let sha256: String
    let version: String
    let size: Int
}

enum AppUpdateError: LocalizedError {
    case busy, invalidVersion, invalidRelease, unsafeURL, invalidResponse
    case tooLarge, invalidChecksum, checksumMismatch, invalidPackage

    var errorDescription: String? {
        switch self {
        case .busy: return "正在检查或下载更新，请稍候。"
        case .invalidVersion, .invalidRelease: return "暂时无法确认可用版本，请稍后重试。"
        case .unsafeURL: return "更新地址无法验证，已停止下载。"
        case .invalidResponse: return "更新服务器暂时无法访问，请稍后重试。"
        case .tooLarge: return "更新文件超出允许大小，已停止下载。"
        case .invalidChecksum, .checksumMismatch, .invalidPackage:
            return "更新文件校验失败，请重新下载。"
        }
    }
}

/// Only reads public release files and writes its own cache directory. It never
/// accesses the website's WebKit store, inventory, backups or Documents folder.
final class AppUpdateService {
    static let latestURL = URL(string: "https://api.github.com/repos/Saimilai/skincare-inventory-ios/releases/latest")!
    static let maximumPackageBytes = 64 * 1_024 * 1_024
    private static let repositoryURL = "https://github.com/Saimilai/skincare-inventory-ios"
    private let currentVersion: String
    private let configuration: URLSessionConfiguration
    private let directory: URL
    private var request: BoundedUpdateRequest?
    private var operation: UUID?
    private var cancelCompletion: (() -> Void)?
    var isBusy: Bool { operation != nil }

    init(
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
        configuration: URLSessionConfiguration = .ephemeral,
        directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InventoryUpdates", isDirectory: true)
    ) {
        self.currentVersion = currentVersion
        self.configuration = configuration
        self.directory = directory
    }

    deinit { request?.cancel() }

    /// Public methods and callbacks use the main thread, matching the UIKit UI.
    func check(completion: @escaping (Result<AppUpdateRelease?, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !isBusy else { completion(.failure(AppUpdateError.busy)); return }
        let identifier = UUID()
        operation = identifier
        cancelCompletion = { completion(.failure(URLError(.cancelled))) }
        fetch(Self.latestURL, maximumBytes: 512 * 1_024, assetRedirects: false) { [weak self] result in
            guard let self = self, self.operation == identifier else { return }
            let parsed = result.flatMap { data -> Result<AppUpdateRelease?, Error> in
                Result { try Self.parseRelease(data, currentVersion: self.currentVersion) }
            }
            self.finish()
            completion(parsed)
        }
    }

    func download(
        _ release: AppUpdateRelease,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<AppUpdatePackage, Error>) -> Void
    ) {
        precondition(Thread.isMainThread)
        guard !isBusy else { completion(.failure(AppUpdateError.busy)); return }
        // Revalidate the value at the trust boundary, including callers that
        // constructed a release directly instead of obtaining it from check().
        guard (try? Self.isNewer(release.version, than: currentVersion)) == true,
              release.id > 0,
              release.expectedSize > 0, release.expectedSize <= Self.maximumPackageBytes,
              release.filename == "SkincareInventory-\(release.version)-TrollStore.ipa",
              Self.isReleaseAssetURL(release.assetURL, version: release.version, filename: release.filename),
              Self.isReleaseAssetURL(release.checksumURL, version: release.version, filename: "SHA256SUMS.txt"),
              release.releaseURL.absoluteString == Self.repositoryURL + "/releases/tag/v" + release.version,
              release.assetDigest == nil || Self.isSHA256(release.assetDigest!) else {
            completion(.failure(AppUpdateError.invalidRelease)); return
        }
        let identifier = UUID()
        operation = identifier
        cancelCompletion = { completion(.failure(URLError(.cancelled))) }
        fetch(release.checksumURL, maximumBytes: 128 * 1_024, assetRedirects: true) { [weak self] result in
            guard let self = self, self.operation == identifier else { return }
            let checksum: String
            do {
                checksum = try Self.parseChecksum(result.get(), filename: release.filename)
                if let digest = release.assetDigest, digest != checksum {
                    throw AppUpdateError.checksumMismatch
                }
            } catch {
                self.finish()
                completion(.failure(error))
                return
            }
            self.fetch(
                release.assetURL, maximumBytes: release.expectedSize,
                assetRedirects: true, expectedBytes: release.expectedSize,
                progress: progress
            ) { [weak self] package in
                guard let self = self, self.operation == identifier else { return }
                var createdDirectory: URL?
                let prepared: Result<AppUpdatePackage, Error> = Result {
                    let data = try package.get()
                    guard data.count == release.expectedSize else { throw AppUpdateError.invalidPackage }
                    guard data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw AppUpdateError.invalidPackage }
                    guard Self.sha256(data) == checksum else { throw AppUpdateError.checksumMismatch }
                    let targetDirectory = self.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    createdDirectory = targetDirectory
                    try FileManager.default.createDirectory(
                        at: targetDirectory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: NSNumber(value: 0o700)]
                    )
                    let file = targetDirectory.appendingPathComponent(release.filename, isDirectory: false)
                    try data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: 0o444)], ofItemAtPath: file.path
                    )
                    return AppUpdatePackage(
                        fileURL: file, sha256: checksum, version: release.version, size: data.count
                    )
                }
                if case .failure = prepared, let folder = createdDirectory {
                    try? FileManager.default.removeItem(at: folder)
                }
                self.finish()
                completion(prepared)
            }
        }
    }

    /// Cancellation completes once, including while transitioning between the
    /// checksum and package requests. A late network callback cannot install.
    func cancel() {
        precondition(Thread.isMainThread)
        guard isBusy else { return }
        let completion = cancelCompletion
        operation = nil
        cancelCompletion = nil
        let active = request
        request = nil
        active?.cancel()
        completion?()
    }

    private func finish() {
        request = nil
        operation = nil
        cancelCompletion = nil
    }

    private func fetch(
        _ url: URL, maximumBytes: Int, assetRedirects: Bool,
        expectedBytes: Int? = nil, progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let next = BoundedUpdateRequest(
            url: url, maximumBytes: maximumBytes, assetRedirects: assetRedirects,
            expectedBytes: expectedBytes, configuration: configuration,
            progress: progress, completion: completion
        )
        request = next
        next.start()
    }

    static func isNewer(_ candidate: String, than current: String) throws -> Bool {
        let first = try versionParts(candidate)
        let second = try versionParts(current)
        return second.lexicographicallyPrecedes(first)
    }

    private static func versionParts(_ text: String) throws -> [Int] {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw AppUpdateError.invalidVersion }
        return try parts.map { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  part.count == 1 || part.first != "0", let number = Int(part), number <= 1_000_000 else {
                throw AppUpdateError.invalidVersion
            }
            return number
        }
    }

    static func parseRelease(_ data: Data, currentVersion: String) throws -> AppUpdateRelease? {
        let release = try JSONDecoder().decode(ReleaseJSON.self, from: data)
        guard !release.draft, !release.prerelease, release.id > 0,
              release.tag_name.hasPrefix("v"), release.published_at?.isEmpty == false else {
            throw AppUpdateError.invalidRelease
        }
        let version = String(release.tag_name.dropFirst())
        _ = try versionParts(version)
        guard release.html_url == repositoryURL + "/releases/tag/v" + version,
              let releaseURL = URL(string: release.html_url) else { throw AppUpdateError.unsafeURL }
        guard try isNewer(version, than: currentVersion) else { return nil }
        let filename = "SkincareInventory-\(version)-TrollStore.ipa"
        let packages = release.assets.filter { $0.name == filename }
        let checksums = release.assets.filter { $0.name == "SHA256SUMS.txt" }
        guard packages.count == 1, checksums.count == 1 else { throw AppUpdateError.invalidRelease }
        let asset = packages[0]
        let checksum = checksums[0]
        guard asset.state == "uploaded", checksum.state == "uploaded",
              asset.size > 0, asset.size <= maximumPackageBytes,
              checksum.size > 0, checksum.size <= 128 * 1_024,
              let assetURL = URL(string: asset.browser_download_url),
              let checksumURL = URL(string: checksum.browser_download_url),
              isReleaseAssetURL(assetURL, version: version, filename: filename),
              isReleaseAssetURL(checksumURL, version: version, filename: "SHA256SUMS.txt") else {
            throw AppUpdateError.invalidRelease
        }
        let digest: String?
        if let raw = asset.digest {
            guard raw.hasPrefix("sha256:"), isSHA256(String(raw.dropFirst(7))) else {
                throw AppUpdateError.invalidChecksum
            }
            digest = String(raw.dropFirst(7)).lowercased()
        } else { digest = nil }
        return AppUpdateRelease(
            version: version, id: release.id, assetURL: assetURL, releaseURL: releaseURL,
            expectedSize: asset.size, filename: filename, checksumURL: checksumURL, assetDigest: digest
        )
    }

    static func parseChecksum(_ data: Data, filename: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw AppUpdateError.invalidChecksum }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { throw AppUpdateError.invalidChecksum }
            let hash = String(fields[0]).lowercased()
            var name = String(fields[1])
            if name.hasPrefix("*") { name.removeFirst() }
            guard isSHA256(hash), !name.isEmpty, !name.contains("/"), !name.contains("\\"),
                  !name.hasPrefix("."), values[name] == nil else { throw AppUpdateError.invalidChecksum }
            values[name] = hash
        }
        guard let hash = values[filename] else { throw AppUpdateError.invalidChecksum }
        return hash
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.lowercased().utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isReleaseAssetURL(_ url: URL, version: String, filename: String) -> Bool {
        url.absoluteString == repositoryURL + "/releases/download/v" + version + "/" + filename
    }

    private struct ReleaseJSON: Decodable {
        let id: Int
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let published_at: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int
            let state: String
            let digest: String?
        }
    }
}

/// The response bound is enforced before and during receipt, so a server cannot
/// make an unchecked dataTask completion buffer an unbounded response in RAM.
private final class BoundedUpdateRequest: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let maximumBytes: Int
    private let assetRedirects: Bool
    private let expectedBytes: Int?
    private let configuration: URLSessionConfiguration
    private let progress: ((Double) -> Void)?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var session: URLSession?
    private var data = Data()

    init(
        url: URL, maximumBytes: Int, assetRedirects: Bool, expectedBytes: Int?,
        configuration: URLSessionConfiguration, progress: ((Double) -> Void)?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.assetRedirects = assetRedirects
        self.expectedBytes = expectedBytes
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.progress = progress
        self.completion = completion
    }

    func start() {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Inventory-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue(assetRedirects ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
    }

    func cancel() { finish(.failure(URLError(.cancelled))) }

    private func finish(_ result: Result<Data, Error>) {
        guard let callback = completion else { return }
        completion = nil
        session?.invalidateAndCancel()
        session = nil
        callback(result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard assetRedirects, let target = request.url,
              target.scheme == "https", target.user == nil, target.password == nil,
              target.port == nil || target.port == 443,
              ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(target.host?.lowercased() ?? "") else {
            completionHandler(nil)
            finish(.failure(AppUpdateError.unsafeURL))
            return
        }
        var anonymous = request
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(anonymous)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard completion != nil else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure(AppUpdateError.invalidResponse))
            return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(AppUpdateError.tooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard completion != nil else { return }
        guard chunk.count <= maximumBytes - data.count else {
            finish(.failure(AppUpdateError.tooLarge)); return
        }
        data.append(chunk)
        if let expected = expectedBytes, expected > 0 {
            progress?(min(1, Double(data.count) / Double(expected)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { finish(.failure(error)) }
        else { finish(.success(data)) }
    }
}
