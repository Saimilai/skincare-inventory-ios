import UIKit
import WebKit

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

final class InventoryViewController: UIViewController {
    private var webView: WKWebView!
    private let loadingOverlay = UIView()
    private let errorOverlay = UIView()
    private let errorMessage = UILabel()
    private let retryButton = UIButton(type: .system)
    private let continueButton = UIButton(type: .system)
    private let banner = UILabel()
    private var bannerDismissal: DispatchWorkItem?
    private var hasLoadedPage = false
    private var compatibilityScriptAvailable = false
    private var navigationGeneration = 0
    private lazy var fileShareCoordinator = FileShareCoordinator(presenter: self)
    private let backgroundColor = UIColor(red: 9 / 255, green: 11 / 255, blue: 10 / 255, alpha: 1)

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = backgroundColor
        overrideUserInterfaceStyle = .dark
        configureWebView()
        configureOverlays()
        if compatibilityScriptAvailable {
            loadWebsite()
        } else {
            showFailure("应用文件不完整，请重新安装此 IPA。")
            retryButton.isHidden = true
        }
    }

    deinit {
        bannerDismissal?.cancel()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: AppConfig.bridgeHandlerName)
    }

    private func configureWebView() {
        let contentController = WKUserContentController()
        contentController.add(
            WeakScriptMessageHandler(target: self),
            name: AppConfig.bridgeHandlerName
        )
        if let scriptURL = Bundle.main.url(
            forResource: AppConfig.compatibilityScriptName,
            withExtension: "js"
        ), let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
            contentController.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            compatibilityScriptAvailable = true
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
           let harnessURL = Bundle.main.url(forResource: "UITestHarness", withExtension: "js"),
           let harness = try? String(contentsOf: harnessURL, encoding: .utf8) {
            contentController.addUserScript(WKUserScript(
                source: harness,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        #endif

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = backgroundColor
        webView.scrollView.backgroundColor = backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.allowsBackForwardNavigationGestures = false
        webView.accessibilityIdentifier = "inventory.webView"
        view.addSubview(webView)
        // The website already accounts for env(safe-area-inset-*).
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureOverlays() {
        for overlay in [loadingOverlay, errorOverlay] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.backgroundColor = backgroundColor
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        let loadingLabel = UILabel()
        loadingLabel.text = "正在打开库存手记…"
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.font = .preferredFont(forTextStyle: .body)
        loadingLabel.adjustsFontForContentSizeCategory = true
        loadingLabel.accessibilityIdentifier = "inventory.loading"
        let loadingStack = UIStackView(arrangedSubviews: [spinner, loadingLabel])
        loadingStack.axis = .vertical
        loadingStack.alignment = .center
        loadingStack.spacing = 20
        addCentered(loadingStack, to: loadingOverlay)

        let title = UILabel()
        title.text = "暂时无法打开库存手记"
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.numberOfLines = 0
        errorMessage.font = .preferredFont(forTextStyle: .body)
        errorMessage.adjustsFontForContentSizeCategory = true
        errorMessage.textColor = .secondaryLabel
        errorMessage.textAlignment = .center
        errorMessage.numberOfLines = 0
        errorMessage.accessibilityIdentifier = "inventory.error"
        retryButton.setTitle("重试", for: .normal)
        retryButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retryButton.accessibilityIdentifier = "inventory.retry"
        retryButton.addTarget(self, action: #selector(retryWebsite), for: .touchUpInside)
        continueButton.setTitle("返回当前页面", for: .normal)
        continueButton.accessibilityIdentifier = "inventory.continue"
        continueButton.addTarget(self, action: #selector(returnToPage), for: .touchUpInside)
        let errorStack = UIStackView(arrangedSubviews: [title, errorMessage, retryButton, continueButton])
        errorStack.axis = .vertical
        errorStack.alignment = .fill
        errorStack.spacing = 18
        addCentered(errorStack, to: errorOverlay)
        errorOverlay.isHidden = true

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.backgroundColor = UIColor(red: 0.35, green: 0.12, blue: 0.12, alpha: 0.98)
        banner.textColor = .white
        banner.font = .preferredFont(forTextStyle: .subheadline)
        banner.adjustsFontForContentSizeCategory = true
        banner.numberOfLines = 0
        banner.textAlignment = .center
        banner.layer.cornerRadius = 8
        banner.clipsToBounds = true
        banner.accessibilityIdentifier = "inventory.notice"
        banner.isHidden = true
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    private func addCentered(_ stack: UIStackView, to parent: UIView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        ])
    }

    private func loadWebsite() {
        errorOverlay.isHidden = true
        loadingOverlay.isHidden = hasLoadedPage
        let request = URLRequest(
            url: AppConfig.websiteURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        webView.load(request)
    }

    @objc private func retryWebsite() {
        guard hasLoadedPage else {
            loadWebsite()
            return
        }
        let alert = UIAlertController(
            title: "重新加载页面？",
            message: "尚未确认的录入内容会被放弃，已保存的库存不受影响。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "重新加载", style: .default) { [weak self] _ in
            self?.loadWebsite()
        })
        guard presentedViewController == nil else { return }
        present(alert, animated: true)
    }

    @objc private func returnToPage() {
        errorOverlay.isHidden = true
        loadingOverlay.isHidden = true
    }

    private func showFailure(_ message: String) {
        loadingOverlay.isHidden = true
        errorMessage.text = message
        continueButton.isHidden = !hasLoadedPage
        errorOverlay.isHidden = false
    }

    private func showNotice(_ message: String) {
        bannerDismissal?.cancel()
        banner.text = "  \(message)  "
        banner.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
        let dismissal = DispatchWorkItem { [weak self] in self?.banner.isHidden = true }
        bannerDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: dismissal)
    }

    private func isTrusted(_ frame: WKFrameInfo) -> Bool {
        let origin = frame.securityOrigin
        return frame.isMainFrame
            && origin.protocol.lowercased() == "https"
            && origin.host.lowercased() == AppConfig.trustedHost
            && (origin.port == 0 || origin.port == 443)
            && AppConfig.isTrusted(frame.request.url)
            && AppConfig.isTrusted(webView.url)
    }

    private func completeBridge(
        requestID: String,
        result: FileShareResult,
        generation: Int
    ) {
        #if DEBUG
        print("[InventoryFileBridge] completion request=\(requestID) result=\(result.bridgeResponse) generation=\(generation)/\(navigationGeneration)")
        #endif
        if case .error(let message) = result { showNotice(message) }
        guard generation == navigationGeneration, AppConfig.isTrusted(webView.url),
              let data = try? JSONSerialization.data(withJSONObject: [requestID, result.bridgeResponse]),
              let arguments = String(data: data, encoding: .utf8) else {
            return
        }
        let script = "if(typeof window.__inventoryFileBridgeComplete==='function'){window.__inventoryFileBridgeComplete.apply(window,\(arguments));}"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func openExternal(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            showNotice("无法打开此链接。")
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

extension InventoryViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        #if DEBUG
        let debugPayload = message.body as? [String: Any]
        let debugOrigin = message.frameInfo.securityOrigin
        let debugFilename = debugPayload?["filename"] as? String ?? "<missing>"
        print("[InventoryFileBridge] received handler=\(message.name) fields=\(debugPayload?.keys.sorted() ?? []) filename=\(debugFilename)")
        print("[InventoryFileBridge] origin=\(debugOrigin.protocol)://\(debugOrigin.host):\(debugOrigin.port) mainFrame=\(message.frameInfo.isMainFrame) trusted=\(isTrusted(message.frameInfo))")
        #endif
        guard message.name == AppConfig.bridgeHandlerName, isTrusted(message.frameInfo),
              let payload = message.body as? [String: Any],
              let requestID = payload["requestId"] as? String,
              !requestID.isEmpty, requestID.utf8.count <= 128 else {
            #if DEBUG
            print("[InventoryFileBridge] rejected origin/handler/request metadata")
            #endif
            return
        }
        let generation = navigationGeneration
        guard let filename = payload["filename"] as? String,
              let mimeType = payload["mimeType"] as? String,
              let base64Data = payload["base64Data"] as? String else {
            completeBridge(requestID: requestID, result: .error("导出请求无效，请重试。"), generation: generation)
            return
        }
        fileShareCoordinator.share(
            filename: filename,
            mimeType: mimeType,
            base64Data: base64Data
        ) { [weak self] result in
            self?.completeBridge(requestID: requestID, result: result, generation: generation)
        }
    }
}

extension InventoryViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(AppConfig.isTrusted(url) ? .allow : .cancel)
            return
        }
        if AppConfig.isTrusted(url) {
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                webView.load(navigationAction.request)
            } else {
                decisionHandler(.allow)
            }
            return
        }

        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated {
            openExternal(url)
        } else if url.scheme?.lowercased() == "blob" {
            showNotice("无法导出此文件，请重试。")
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        guard AppConfig.isTrusted(navigationResponse.response.url) else {
            decisionHandler(.cancel)
            showFailure("网站地址无法验证，请稍后重试。已有库存仍保留在此设备中。")
            return
        }
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            decisionHandler(.cancel)
            showFailure("网站暂时无法访问，请稍后重试。已有库存仍保留在此设备中。")
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration += 1
        if !hasLoadedPage {
            errorOverlay.isHidden = true
            loadingOverlay.isHidden = false
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard AppConfig.isTrusted(webView.url) else { return }
        hasLoadedPage = true
        loadingOverlay.isHidden = true
        errorOverlay.isHidden = true
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        showFailure("请检查网络连接后重试。已有库存仍保留在此设备中。")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationGeneration += 1
        hasLoadedPage = false
        showFailure("页面暂时中断，请重试。已保存的库存仍保留在此设备中。")
    }
}

extension InventoryViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        guard isTrusted(frame), presentedViewController == nil, view.window != nil else {
            completionHandler()
            return
        }
        let alert = UIAlertController(title: "库存手记", message: String(message.prefix(5_000)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard isTrusted(frame), presentedViewController == nil, view.window != nil else {
            completionHandler(false)
            return
        }
        let alert = UIAlertController(title: "库存手记", message: String(message.prefix(5_000)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确认", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        guard isTrusted(frame), presentedViewController == nil, view.window != nil else {
            completionHandler(nil)
            return
        }
        let alert = UIAlertController(title: "库存手记", message: String(prompt.prefix(5_000)), preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.accessibilityIdentifier = "inventory.promptInput"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确认", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if AppConfig.isTrusted(url) {
            webView.load(navigationAction.request)
        } else if navigationAction.navigationType == .linkActivated {
            openExternal(url)
        }
        return nil
    }
}
