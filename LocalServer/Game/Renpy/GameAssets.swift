import Foundation

/// 游戏资源的统一读取入口：文件系统优先，其次各个 .rpa 归档。
///
/// 与 Ren'Py 自身的顺序一致（loader.py：`Files on disk should be checked before archives`），
/// 归档之间按文件名倒序，先匹配到的生效。
final class GameAssets {
    /// 游戏根目录（含 `game/`，或直接就是 `game/`）
    let root: URL
    let gameDirectory: URL
    private var archives: [RenPyArchive] = []
    /// 小写路径 -> 相对 game 目录的真实路径
    private var loose: [String: String] = [:]
    private let cache = NSCache<NSString, NSData>()
    private let fileManager = FileManager.default

    /// 在给定文件夹里定位游戏；找不到 game 目录时返回 nil
    static func locate(from folder: URL) -> GameAssets? {
        var candidates = [folder, folder.appendingPathComponent("game", isDirectory: true)]
        candidates += FileManager.default.children(of: folder).map {
            folder.appendingPathComponent($0, isDirectory: true)
        }
        for candidate in candidates {
            if let assets = GameAssets(gameDirectory: candidate) { return assets }
        }
        return nil
    }

    private init?(gameDirectory: URL) {
        // `game/` 里要有 .rpy 或 .rpa 才算脚本目录；给定目录自身是脚本目录时也可以
        let manager = FileManager.default
        let direct = gameDirectory.appendingPathComponent("game", isDirectory: true)
        let directory: URL
        if manager.hasScriptFiles(in: direct) {
            directory = direct
        } else if manager.hasScriptFiles(in: gameDirectory) {
            directory = gameDirectory
        } else {
            return nil
        }
        self.gameDirectory = directory
        self.root = directory.deletingLastPathComponent().standardizedFileURL

        indexLooseFiles(in: directory)
        indexArchives(in: directory)
        cache.countLimit = 96
    }

    // MARK: - 索引

    private func indexLooseFiles(in directory: URL) {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true else { continue }
            guard let relative = FileStore.relativePath(of: url, to: directory) else { continue }
            loose[RenPyArchive.key(relative)] = relative
        }
    }

    private func indexArchives(in directory: URL) {
        let candidates = fileManager.children(of: directory)
            .filter { $0.lowercased().hasSuffix(".rpa") }
            .sorted(by: >)
        for name in candidates {
            if let archive = RenPyArchive.open(url: directory.appendingPathComponent(name)) {
                archives.append(archive)
            }
        }
    }

    // MARK: - 读取

    /// 相对 game 目录的路径；也接受带 `game/` 前缀的写法
    private func normalized(_ name: String) -> String {
        var path = name.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        if path.hasPrefix("/") { path = String(path.dropFirst()) }
        if path.hasPrefix("game/") { path = String(path.dropFirst(5)) }
        return RenPyArchive.key(path)
    }

    func exists(_ name: String) -> Bool {
        let key = normalized(name)
        if loose[key] != nil { return true }
        return archives.contains { $0.contains(key) }
    }

    /// 读取内容；找不到返回 nil
    func read(_ name: String) -> Data? {
        let key = normalized(name)
        if let cached = cache.object(forKey: key as NSString) {
            return cached as Data
        }
        let data: Data?
        if let relative = loose[key] {
            data = try? Data(contentsOf: gameDirectory.appendingPathComponent(relative))
        } else {
            data = archives.lazy.compactMap { $0.data(for: key) }.first
        }
        if let data {
            cache.setObject(data as NSData, forKey: key as NSString, cost: max(1, data.count / 1024))
        }
        return data
    }

    func text(_ name: String) -> String? {
        guard let data = read(name) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 所有可见资源的相对路径（含归档内），用于枚举脚本
    func allNames() -> [String] {
        var names = Set(loose.keys)
        for archive in archives {
            names.formUnion(archive.memberNames().map { RenPyArchive.key($0) })
        }
        return Array(names).sorted()
    }

    func names(withExtension extensionName: String) -> [String] {
        let suffix = "." + extensionName.lowercased()
        return allNames().filter { $0.hasSuffix(suffix) }
    }

    /// 打开过的归档数，供“能否读取资源”的诊断信息使用
    var archiveCount: Int { archives.count }

    // MARK: - 图片与音频

    private static let imageExtensions = ["webp", "png", "jpg", "jpeg", "gif"]
    private static let imageDirectories = ["", "bg/", "characters/", "images/", "gui/", "cg/"]

    /// 按 Ren'Py 的空格命名习惯找图片：`show bg library` -> `bg library.png`
    func imageData(named name: String) -> Data? {
        let lowered = normalized(name)
        for directory in Self.imageDirectories {
            let base = directory.isEmpty ? lowered : directory + lowered
            // `image bg room = "bg/room.png"` 这种已经带扩展名的路径直接读
            if hasImageExtension(base), let data = read(base) { return data }
            for ext in Self.imageExtensions {
                if let data = read(base + "." + ext) { return data }
            }
        }
        // 文件名里的空格换成下划线再试一次
        let underscored = lowered.replacingOccurrences(of: " ", with: "_")
        for ext in Self.imageExtensions {
            if let data = read(underscored + "." + ext) { return data }
        }
        return nil
    }

    private func hasImageExtension(_ name: String) -> Bool {
        Self.imageExtensions.contains { name.hasSuffix("." + $0) }
    }

    private static let audioExtensions = ["ogg", "oga", "mp3", "wav", "m4a"]

    /// 音频：先按原样找，再试常见的 audio/ 目录
    func audioData(named name: String) -> Data? {
        if hasAudioExtension(name), let data = read(name) { return data }
        for directory in ["", "audio/", "music/", "sound/", "voice/", "ogg/"] {
            let candidate = directory + name
            if hasAudioExtension(candidate), let data = read(candidate) { return data }
            for ext in Self.audioExtensions {
                if let data = read(candidate + "." + ext) { return data }
            }
        }
        return nil
    }

    private func hasAudioExtension(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return Self.audioExtensions.contains { lowered.hasSuffix("." + $0) }
    }
}

extension FileManager {
    /// 目录内（不含子目录）是否有 .rpy / .rpa 脚本
    func hasScriptFiles(in directory: URL) -> Bool {
        guard let names = try? contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains {
            let lower = $0.lowercased()
            return lower.hasSuffix(".rpy") || lower.hasSuffix(".rpa") || lower.hasSuffix(".rpym")
        }
    }

    func children(of directory: URL) -> [String] {
        (try? contentsOfDirectory(atPath: directory.path)) ?? []
    }
}
