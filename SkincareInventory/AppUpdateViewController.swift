import UIKit

protocol InventoryUpdateServing: AnyObject {
    func check(completion: @escaping (Result<AppUpdateRelease?, Error>) -> Void)
    func download(
        _ release: AppUpdateRelease,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<AppUpdatePackage, Error>) -> Void
    )
    func cancel()
}

extension AppUpdateService: InventoryUpdateServing {}

func makeInventoryUpdateService() -> InventoryUpdateServing {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
        return UITestUpdateService()
    }
    #endif
    return AppUpdateService(currentVersion: AppConfig.appVersion)
}

/// The update screen never owns or reloads the inventory's web view. Only a
/// checksum-verified local file can reach the installer or document handoff.
final class AppUpdateViewController: UIViewController, UIDocumentInteractionControllerDelegate {
    private let service: InventoryUpdateServing
    private let availabilityChanged: (AppUpdateRelease?) -> Void
    private let status = UILabel()
    private let detail = UILabel()
    private let installerStatus = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let checkButton = UIButton(type: .system)
    private let downloadButton = UIButton(type: .system)
    private let installButton = UIButton(type: .system)
    private let handoffButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var release: AppUpdateRelease?
    private var verifiedPackage: AppUpdatePackage?
    private var installerReady = false
    private var installing = false
    private var documentController: UIDocumentInteractionController?
    private var selectedApplication = false
    private var isSendingPackage = false
    private var operation = 0
    private var busy = false
    private var didStart = false

    init(
        service: InventoryUpdateServing,
        availabilityChanged: @escaping (AppUpdateRelease?) -> Void
    ) {
        self.service = service
        self.availabilityChanged = availabilityChanged
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(red: 9 / 255, green: 11 / 255, blue: 10 / 255, alpha: 1)
        let title = UILabel()
        title.text = "App 更新"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        let current = UILabel()
        current.text = "当前版本 \(AppConfig.appVersion)"
        current.accessibilityIdentifier = "inventory.update.current"
        current.textColor = .secondaryLabel
        for label in [current, status, detail, installerStatus] {
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
        }
        status.accessibilityIdentifier = "inventory.update.status"
        detail.accessibilityIdentifier = "inventory.update.details"
        detail.textColor = .secondaryLabel
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.text = "打开 App 时会自动检查新版。更新前请先保存正在录入的内容，并在“我的”中导出 JSON 备份。\n\n通过巨魔覆盖安装，已保存的库存通常会保留。不要先卸载 App。"
        installerStatus.text = "正在识别原地更新环境…"
        installerStatus.textColor = .secondaryLabel
        installerStatus.font = .preferredFont(forTextStyle: .subheadline)
        installerStatus.accessibilityIdentifier = "inventory.update.installer"
        configure(checkButton, title: "重新检查", identifier: "inventory.update.check", action: #selector(checkForUpdate))
        configure(downloadButton, title: "下载更新", identifier: "inventory.update.download", action: #selector(confirmDownload))
        configure(installButton, title: "在 App 内覆盖更新", identifier: "inventory.update.install", action: #selector(confirmInstall))
        configure(handoffButton, title: "通过巨魔文件交接更新", identifier: "inventory.update.handoff", action: #selector(confirmFileHandoff))
        configure(cancelButton, title: "取消", identifier: "inventory.update.cancel", action: #selector(cancelOperation))
        configure(closeButton, title: "关闭，返回库存", identifier: "inventory.update.close", action: #selector(closeScreen))
        let releaseButton = UIButton(type: .system)
        configure(releaseButton, title: "查看发布与下载页", identifier: "inventory.update.releases", action: #selector(openReleasePage))
        downloadButton.isHidden = true
        installButton.isHidden = true
        handoffButton.isHidden = true
        cancelButton.isHidden = true
        progressView.isHidden = true
        progressView.accessibilityIdentifier = "inventory.update.progress"
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView(arrangedSubviews: [title, current, spinner, status, progressView,
            detail, installerStatus, downloadButton, installButton, handoffButton, checkButton,
            cancelButton, releaseButton, closeButton])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reason = InventorySelfUpdateUnavailableReason()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.installerReady = reason == nil
                self.installerStatus.text = reason ?? "已识别兼容的巨魔安装助手，可直接在 App 内确认更新。安装会关闭库存，之后请重开。"
                if self.verifiedPackage != nil && !self.busy {
                    self.installButton.isHidden = !self.installerReady
                }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didStart {
            didStart = true
            checkForUpdate()
        }
    }

    deinit { service.cancel() }

    private func configure(_ button: UIButton, title: String, identifier: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.accessibilityIdentifier = identifier
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func setBusy(_ value: Bool) {
        busy = value
        isModalInPresentation = value
        checkButton.isHidden = value
        cancelButton.isHidden = !value
        closeButton.isEnabled = !value
        if value { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    @objc private func checkForUpdate() {
        guard !busy, documentController == nil else { return }
        operation += 1
        let generation = operation
        release = nil
        verifiedPackage = nil
        downloadButton.isHidden = true
        installButton.isHidden = true
        handoffButton.isHidden = true
        progressView.isHidden = true
        status.text = "正在检查新版本…"
        setBusy(true)
        service.check { [weak self] result in
            guard let self = self, self.operation == generation else { return }
            self.setBusy(false)
            switch result {
            case .success(let update):
                self.release = update
                self.availabilityChanged(update)
                if let update = update {
                    self.status.text = "发现新版本 \(update.version)"
                    self.downloadButton.isHidden = false
                } else {
                    self.status.text = "当前已是最新版本"
                }
            case .failure(let error):
                self.showError(error, fallback: "暂时无法检查更新，请联网后重试。")
            }
        }
    }

    @objc private func confirmDownload() {
        guard !busy, release != nil, documentController == nil else { return }
        let alert = UIAlertController(title: "下载更新前", message:
            "请先保存正在录入的内容，并确认 JSON 备份已保存到“文件”或网盘。覆盖安装会关闭当前 App。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "先去保存和备份", style: .cancel) { [weak self] _ in
            self?.presentingViewController?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: "已保存，开始下载", style: .default) { [weak self] _ in
            self?.startDownload()
        })
        present(alert, animated: true)
    }

    private func startDownload() {
        guard let update = release, !busy else { return }
        operation += 1
        let generation = operation
        setBusy(true)
        downloadButton.isHidden = true
        installButton.isHidden = true
        handoffButton.isHidden = true
        progressView.progress = 0
        progressView.isHidden = false
        status.text = "正在下载更新…"
        service.download(update, progress: { [weak self] progress in
            guard let self = self, self.operation == generation else { return }
            self.progressView.progress = Float(progress)
            self.status.text = "正在下载并校验… \(Int(progress * 100))%"
        }, completion: { [weak self] result in
            guard let self = self, self.operation == generation else { return }
            self.setBusy(false)
            self.progressView.isHidden = true
            switch result {
            case .success(let package):
                self.verifiedPackage = package
                self.status.text = "更新包已下载并通过校验"
                self.installButton.isHidden = !self.installerReady
                self.handoffButton.isHidden = false
            case .failure(let error):
                self.verifiedPackage = nil
                self.downloadButton.isHidden = false
                self.showError(error, fallback: "下载未完成，请检查网络后重试。")
            }
        })
    }

    @objc private func cancelOperation() {
        guard busy, !installing else { return }
        operation += 1
        service.cancel()
        setBusy(false)
        progressView.isHidden = true
        status.text = "已取消，可继续使用库存"
        downloadButton.isHidden = release == nil
    }

    private func showError(_ error: Error, fallback: String) {
        if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled {
            status.text = "已取消，可继续使用库存"
        } else if let description = (error as? LocalizedError)?.errorDescription {
            status.text = description
        } else {
            status.text = fallback
        }
    }

    @objc private func confirmInstall() {
        guard !busy, installerReady, verifiedPackage != nil, documentController == nil else { return }
        let alert = UIAlertController(title: "在 App 内覆盖更新", message:
            "请确认已保存录入并备份 JSON。安装时“库存”会关闭；完成后从桌面重新打开，核对版本和库存。无需切换到巨魔，不要卸载旧版。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认安装", style: .default) { [weak self] _ in
            self?.startNativeInstall()
        })
        present(alert, animated: true)
    }

    private func startNativeInstall() {
        guard let package = verifiedPackage, !busy, installerReady else { return }
        installing = true
        setBusy(true)
        cancelButton.isHidden = true
        installButton.isHidden = true
        handoffButton.isHidden = true
        status.text = "正在覆盖安装，库存将关闭…完成后请从桌面重开。"
        // This record can be checked by the newly launched version, even when
        // the old process is terminated before its helper callback returns.
        UserDefaults.standard.set(package.version, forKey: "inventory.appUpdate.pendingVersion")
        UserDefaults.standard.synchronize()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = InventoryPerformSelfUpdate(package.fileURL, package.version, package.sha256, numericCast(package.size))
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.installing = false
                self.setBusy(false)
                self.installButton.isHidden = !self.installerReady
                self.handoffButton.isHidden = false
                if let failure = failure {
                    UserDefaults.standard.removeObject(forKey: "inventory.appUpdate.pendingVersion")
                    self.status.text = failure
                } else {
                    self.status.text = "安装助手已结束。请重开 App 核对版本和库存。"
                }
            }
        }
    }

    @objc private func confirmFileHandoff() {
        guard !busy, verifiedPackage != nil, documentController == nil else { return }
        let alert = UIAlertController(title: "交给巨魔覆盖安装", message:
            "在接下来的“打开方式”中选择 TrollStore（巨魔），覆盖更新现有的“库存”。不要先卸载。继续前请确认已保存录入并备份 JSON。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "继续", style: .default) { [weak self] _ in
            self?.openVerifiedPackage()
        })
        present(alert, animated: true)
    }

    private func openVerifiedPackage() {
        guard let file = verifiedPackage?.fileURL, FileManager.default.fileExists(atPath: file.path) else {
            verifiedPackage = nil
            installButton.isHidden = true
            handoffButton.isHidden = true
            downloadButton.isHidden = release == nil
            status.text = "更新包已被系统清理，请重新下载。"
            return
        }
        let controller = UIDocumentInteractionController(url: file)
        controller.uti = "com.apple.itunes.ipa"
        controller.name = "库存更新"
        controller.delegate = self
        selectedApplication = false
        isSendingPackage = false
        documentController = controller
        if !controller.presentOpenInMenu(from: handoffButton.bounds, in: handoffButton, animated: true) {
            documentController = nil
            status.text = "未找到可打开 IPA 的应用。请确认巨魔已安装，也可从发布页下载后在巨魔中覆盖安装。"
        }
    }

    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        if !selectedApplication {
            documentController = nil
            status.text = "已取消安装交接，可继续使用库存。"
        } else if !isSendingPackage {
            documentController = nil
        }
    }

    func documentInteractionController(_ controller: UIDocumentInteractionController,
                                       willBeginSendingToApplication application: String?) {
        selectedApplication = true
        isSendingPackage = true
        status.text = "正在交给所选应用…"
    }

    func documentInteractionController(_ controller: UIDocumentInteractionController,
                                       didEndSendingToApplication application: String?) {
        isSendingPackage = false
        documentController = nil
        status.text = "已交给所选应用；是否已更新，请重开 App 核对版本和库存。"
    }

    @objc private func closeScreen() {
        guard !busy, documentController == nil else { return }
        dismiss(animated: true)
    }

    @objc private func openReleasePage() {
        guard !installing else { return }
        UIApplication.shared.open(AppConfig.releasesURL, options: [:], completionHandler: nil)
    }
}

#if DEBUG
/// UI tests exercise the real update screen without relying on a public
/// Release changing mid-test. Network/download validation is tested separately.
private final class UITestUpdateService: InventoryUpdateServing {
    func check(completion: @escaping (Result<AppUpdateRelease?, Error>) -> Void) {
        DispatchQueue.main.async { completion(.success(nil)) }
    }
    func download(_ release: AppUpdateRelease, progress: @escaping (Double) -> Void,
                  completion: @escaping (Result<AppUpdatePackage, Error>) -> Void) {
        DispatchQueue.main.async { completion(.failure(URLError(.cancelled))) }
    }
    func cancel() {}
}
#endif
