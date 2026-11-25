import Foundation

enum AppConfig {
    static let websiteURL = URL(string: "https://skincare-k-test-20261115.pages.dev/")!
    static let trustedHost = "skincare-k-test-20261115.pages.dev"
    static let bridgeHandlerName = "inventoryFiles"
    static let compatibilityScriptName = "WebCompatibility"
    static let maximumExportFileBytes = 20 * 1_024 * 1_024

    static func isTrusted(_ url: URL?) -> Bool {
        guard let url = url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == trustedHost,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return url.port == nil || url.port == 443
    }
}
