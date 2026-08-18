import Foundation
import UIKit
import UniformTypeIdentifiers

final class NativePickedFileIOS: NSObject {
    let path: String
    let name: String
    let size: Double
    let mimeType: String

    init(path: String, name: String, size: Double, mimeType: String) {
        self.path = path
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }
}

final class NativeFilePickerIOS: NSObject, UIDocumentPickerDelegate {
    static let shared = NativeFilePickerIOS()

    private enum Mode {
        case open
        case saveFolder
    }

    private var mode: Mode = .open
    private var maxCount = 1
    private var maxSizeBytes: Int64 = 50 * 1024 * 1024
    private var progressHandler: ((String, Int, Int, Double, Double, Int) -> Void)?
    private var completionHandler: (([NativePickedFileIOS], String?) -> Void)?
    private var saveCompletionHandler: ((String, String, String?) -> Void)?
    private var pendingFilename = "attachment"
    private var folderByToken: [String: URL] = [:]
    private var cacheDestDir = ""

    func choose(
        from viewController: UIViewController,
        count: Int,
        maxSizeBytes: Double,
        destDir: String,
        progress: @escaping (String, Int, Int, Double, Double, Int) -> Void,
        completion: @escaping ([NativePickedFileIOS], String?) -> Void
    ) {
        guard completionHandler == nil, saveCompletionHandler == nil else {
            completion([], "文件选择器正在使用中")
            return
        }
        self.mode = .open
        self.maxCount = max(1, count)
        self.maxSizeBytes = Int64(max(1, maxSizeBytes))
        self.cacheDestDir = destDir
        self.progressHandler = progress
        self.completionHandler = completion

        DispatchQueue.main.async {
            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) {
                picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
            } else {
                picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .open)
            }
            picker.delegate = self
            picker.allowsMultipleSelection = self.maxCount > 1
            picker.modalPresentationStyle = .formSheet
            viewController.present(picker, animated: true)
        }
    }

    func chooseSaveFolder(
        from viewController: UIViewController,
        filename: String,
        completion: @escaping (String, String, String?) -> Void
    ) {
        guard completionHandler == nil, saveCompletionHandler == nil else {
            completion("", filename, "文件选择器正在使用中")
            return
        }
        self.mode = .saveFolder
        self.pendingFilename = sanitizeFileName(filename)
        self.saveCompletionHandler = completion

        DispatchQueue.main.async {
            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) {
                picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            } else {
                picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
            }
            picker.delegate = self
            picker.allowsMultipleSelection = false
            picker.modalPresentationStyle = .formSheet
            if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                picker.directoryURL = downloads
            }
            viewController.present(picker, animated: true)
        }
    }

    func writeSavedFile(
        token: String,
        sourcePath: String,
        filename: String,
        completion: @escaping (String, String?) -> Void
    ) {
        do {
            let path = try copyToChosenFolder(token: token, sourcePath: sourcePath, filename: filename)
            completion(path, nil)
        } catch {
            completion("", error.localizedDescription)
        }
    }

    private func copyToChosenFolder(token: String, sourcePath: String, filename: String) throws -> String {
        guard let folder = folderByToken[token] else {
            throw PickerError.saveExpired
        }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer {
            if accessed { folder.stopAccessingSecurityScopedResource() }
        }
        let fromPath = localFilePath(sourcePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fromPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PickerError.sourceMissing
        }
        let sourceSize = (try FileManager.default.attributesOfItem(atPath: fromPath)[.size] as? NSNumber)?.int64Value ?? 0
        if sourceSize <= 0 {
            throw PickerError.sourceEmpty
        }
        let name = sanitizeFileName(filename)
        let destination = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(atPath: fromPath, toPath: destination.path)
        folderByToken.removeValue(forKey: token)
        return destination.path
    }

    private func localFilePath(_ raw: String) -> String {
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return url.path
        }
        return raw
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if mode == .saveFolder {
            finishSave(token: "", filename: pendingFilename, error: nil)
            return
        }
        finish(files: [], error: nil)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        if mode == .saveFolder {
            guard let folder = urls.first else {
                finishSave(token: "", filename: pendingFilename, error: nil)
                return
            }
            let token = "save_\(Int(Date().timeIntervalSince1970 * 1000))"
            folderByToken[token] = folder
            finishSave(token: token, filename: pendingFilename, error: nil)
            return
        }
        let selected = Array(urls.prefix(maxCount))
        let limit = maxSizeBytes
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var prepared: [NativePickedFileIOS] = []
            do {
                for (offset, url) in selected.enumerated() {
                    let file = try self.copyToCache(
                        sourceURL: url,
                        index: offset + 1,
                        count: selected.count,
                        maxSizeBytes: limit
                    )
                    prepared.append(file)
                }
                self.finish(files: prepared, error: nil)
            } catch {
                prepared.forEach { try? FileManager.default.removeItem(atPath: $0.path) }
                self.finish(files: [], error: error.localizedDescription)
            }
        }
    }

    private func copyToCache(
        sourceURL: URL,
        index: Int,
        count: Int,
        maxSizeBytes: Int64
    ) throws -> NativePickedFileIOS {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .nameKey])
        let originalName = values.name ?? sourceURL.lastPathComponent
        let name = sanitizeFileName(originalName)
        let declaredSize = Int64(values.fileSize ?? 0)
        if declaredSize > maxSizeBytes {
            throw PickerError.tooLarge(name: name, maxSizeMB: maxSizeBytes / 1024 / 1024)
        }

        let docRoot = plusDocDirectory()
        let cacheRoot = docRoot.appendingPathComponent("native_file_picker", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let destination = cacheRoot.appendingPathComponent("\(UUID().uuidString)_\(name)")
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destination)
        var copied: Int64 = 0
        var lastPercent = -1
        do {
            while true {
                let data = input.readData(ofLength: 256 * 1024)
                if data.isEmpty { break }
                copied += Int64(data.count)
                if copied > maxSizeBytes {
                    throw PickerError.tooLarge(name: name, maxSizeMB: maxSizeBytes / 1024 / 1024)
                }
                output.write(data)
                let total = declaredSize
                let percent = total > 0 ? min(99, Int(copied * 100 / total)) : 0
                if percent != lastPercent {
                    lastPercent = percent
                    progressHandler?(name, index, count, Double(copied), Double(total), percent)
                }
            }
            input.closeFile()
            output.closeFile()
        } catch {
            input.closeFile()
            output.closeFile()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let mime = mimeType(for: destination.pathExtension)
        progressHandler?(name, index, count, Double(copied), Double(copied), 100)
        return NativePickedFileIOS(
            path: destination.path,
            name: name,
            size: Double(copied),
            mimeType: mime
        )
    }

    /// 优先用 JS 传入的 5+ `_doc` 绝对路径，避免原生自己猜 Pandora 目录猜错。
    /// 不要写 temporaryDirectory：plus.io / plus.uploader 对 tmp 会报「不允许读」。
    private func plusDocDirectory() -> URL {
        let trimmed = cacheDestDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var path = trimmed
            if path.hasPrefix("file://"), let url = URL(string: path) {
                path = url.path
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let fm = FileManager.default
        if let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let apps = library.appendingPathComponent("Pandora/apps", isDirectory: true)
            if let children = try? fm.contentsOfDirectory(
                at: apps,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for appDir in children {
                    let doc = appDir.appendingPathComponent("doc", isDirectory: true)
                    if fm.fileExists(atPath: doc.path) {
                        return doc
                    }
                }
                if let first = children.first {
                    let doc = first.appendingPathComponent("doc", isDirectory: true)
                    try? fm.createDirectory(at: doc, withIntermediateDirectories: true)
                    return doc
                }
            }
        }
        return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func plusUploaderPath(destination: URL, docRoot: URL) -> String {
        let destPath = destination.standardizedFileURL.path
        let rootPath = docRoot.standardizedFileURL.path
        if destPath.hasPrefix(rootPath) {
            let rest = String(destPath.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !cacheDestDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rest.isEmpty ? "_doc" : "_doc/\(rest)"
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .standardizedFileURL.path
            if rootPath == documents {
                return rest.isEmpty ? "_documents" : "_documents/\(rest)"
            }
            return rest.isEmpty ? "_doc" : "_doc/\(rest)"
        }
        return destPath
    }

    private func finish(files: [NativePickedFileIOS], error: String?) {
        DispatchQueue.main.async {
            let completion = self.completionHandler
            self.completionHandler = nil
            self.progressHandler = nil
            completion?(files, error)
        }
    }

    private func finishSave(token: String, filename: String, error: String?) {
        DispatchQueue.main.async {
            let completion = self.saveCompletionHandler
            self.saveCompletionHandler = nil
            completion?(token, filename, error)
        }
    }

    private func sanitizeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let result = value.components(separatedBy: invalid).joined(separator: "_")
        return result.isEmpty ? "file_\(Int(Date().timeIntervalSince1970))" : result
    }

    private func mimeType(for extensionName: String) -> String {
        if #available(iOS 14.0, *), let type = UTType(filenameExtension: extensionName) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}

private enum UploadError: LocalizedError {
    case fileMissing
    case fileEmpty

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "无法读取所选文件，请重新选择"
        case .fileEmpty:
            return "所选文件是空的，请重新选择"
        }
    }
}

private enum PickerError: LocalizedError {
    case tooLarge(name: String, maxSizeMB: Int64)
    case saveExpired
    case sourceMissing
    case sourceEmpty

    var errorDescription: String? {
        switch self {
        case let .tooLarge(name, maxSizeMB):
            return "「\(name)」超过 \(maxSizeMB)MB"
        case .saveExpired:
            return "保存位置已失效，请重新选择"
        case .sourceMissing:
            return "下载文件已丢失，无法写入所选位置"
        case .sourceEmpty:
            return "下载文件为空，未写入所选位置"
        }
    }
}

final class NativeUploaderIOS: NSObject, URLSessionTaskDelegate {
    static let shared = NativeUploaderIOS()

    private var session: URLSession?
    private var progressHandler: ((Int, Double, Double) -> Void)?
    private var busy = false

    func uploadMultipart(
        url: String,
        headersJson: String,
        formDataJson: String,
        filePaths: [String],
        fileFields: [String],
        fileNames: [String],
        fileMimes: [String],
        progress: @escaping (Int, Double, Double) -> Void,
        completion: @escaping (Int, String, String?) -> Void
    ) {
        if busy {
            completion(0, "", "上传进行中")
            return
        }
        busy = true
        progressHandler = progress
        DispatchQueue.global(qos: .userInitiated).async {
            let finish: (Int, String, String?) -> Void = { code, body, message in
                DispatchQueue.main.async {
                    self.busy = false
                    self.progressHandler = nil
                    completion(code, body, message)
                }
            }
            guard let requestURL = URL(string: url) else {
                finish(0, "", "上传地址无效")
                return
            }
            guard filePaths.count > 0, filePaths.count == fileFields.count, filePaths.count == fileNames.count else {
                finish(0, "", "上传文件参数不完整")
                return
            }
            let boundary = "Boundary-\(UUID().uuidString)"
            let bodyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("native_upload_\(UUID().uuidString)")
            do {
                try self.writeMultipartBody(
                    to: bodyURL,
                    boundary: boundary,
                    fields: self.parseStringMap(formDataJson),
                    filePaths: filePaths,
                    fileFields: fileFields,
                    fileNames: fileNames,
                    fileMimes: fileMimes
                )
                var request = URLRequest(url: requestURL)
                request.httpMethod = "POST"
                request.timeoutInterval = 120
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                for (key, value) in self.parseStringMap(headersJson) {
                    if key.lowercased() == "content-type" { continue }
                    request.setValue(value, forHTTPHeaderField: key)
                }
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 120
                config.timeoutIntervalForResource = 120
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.uploadTask(with: request, fromFile: bodyURL) { data, response, error in
                    try? FileManager.default.removeItem(at: bodyURL)
                    session.finishTasksAndInvalidate()
                    self.session = nil
                    if let error {
                        finish(0, "", error.localizedDescription)
                        return
                    }
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    finish(code, body, nil)
                }
                task.resume()
            } catch {
                try? FileManager.default.removeItem(at: bodyURL)
                finish(0, "", error.localizedDescription)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let total = max(totalBytesExpectedToSend, 1)
        let percent = min(99, Int(totalBytesSent * 100 / total))
        DispatchQueue.main.async {
            self.progressHandler?(percent, Double(totalBytesSent), Double(totalBytesExpectedToSend))
        }
    }

    private func writeMultipartBody(
        to bodyURL: URL,
        boundary: String,
        fields: [String: String],
        filePaths: [String],
        fileFields: [String],
        fileNames: [String],
        fileMimes: [String]
    ) throws {
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { output.closeFile() }
        for (key, value) in fields {
            output.write(Data("--\(boundary)\r\n".utf8))
            output.write(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            output.write(Data("\(value)\r\n".utf8))
        }
        for index in 0..<filePaths.count {
            let path = self.localFilePath(filePaths[index])
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw UploadError.fileMissing
            }
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            if size <= 0 {
                throw UploadError.fileEmpty
            }
            let name = fileNames[index].replacingOccurrences(of: "\"", with: "_")
            let field = fileFields[index]
            let mime = fileMimes[index].isEmpty ? "application/octet-stream" : fileMimes[index]
            output.write(Data("--\(boundary)\r\n".utf8))
            output.write(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\n".utf8))
            output.write(Data("Content-Type: \(mime)\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { input.closeFile() }
            while true {
                let chunk = input.readData(ofLength: 256 * 1024)
                if chunk.isEmpty { break }
                output.write(chunk)
            }
            output.write(Data("\r\n".utf8))
        }
        output.write(Data("--\(boundary)--\r\n".utf8))
    }

    private func localFilePath(_ raw: String) -> String {
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return url.path
        }
        return raw
    }

    private func parseStringMap(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in obj {
            if let text = value as? String {
                result[key] = text
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            } else if value is NSNull {
                continue
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }
}
