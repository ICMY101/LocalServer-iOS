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
    private static let imageDirectories = [
        "", "images/", "bg/", "images/bg/", "characters/", "images/characters/",
        "cg/", "images/cg/", "gui/", "images/gui/"
    ]

    /// `images/bg/home_front_night.webp` -> `bg home front night`
    ///
    /// 这是 Ren'Py 的自动图片命名规则：`images/` 下的子目录和文件名里的下划线
    /// 都当作空格，图片名就是由此拼出来的标签 + 属性。
    private lazy var autoImageIndex: [String: String] = {
        var index: [String: String] = [:]
        for path in allNames() where path.hasPrefix("images/") {
            guard let ext = Self.pathExtension(path), Self.imageExtensions.contains(ext) else { continue }
            let stem = String(path.dropFirst("images/".count).dropLast(ext.count + 1))
            for name in Self.automaticNames(stem) where index[name] == nil {
                index[name] = path
            }
        }
        return index
    }()

    /// 一个图片文件可能对应的名字：
    /// 1. 路径里的 `/` 和下划线都当空格（Ren'Py 自动图片的通用规则）；
    /// 2. `cg-08-05-report_ashamed` 这类 CG 文件名，游戏自己的脚本会注册成
    ///    `cg report ashamed`（去掉编号，只留前缀和标题）；
    /// 3. 立绘部件和叠加层按去掉 `fg/`、`overlay/` 目录的名字引用：
    ///    `images/fg/hana/body_base.webp` 就是 `hana body base`。
    private static func automaticNames(_ stem: String) -> [String] {
        var names = [spaceName(stem)]
        let file = stem.split(separator: "/").last.map(String.init) ?? stem
        let parts = file.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 4 {
            names.append(spaceName(String(parts[0]) + " " + String(parts[3])))
        }
        for prefix in ["fg/", "overlay/"] where stem.hasPrefix(prefix) {
            names.append(spaceName(String(stem.dropFirst(prefix.count))))
        }
        return names
    }

    /// 按 Ren'Py 的空格命名习惯找图片：`show bg library` -> `bg library.png`
    func imageData(named name: String) -> Data? {
        let lowered = normalized(name)
        // `image bg room = "bg/room.png"` 这种已经带扩展名的路径直接读
        if hasImageExtension(lowered), let data = read(lowered) { return data }
        // images/ 下的自动命名（真实工程基本都是这种布局）
        if let path = autoImageIndex[Self.spaceName(lowered)], let data = read(path) { return data }
        for directory in Self.imageDirectories {
            let base = directory.isEmpty ? lowered : directory + lowered
            for candidate in [base, base.replacingOccurrences(of: " ", with: "_")] {
                if hasImageExtension(candidate), let data = read(candidate) { return data }
                for ext in Self.imageExtensions {
                    if let data = read(candidate + "." + ext) { return data }
                }
            }
        }
        return nil
    }

    private func hasImageExtension(_ name: String) -> Bool {
        guard let ext = Self.pathExtension(name) else { return false }
        return Self.imageExtensions.contains(ext)
    }

    private static let audioExtensions = ["ogg", "oga", "mp3", "wav", "m4a"]

    /// 去掉扩展名的完整路径、路径后缀和文件名都能命中音频。
    /// 真实工程把音乐放在 `audio/bgm/`、音效放在 `audio/sound/`，脚本里往往只写裸文件名。
    private lazy var audioIndex: [String: String] = {
        var index: [String: String] = [:]
        for path in allNames() {
            guard let ext = Self.pathExtension(path), Self.audioExtensions.contains(ext) else { continue }
            let stem = String(path.dropLast(ext.count + 1))
            var suffixes = [path, stem]
            var rest = stem[...]
            while let slash = rest.firstIndex(of: "/") {
                rest = rest[rest.index(after: slash)...]
                suffixes.append(String(rest))
            }
            for suffix in suffixes where index[suffix] == nil {
                index[suffix] = path
            }
        }
        return index
    }()

    /// 音频：先按原样找，再按去掉目录的文件名找，最后试常见的 audio/ 目录
    func audioData(named name: String) -> Data? {
        let key = normalized(name)
        if hasAudioExtension(key), let data = read(key) { return data }
        if hasAudioExtension(key), let path = audioIndex[key], let data = read(path) { return data }
        if let path = audioIndex[key], let data = read(path) { return data }
        for directory in ["", "audio/", "music/", "sound/", "voice/", "ogg/", "audio/bgm/", "audio/sound/", "audio/voice/"] {
            let candidate = directory + key
            if hasAudioExtension(candidate), let data = read(candidate) { return data }
            for ext in Self.audioExtensions {
                if let data = read(candidate + "." + ext) { return data }
            }
        }
        return nil
    }

    private static func pathExtension(_ path: String) -> String? {
        guard let dot = path.lastIndex(of: ".") else { return nil }
        return String(path[path.index(after: dot)...])
    }

    /// 目录分隔符、下划线和连续空格都折叠成单个空格
    private static func spaceName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .lowercased()
    }

    private func hasAudioExtension(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return Self.audioExtensions.contains { lowered.hasSuffix("." + $0) }
    }
}

extension FileManager {
    /// 目录内（不含子目录）是否有脚本或归档：.rpy / .rpyc / .rpym / .rpymc / .rpa
    func hasScriptFiles(in directory: URL) -> Bool {
        guard let names = try? contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains {
            let lower = $0.lowercased()
            return lower.hasSuffix(".rpy") || lower.hasSuffix(".rpyc")
                || lower.hasSuffix(".rpym") || lower.hasSuffix(".rpymc")
                || lower.hasSuffix(".rpa")
        }
    }

    func children(of directory: URL) -> [String] {
        (try? contentsOfDirectory(atPath: directory.path)) ?? []
    }
}
