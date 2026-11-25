import Foundation
import UIKit

enum FileShareResult {
    case shared
    case cancelled
    case error(String)

    var bridgeResponse: [String: String] {
        switch self {
        case .shared:
            return ["status": "shared"]
        case .cancelled:
            return ["status": "cancelled"]
        case .error(let message):
            return ["status": "error", "message": message]
        }
    }
}

enum FileExportValidationError: LocalizedError {
    case unsafeFilename
    case unsupportedType
    case invalidBase64
    case emptyFile
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsafeFilename:
            return "文件名无效，请重新导出。"
        case .unsupportedType:
            return "仅支持导出 JSON 备份和 XLSX 表格。"
        case .invalidBase64:
            return "文件内容无效，请重新导出。"
        case .emptyFile:
            return "导出文件为空，请重新导出。"
        case .tooLarge:
            return "文件超过 20 MB，暂时无法分享。"
        }
    }
}

final class FileShareCoordinator {
    private struct PreparedFile {
        let directory: URL
        let file: URL
    }

    private weak var presenter: UIViewController?
    private(set) var isBusy = false
    private var activeController: UIActivityViewController?

    init(presenter: UIViewController) {
        self.presenter = presenter
    }

    static func validate(
        filename: String,
        mimeType: String,
        base64Data: String
    ) throws -> Data {
        let forbiddenFilenameCharacters = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/\\:"))
        guard !filename.isEmpty,
              !filename.hasPrefix("."),
              filename.utf8.count <= 240,
              filename == filename.trimmingCharacters(in: .whitespacesAndNewlines),
              filename.rangeOfCharacter(from: forbiddenFilenameCharacters) == nil else {
            throw FileExportValidationError.unsafeFilename
        }

        let fileExtension = (filename as NSString).pathExtension.lowercased()
        let expectedMIMEType: String
        switch fileExtension {
        case "json":
            expectedMIMEType = "application/json"
        case "xlsx":
            expectedMIMEType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default:
            throw FileExportValidationError.unsupportedType
        }
        guard mimeType.lowercased() == expectedMIMEType else {
            throw FileExportValidationError.unsupportedType
        }

        let maximumBase64Bytes = ((AppConfig.maximumExportFileBytes + 2) / 3) * 4
        guard base64Data.utf8.count <= maximumBase64Bytes else {
            throw FileExportValidationError.tooLarge
        }
        guard let data = Data(base64Encoded: base64Data) else {
            throw FileExportValidationError.invalidBase64
        }
        guard !data.isEmpty else {
            throw FileExportValidationError.emptyFile
        }
        guard data.count <= AppConfig.maximumExportFileBytes else {
            throw FileExportValidationError.tooLarge
        }
        return data
    }

    func share(
        filename: String,
        mimeType: String,
        base64Data: String,
        completion: @escaping (FileShareResult) -> Void
    ) {
        precondition(Thread.isMainThread)
        guard !isBusy else {
            completion(.error("已有文件分享操作正在进行，请先完成或取消。"))
            return
        }
        isBusy = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let prepared: Result<PreparedFile, Error>
            do {
                let data = try Self.validate(
                    filename: filename,
                    mimeType: mimeType,
                    base64Data: base64Data
                )
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("InventoryExports", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    let file = directory.appendingPathComponent(filename, isDirectory: false)
                    try data.write(to: file, options: .atomic)
                    prepared = .success(PreparedFile(directory: directory, file: file))
                } catch {
                    Self.removeTemporaryDirectory(directory)
                    throw error
                }
            } catch {
                prepared = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    if case .success(let file) = prepared {
                        Self.removeTemporaryDirectory(file.directory)
                    }
                    completion(.error("页面已关闭，请重新打开后导出。"))
                    return
                }
                switch prepared {
                case .success(let file):
                    self.present(file, completion: completion)
                case .failure(let error):
                    self.isBusy = false
                    let message = (error as? FileExportValidationError)?.errorDescription
                        ?? "无法准备导出文件，请检查设备存储空间后重试。"
                    completion(.error(message))
                }
            }
        }
    }

    private func present(
        _ prepared: PreparedFile,
        completion: @escaping (FileShareResult) -> Void
    ) {
        guard let presenter = presenter,
              presenter.isViewLoaded,
              presenter.view.window != nil,
              presenter.presentedViewController == nil else {
            Self.removeTemporaryDirectory(prepared.directory)
            isBusy = false
            completion(.error("当前页面暂时无法分享，请关闭弹窗后重试。"))
            return
        }

        let controller = UIActivityViewController(
            activityItems: [prepared.file],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { [weak self] _, completed, _, error in
            Self.removeTemporaryDirectory(prepared.directory)
            self?.activeController = nil
            self?.isBusy = false
            if error != nil {
                completion(.error("系统未能完成分享，请重试。"))
            } else {
                completion(completed ? .shared : .cancelled)
            }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.maxY - presenter.view.safeAreaInsets.bottom - 20,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        activeController = controller
        presenter.present(controller, animated: true)
    }

    private static func removeTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
