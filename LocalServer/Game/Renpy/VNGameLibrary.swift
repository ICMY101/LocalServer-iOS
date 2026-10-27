import Foundation

/// 库里的一部视觉小说
struct VNGame: Identifiable, Equatable {
    /// 相对游戏根目录的文件夹名，同时用作存档目录名
    var id: String
    var title: String
    var folder: URL
    var scriptCount: Int
    var archiveCount: Int

    /// 只有 .rpa 归档、没有脚本时读不出剧情
    var isPlayable: Bool { scriptCount > 0 }
}

enum VNGameError: LocalizedError {
    case noScripts
    case unsupportedPackage(String)
    case copyFailed
    case stepFailure(String, Error)
    case insufficientSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .noScripts:
            return "这个压缩包里没有找到 .rpy/.rpyc 脚本或 .rpa 归档，无法运行。"
        case .unsupportedPackage(let name):
            return "不支持导入 \(name)。请提供文件夹、.zip，或单独的 .rpa 文件。"
        case .copyFailed:
            return "复制游戏文件失败，请确认文件仍然存在且空间充足。"
        case .stepFailure(let step, let underlying):
            return "\(step)失败：\(underlying.localizedDescription)"
        case .insufficientSpace(let needed, let available):
            let gb: (Int64) -> String = { String(format: "%.1f GB", Double($0) / 1_000_000_000) }
            return "设备剩余空间不足：这次导入大约需要 \(gb(needed))，目前只剩 \(gb(available))。请清理空间后重试。"
        }
    }
}

/// 视觉小说库：扫描目录、解压导入、把整个游戏的脚本编译成一份指令表。
enum VNGameLibrary {
    static let rootFolderName = "VisualNovels"

    /// 游戏都放在 Documents/VisualNovels 下，文件标签页里也能直接看到
    static var root: URL {
        let url = FileStore.rootURL.appendingPathComponent(rootFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func games() -> [VNGame] {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            guard let assets = GameAssets.locate(from: url) else { return nil }
            return VNGame(id: url.lastPathComponent,
                          title: url.lastPathComponent,
                          folder: assets.root,
                          scriptCount: scriptCount(in: assets),
                          archiveCount: assets.archiveCount)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func assets(for game: VNGame) -> GameAssets? {
        let folder = root.appendingPathComponent(game.id, isDirectory: true)
        return GameAssets.locate(from: folder)
    }

    /// 所有脚本解析、编译成一份程序：源码里有 start 就优先用源码，否则读编译脚本。
    /// 不少发行包只留一两个 .rpy 配置脚本，剧情全在 .rpyc 里，不能让它挡住编译脚本。
    /// 文件名参与指纹，重命名或改脚本都会让旧存档失效。
    static func program(for game: VNGame, assets: GameAssets) -> (program: VNProgram?, issues: [String]) {
        let sources = defaultLanguage(assets.names(withExtension: "rpy")).sorted()
        let binaries = defaultLanguage(assets.names(withExtension: "rpyc")).sorted()

        let compiledSources = sources.isEmpty ? nil : compile(sources, assets: assets, binary: false)
        if let compiledSources, compiledSources.program?.startIndex != nil {
            return compiledSources
        }
        if !binaries.isEmpty {
            return compile(binaries, assets: assets, binary: true)
        }
        return compiledSources ?? (nil, ["没有找到 .rpy 或 .rpyc 脚本。"])
    }

    /// 默认语言的脚本：`tl/` 下除 `tl/None` 之外的目录都是翻译副本，
    /// 读进来只会白白解码（内容本来也会被跳过），发行包里这部分常常占大头。
    private static func defaultLanguage(_ names: [String]) -> [String] {
        names.filter { name in
            let key = RenPyArchive.key(name)
            return !key.hasPrefix("tl/") || key.hasPrefix("tl/none/")
        }
    }

    private static func compile(_ names: [String], assets: GameAssets,
                                binary: Bool) -> (program: VNProgram?, issues: [String]) {
        var statements: [VNStmt] = []
        var issues: [String] = []
        var parts: [(name: String, bytes: [UInt8])] = []

        for name in names {
            guard let data = assets.read(name) else {
                issues.append("读取失败：\(name)")
                continue
            }
            if binary {
                guard let script = RpycReader.read(data) else {
                    issues.append("无法解析编译脚本：\(name)")
                    continue
                }
                statements.append(contentsOf: script.statements)
                issues.append(contentsOf: script.warnings)
            } else {
                statements.append(contentsOf: RpyParser.parse(String(decoding: data, as: UTF8.self)))
            }
            parts.append((name, [UInt8](data)))
        }

        guard !parts.isEmpty else { return (nil, issues) }
        return compiled(statements, fingerprint: fingerprint(of: parts), issues: issues)
    }

    /// 可执行脚本数：源码和编译脚本都是同一批文件时取较多的那一边
    static func scriptCount(in assets: GameAssets) -> Int {
        max(assets.names(withExtension: "rpy").count,
            assets.names(withExtension: "rpyc").count)
    }

    private static func compiled(_ statements: [VNStmt], fingerprint: String,
                                 issues: [String]) -> (program: VNProgram?, issues: [String]) {
        let program = VNCompiler.compile(statements, fingerprint: fingerprint)
        var all = issues + program.warnings
        if program.startIndex == nil {
            all.append("脚本里没有 start 标签，也没有任何标签。")
        }
        return (program, all)
    }

    /// FNV-1a 64 位：不依赖 CryptoKit，跨设备、跨启动都稳定
    private static func fingerprint(of sources: [(name: String, bytes: [UInt8])]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for source in sources {
            for byte in (source.name + "\u{0}").utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            for byte in source.bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }

    // MARK: - 导入

    /// 导入一个游戏包：文件夹、.zip、单个 .rpa 或 .rpy。
    /// 压缩包先解到隐藏的临时目录，再把真正的游戏根目录挪到库里，外层壳和无关文件一起清掉。
    static func importGame(from url: URL) throws -> VNGame {
        let manager = FileManager.default
        let baseName = url.deletingPathExtension().lastPathComponent
        let name = baseName.isEmpty ? "未命名游戏" : baseName
        let destination: URL

        switch url.pathExtension.lowercased() {
        case "zip":
            try checkSpace(for: url)
            let staged = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            try step("创建临时目录") { try manager.createDirectory(at: staged, withIntermediateDirectories: true) }
            do {
                _ = try step("解压压缩包") { try ZipExtractor.extractToFolder(url, in: staged, folderName: name) }
                guard let real = gameRoot(inside: staged, depth: 3) else { throw VNGameError.noScripts }
                let target = availableFolder(named: name)
                try step("整理游戏目录") { try manager.moveItem(at: real, to: target) }
                try? manager.removeItem(at: staged)
                destination = target
            } catch {
                try? manager.removeItem(at: staged)
                throw error
            }
        case "rpa", "rpy", "rpyc":
            // 单独一个脚本或归档：补一个 game/ 目录放进去
            let folder = availableFolder(named: name)
            let gameDirectory = folder.appendingPathComponent("game", isDirectory: true)
            try step("创建游戏目录") { try manager.createDirectory(at: gameDirectory, withIntermediateDirectories: true) }
            try step("复制 \(url.lastPathComponent)") {
                try manager.copyItem(at: url, to: gameDirectory.appendingPathComponent(url.lastPathComponent))
            }
            destination = folder
        case "":
            let copied = availableFolder(named: name)
            try checkSpace(for: url)
            try step("复制游戏文件夹") { try copyRecursively(from: url, to: copied) }
            destination = try flattenIfNested(copied, name: name)
        default:
            throw VNGameError.unsupportedPackage(url.lastPathComponent)
        }

        guard let assets = GameAssets.locate(from: destination) else {
            throw VNGameError.noScripts
        }
        return VNGame(id: destination.lastPathComponent,
                      title: destination.lastPathComponent,
                      folder: assets.root,
                      scriptCount: scriptCount(in: assets),
                      archiveCount: assets.archiveCount)
    }

    /// 系统错误只说"未能保存"，补上 importGame 是哪一步出的错
    private static func step<T>(_ label: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as VNGameError { throw error }
        catch { throw VNGameError.stepFailure(label, error) }
    }

    /// 解压期间压缩包和解出来的内容同时占着空间，粗略按两倍估
    private static func checkSpace(for url: URL) throws {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return }
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage, available >= 0 else { return }
        let needed = Int64(max(size * 2, 512 * 1024 * 1024))
        if available < needed {
            throw VNGameError.insufficientSpace(needed: needed, available: available)
        }
    }

    /// 从"文件"App 选来的文件夹带安全作用域，整目录 copyItem 在不少提供方上会直接失败；
    /// 逐个文件拷，失败时也能说出是哪个文件
    static func copyRecursively(from source: URL, to target: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else {
            try step("复制 \(source.lastPathComponent)") { try manager.copyItem(at: source, to: target) }
            return
        }
        try step("创建文件夹 \(target.lastPathComponent)") {
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
        }
        let children = (try? manager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for child in children {
            try copyRecursively(from: child, to: target.appendingPathComponent(child.lastPathComponent))
        }
    }

    /// 文件夹里又套了一层游戏目录时，把里层挪到库里
    private static func flattenIfNested(_ copied: URL, name: String) throws -> URL {
        let manager = FileManager.default
        guard let real = gameRoot(inside: copied, depth: 2),
              real.standardizedFileURL != copied.standardizedFileURL else {
            return copied
        }
        let staged = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try manager.moveItem(at: real, to: staged)
        try? manager.removeItem(at: copied)
        let target = availableFolder(named: name)
        try manager.moveItem(at: staged, to: target)
        return target
    }

    static func delete(_ game: VNGame) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(game.id, isDirectory: true))
    }

    // MARK: - 目录辅助

    private static func availableFolder(named name: String) -> URL {
        let manager = FileManager.default
        let base = ZipExtractor.safeFolderName(name)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    /// 自身或最多两层子目录里，哪一层才是有脚本的游戏根目录
    private static func gameRoot(inside folder: URL, depth: Int = 2) -> URL? {
        if isGameRoot(folder) { return folder }
        guard depth > 0 else { return nil }
        for child in FileManager.default.children(of: folder) {
            let url = folder.appendingPathComponent(child, isDirectory: true)
            if let found = gameRoot(inside: url, depth: depth - 1) { return found }
        }
        return nil
    }

    private static func isGameRoot(_ url: URL) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        if manager.hasScriptFiles(in: url.appendingPathComponent("game", isDirectory: true)) { return true }
        return manager.hasScriptFiles(in: url)
    }
}
