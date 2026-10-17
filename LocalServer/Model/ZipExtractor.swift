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

    static func extract(_ zipURL: URL, into destination: URL) throws -> Result {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw ExtractError.unreadable
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let rootPath = destination.standardizedFileURL.path
        let encoding = pathEncoding(for: archive)
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
            let targetPath = target.standardizedFileURL.path
            guard targetPath.hasPrefix(rootPath + "/") else {
                result.skipped += 1
                continue
            }

            switch entry.type {
            case .directory:
                try createDirectory(at: target, fileManager: fileManager)
            case .file:
                try createDirectory(at: target.deletingLastPathComponent(), fileManager: fileManager)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
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
