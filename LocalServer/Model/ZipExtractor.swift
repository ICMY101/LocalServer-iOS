import Foundation
import ZIPFoundation

/// 解压 zip 到指定目录，同名文件会被覆盖。
/// - 兼容 Windows 上用 GBK 编码文件名打包的 zip
/// - 拒绝 `../` 等越界路径（zip slip）
/// - 跳过 `__MACOSX`、隐藏文件和符号链接
enum ZipExtractor {
    struct Result: Equatable {
        var files = 0
        var skipped = 0
    }

    enum ExtractError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取 zip 文件，文件可能已损坏或不是 zip 格式"
            }
        }
    }

    /// 解压到一个独立的文件夹中，避免文件散落在当前目录：
    /// - zip 内只有一个顶层文件夹时，直接解压到 `parent`，得到的就是这个文件夹
    /// - 否则在 `parent` 中新建以 `folderName` 命名的文件夹并解压到其中（已存在同名文件夹时合并覆盖）
    static func extractToFolder(_ zipURL: URL, in parent: URL, folderName: String) throws -> (result: Result, folder: URL) {
        let archive = try open(zipURL)
        let encoding = pathEncoding(for: archive)

        var topLevel = Set<String>()
        var hasTopLevelFile = false
        for entry in archive {
            guard let components = sanitizedComponents(entry.path(using: encoding)) else { continue }
            topLevel.insert(components[0])
            if components.count == 1 && entry.type != .directory {
                hasTopLevelFile = true
            }
        }

        if topLevel.count == 1, !hasTopLevelFile, let only = topLevel.first {
            let folder = parent.appendingPathComponent(only, isDirectory: true)
            if !isRegularFile(folder) {
                let result = try extract(archive, encoding: encoding, into: parent)
                return (result, folder)
            }
        }

        let folder = availableFolder(named: safeFolderName(folderName), in: parent)
        let result = try extract(archive, encoding: encoding, into: folder)
        return (result, folder)
    }

    /// 原样解压到 `destination`
    static func extract(_ zipURL: URL, into destination: URL) throws -> Result {
        let archive = try open(zipURL)
        return try extract(archive, encoding: pathEncoding(for: archive), into: destination)
    }

    private static func open(_ zipURL: URL) throws -> Archive {
        do {
            return try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw ExtractError.unreadable
        }
    }

    private static func extract(_ archive: Archive, encoding: String.Encoding, into destination: URL) throws -> Result {
        let fileManager = FileManager.default
        try createDirectory(at: destination, fileManager: fileManager)
        let rootPath = destination.standardizedFileURL.path
        var result = Result()

        for entry in archive {
            guard let components = sanitizedComponents(entry.path(using: encoding)) else {
                result.skipped += 1
                continue
            }
            var target = destination
            for component in components {
                target.appendPathComponent(component)
            }
            // 防御性检查：最终路径必须仍在目标目录内
            guard target.standardizedFileURL.path.hasPrefix(rootPath + "/") else {
                result.skipped += 1
                continue
            }

            switch entry.type {
            case .directory:
                try createDirectory(at: target, fileManager: fileManager)
            case .file:
                try createDirectory(at: target.deletingLastPathComponent(), fileManager: fileManager)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                _ = try archive.extract(entry, to: target)
                result.files += 1
            case .symlink:
                result.skipped += 1
            }
        }
        return result
    }

    /// 把 zip 内的路径拆成安全的路径片段，不安全或应跳过时返回 nil
    static func sanitizedComponents(_ rawPath: String) -> [String]? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") { return nil }
        var components: [String] = []
        for part in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            if part.hasPrefix(".") || part == "__MACOSX" { return nil }
            if part.contains("\0") || part.contains(":") { return nil }
            components.append(String(part))
        }
        return components.isEmpty ? nil : components
    }

    /// 如果所有文件名都是合法的 UTF-8 就按 UTF-8 解码，否则按 GB18030（兼容 GBK）解码
    static func pathEncoding(for archive: Archive) -> String.Encoding {
        for entry in archive {
            let path = entry.path(using: .utf8)
            if path.isEmpty || path.contains("\u{FFFD}") {
                return gb18030
            }
        }
        return .utf8
    }

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))

    /// 由 zip 文件名得到文件夹名：去掉扩展名和不允许的字符
    static func safeFolderName(_ name: String) -> String {
        var name = name
        if name.lowercased().hasSuffix(".zip") {
            name = String(name.dropLast(4))
        }
        name = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        return name.isEmpty ? "解压文件" : name
    }

    /// 同名文件夹可以合并；若被同名的普通文件占用，则改用“名称 2”“名称 3”……
    private static func availableFolder(named name: String, in parent: URL) -> URL {
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while isRegularFile(candidate) {
            candidate = parent.appendingPathComponent("\(name) \(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func createDirectory(at url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            // 同名文件挡住了目录，用目录替换它
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
