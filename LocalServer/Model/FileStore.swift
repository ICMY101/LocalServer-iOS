import Foundation

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: URL { url }

    var isTextFile: Bool {
        FileStore.textExtensions.contains(url.pathExtension.lowercased())
    }

    var isHTML: Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    var isZip: Bool {
        !isDirectory && url.pathExtension.lowercased() == "zip"
    }
}

enum FileStore {
    static let textExtensions: Set<String> = [
        "html", "htm", "css", "js", "mjs", "json", "txt", "md", "xml", "svg", "csv", "webmanifest", "map", "ts", "jsx", "tsx", "vue",
    ]

    /// 网站根目录：Documents/www（在「文件」App 中可见）
    static let rootURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("www", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? WelcomePage.html.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        }
        return root
    }()

    static func restoreWelcomePage() throws {
        try WelcomePage.html.write(to: rootURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    static func contents(of directory: URL) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.map { url -> FileItem in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// www 下的所有文件夹（相对路径），用于选择导入位置，最多列出 4 层
    static func allFolders(maxDepth: Int = 4) -> [String] {
        var result = [""]
        func walk(_ url: URL, _ relative: String, _ depth: Int) {
            guard depth < maxDepth else { return }
            for item in contents(of: url) where item.isDirectory {
                let path = relative.isEmpty ? item.name : relative + "/" + item.name
                result.append(path)
                walk(item.url, path, depth + 1)
            }
        }
        walk(rootURL, "", 0)
        return result
    }

    struct ImportSummary {
        var imported = 0
        var extractedFiles = 0
        /// 新建或解压出的文件夹名称
        var folders: [String] = []
        var failures: [String] = []

        var message: String {
            var parts: [String] = []
            if imported > 0 { parts.append("已导入 \(imported) 项") }
            if extractedFiles > 0 { parts.append("解压出 \(extractedFiles) 个文件") }
            if !folders.isEmpty { parts.append("位于文件夹「" + folders.joined(separator: "」「") + "」") }
            if !failures.isEmpty { parts.append("失败：\n" + failures.joined(separator: "\n")) }
            return parts.isEmpty ? "没有导入任何文件" : parts.joined(separator: "，")
        }
    }

    /// 多个文件放进新文件夹时的默认名称：单个文件用文件名，多个文件用导入时间
    static func defaultFolderName(for urls: [URL]) -> String {
        if urls.count == 1, let url = urls.first {
            return ZipExtractor.safeFolderName(url.deletingPathExtension().lastPathComponent)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH.mm"
        return "导入 " + formatter.string(from: Date())
    }

    /// 把选中的文件或文件夹复制进来，同名项目会被覆盖。
    /// - extractZips: zip 解压到以其文件名命名的文件夹（zip 内本身只有一个顶层文件夹时直接使用它）
    /// - newFolderName: 不为空时，先新建（或沿用）这个文件夹，再把所有项目放进去
    static func importItems(
        _ urls: [URL],
        into directory: URL,
        extractZips: Bool,
        newFolderName: String? = nil
    ) -> ImportSummary {
        let fileManager = FileManager.default
        var summary = ImportSummary()
        var directory = directory
        if let newFolderName {
            let name = ZipExtractor.safeFolderName(newFolderName)
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                directory = folder
                summary.folders.append(name)
            } catch {
                summary.failures.append("无法创建文件夹「\(name)」：\(error.localizedDescription)")
                return summary
            }
        }
        for source in urls {
            let accessing = source.startAccessingSecurityScopedResource()
            defer {
                if accessing { source.stopAccessingSecurityScopedResource() }
            }
            do {
                if extractZips && source.pathExtension.lowercased() == "zip" {
                    let extracted = try ZipExtractor.extractToFolder(
                        source,
                        in: directory,
                        folderName: source.lastPathComponent
                    )
                    summary.imported += 1
                    summary.extractedFiles += extracted.result.files
                    if newFolderName == nil {
                        summary.folders.append(extracted.folder.lastPathComponent)
                    }
                } else {
                    let destination = directory.appendingPathComponent(source.lastPathComponent)
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.copyItem(at: source, to: destination)
                    summary.imported += 1
                }
            } catch {
                summary.failures.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return summary
    }

    static func extractZip(_ item: FileItem) throws -> (result: ZipExtractor.Result, folder: URL) {
        try ZipExtractor.extractToFolder(item.url, in: item.url.deletingLastPathComponent(), folderName: item.name)
    }

    /// 其他 App 通过“用其他应用打开”传来的文件会被系统放在 Documents/Inbox，导入后清理掉
    static func cleanUpInbox(_ urls: [URL]) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.resolvingSymlinksInPath().path
        for url in urls {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(documents + "/Inbox/") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func createFolder(named name: String, in directory: URL) throws {
        let name = try validated(name)
        let url = directory.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw StoreError.exists }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    static func createFile(named name: String, in directory: URL) throws -> URL {
        var name = try validated(name)
        if (name as NSString).pathExtension.isEmpty {
            name += ".html"
        }
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw StoreError.exists }
        let template = url.pathExtension.lowercased().hasPrefix("htm") ? WelcomePage.blankTemplate : ""
        try template.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func rename(_ item: FileItem, to name: String) throws {
        let name = try validated(name)
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination != item.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StoreError.exists }
        try FileManager.default.moveItem(at: item.url, to: destination)
    }

    static func delete(_ item: FileItem) throws {
        try FileManager.default.removeItem(at: item.url)
    }

    /// 相对 www 的路径，例如 `blog/assets`；不在 www 内时返回 nil
    static func relativePath(of url: URL, to base: URL = rootURL) -> String? {
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == basePath { return "" }
        guard path.hasPrefix(basePath + "/") else { return nil }
        return String(path.dropFirst(basePath.count + 1))
    }

    /// 文件在某个网站根目录下对应的 URL 路径，例如 `/blog/index.html`；不在该网站内时返回 nil
    static func webPath(for url: URL, siteRoot: URL) -> String? {
        relativePath(of: url, to: siteRoot).map { "/" + $0 }
    }

    private static func validated(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw StoreError.invalidName
        }
        return name
    }

    enum StoreError: LocalizedError {
        case invalidName
        case exists

        var errorDescription: String? {
            switch self {
            case .invalidName: return "名称不能为空，不能包含 “/”，也不能以 “.” 开头"
            case .exists: return "已存在同名的文件或文件夹"
            }
        }
    }
}
