import Foundation
import ZIPFoundation

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
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("www", isDirectory: true)
        if !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try? writeWelcomeSite(in: root)
        } else {
            migrateLegacyWelcomePage(in: root)
        }
        return root
    }()

    /// 示例站点所在的文件夹名
    static let welcomeSiteName = "示例站点"

    static func restoreWelcomePage() throws {
        try writeWelcomeSite(in: rootURL)
    }

    private static func writeWelcomeSite(in root: URL) throws {
        let folder = root.appendingPathComponent(welcomeSiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WelcomePage.html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    /// 旧版本把示例页放在 www 根目录；现在 / 显示站点列表，把未改动过的旧示例页移进示例站点
    private static func migrateLegacyWelcomePage(in root: URL) {
        let legacy = root.appendingPathComponent("index.html")
        guard let content = try? String(contentsOf: legacy, encoding: .utf8),
              content.contains(WelcomePage.legacyMarker) else { return }
        try? FileManager.default.removeItem(at: legacy)
        let folder = root.appendingPathComponent(welcomeSiteName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? writeWelcomeSite(in: root)
        }
    }

    // MARK: - 站点

    struct SiteInfo: Identifiable, Hashable {
        let name: String
        let url: URL
        let hasIndex: Bool
        let modified: Date?
        /// 是否开启；状态保存在站点文件夹中的隐藏标记文件里
        let enabled: Bool

        var id: String { name }
        /// 访问路径，例如 `/blog/`
        var path: String {
            "/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name) + "/"
        }
    }

    /// www 下的每个一级文件夹都是一个站点
    static func sites() -> [SiteInfo] {
        contents(of: rootURL)
            .filter { $0.isDirectory && Router.isValidSiteName($0.name) }
            .map { item in
                let fileManager = FileManager.default
                let hasIndex = fileManager.fileExists(atPath: item.url.appendingPathComponent("index.html").path)
                    || fileManager.fileExists(atPath: item.url.appendingPathComponent("index.htm").path)
                return SiteInfo(
                    name: item.name,
                    url: item.url,
                    hasIndex: hasIndex,
                    modified: item.modified,
                    enabled: !SiteMarker.isDisabled(item.url)
                )
            }
    }

    /// 是否是 www 下的一级文件夹（即一个站点）
    static func isSiteFolder(_ url: URL) -> Bool {
        guard let relative = relativePath(of: url), !relative.isEmpty, !relative.contains("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && Router.isValidSiteName(relative)
    }

    /// 文件所属的站点名；不在任何站点中时返回 nil
    static func siteName(of url: URL) -> String? {
        guard let relative = relativePath(of: url), !relative.isEmpty,
              let first = relative.split(separator: "/").first.map(String.init),
              Router.isValidSiteName(first) else { return nil }
        let folder = rootURL.appendingPathComponent(first)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return first
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

    // MARK: - 复制、移动、压缩

    /// 目标位置已存在同名项目时的处理方式
    enum ConflictPolicy {
        /// 报错，由调用方决定
        case fail
        /// 覆盖已有项目
        case overwrite
        /// 保留两者，新项目自动改名为“名称 2”
        case keepBoth
    }

    enum TransferError: LocalizedError, Equatable {
        case notFound
        case exists(String)
        case intoItself
        case root

        var errorDescription: String? {
            switch self {
            case .notFound: return "文件不存在"
            case .exists(let name): return "已存在名为「\(name)」的项目"
            case .intoItself: return "不能把文件夹移动或拷贝到它自己里面"
            case .root: return "不能操作 www 根目录"
            }
        }
    }

    /// 在文件夹中找一个不冲突的名称，例如“首页 2.html”“首页 3.html”
    static func availableName(for name: String, in directory: URL, firstSuffix: String = " 2") -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        func candidate(_ suffix: String) -> String {
            ext.isEmpty ? base + suffix : base + suffix + "." + ext
        }
        var result = candidate(firstSuffix)
        // “名称 2”之后是“名称 3”；“名称 副本”之后是“名称 副本 2”
        var index = firstSuffix == " 2" ? 2 : 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(result).path) {
            index += 1
            result = candidate(firstSuffix == " 2" ? " \(index)" : firstSuffix + " \(index)")
        }
        return result
    }

    /// 复制或移动到指定的完整路径（包含新名称），返回最终位置
    @discardableResult
    static func transfer(_ source: URL, to destination: URL, copy: Bool, policy: ConflictPolicy) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { throw TransferError.notFound }
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard sourcePath != rootURL.standardizedFileURL.path else { throw TransferError.root }
        if destinationPath == sourcePath {
            // 移动到原位置无需操作；拷贝到原位置则自动创建副本
            guard copy else { return source }
        } else if destinationPath.hasPrefix(sourcePath + "/") {
            throw TransferError.intoItself
        }

        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var target = destination
        if fileManager.fileExists(atPath: target.path) {
            switch policy {
            case .fail:
                throw TransferError.exists(target.lastPathComponent)
            case .overwrite where destinationPath != sourcePath:
                try fileManager.removeItem(at: target)
            case .overwrite, .keepBoth:
                // 拷贝到原位置时生成“名称 副本”，与 App 内的“创建副本”一致
                let suffix = destinationPath == sourcePath ? " 副本" : " 2"
                target = directory.appendingPathComponent(
                    availableName(for: target.lastPathComponent, in: directory, firstSuffix: suffix)
                )
            }
        }
        if copy {
            try fileManager.copyItem(at: source, to: target)
        } else {
            try fileManager.moveItem(at: source, to: target)
        }
        return target
    }

    /// 把项目复制或移动到文件夹中（保持原名），返回最终位置
    @discardableResult
    static func transfer(_ source: URL, into directory: URL, copy: Bool, policy: ConflictPolicy) throws -> URL {
        try transfer(source, to: directory.appendingPathComponent(source.lastPathComponent), copy: copy, policy: policy)
    }

    /// 在同一文件夹中创建副本，例如“首页 副本.html”
    @discardableResult
    static func duplicate(_ item: FileItem) throws -> URL {
        let directory = item.url.deletingLastPathComponent()
        let name = availableName(for: item.name, in: directory, firstSuffix: " 副本")
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: item.url, to: target)
        return target
    }

    /// 把一个或多个项目压缩为 zip，返回 zip 的位置。
    /// 单个项目保存为“名称.zip”，多个项目保存为“归档.zip”，都放在 directory 中。
    @discardableResult
    static func compress(_ urls: [URL], into directory: URL) throws -> URL {
        guard let first = urls.first else { throw TransferError.notFound }
        let fileManager = FileManager.default
        let baseName = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "归档"
        let destination = directory.appendingPathComponent(availableName(for: baseName + ".zip", in: directory))

        if urls.count == 1 {
            try fileManager.zipItem(at: first, to: destination, shouldKeepParent: true, compressionMethod: .deflate)
            return destination
        }
        // 多个项目：先在临时文件夹中汇总（APFS 上复制几乎不占空间），再整体压缩
        let staging = fileManager.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        for url in urls {
            try fileManager.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent))
        }
        try fileManager.zipItem(at: staging, to: destination, shouldKeepParent: false, compressionMethod: .deflate)
        return destination
    }

    /// 文件或文件夹的总大小和文件数（不含隐藏文件）
    static func measure(_ url: URL) -> (bytes: Int64, files: Int, folders: Int) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return (0, 0, 0) }
        guard isDirectory.boolValue else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return (Int64(size), 1, 0)
        }
        var bytes: Int64 = 0
        var files = 0
        var folders = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let child as URL in enumerator {
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    folders += 1
                } else {
                    files += 1
                    bytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return (bytes, files, folders)
    }

    /// 文件对应的访问路径，例如 `/blog/index.html`；不在 www 内时返回 nil
    static func webPath(for url: URL) -> String? {
        relativePath(of: url).map { "/" + $0 }
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
