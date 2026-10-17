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

    /// 把从「文件」App 选中的文件或文件夹复制进来，同名项目会被覆盖
    @discardableResult
    static func importItems(_ urls: [URL], into directory: URL) throws -> Int {
        let fileManager = FileManager.default
        var count = 0
        var firstError: Error?
        for source in urls {
            let accessing = source.startAccessingSecurityScopedResource()
            defer {
                if accessing { source.stopAccessingSecurityScopedResource() }
            }
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                count += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        if count == 0, let firstError {
            throw firstError
        }
        return count
    }

    static func createFolder(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(try validated(name), isDirectory: true)
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
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(try validated(name))
        guard destination != item.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StoreError.exists }
        try FileManager.default.moveItem(at: item.url, to: destination)
    }

    static func delete(_ item: FileItem) throws {
        try FileManager.default.removeItem(at: item.url)
    }

    /// 相对网站根目录的 URL 路径，例如 `/blog/index.html`
    static func webPath(for url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(rootPath) else { return "/" }
        let relative = String(path.dropFirst(rootPath.count))
        return relative.hasPrefix("/") ? relative : "/" + relative
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
