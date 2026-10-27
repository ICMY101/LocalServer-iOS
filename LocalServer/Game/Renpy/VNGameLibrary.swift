import Foundation

/// 库里的一部视觉小说
struct VNGame: Identifiable, Equatable {
    /// 相对游戏根目录的文件夹名，同时用作存档目录名
    var id: String
    var title: String
    var folder: URL
    var scriptCount: Int
    var archiveCount: Int

    /// 没有 .rpy 就只有 .rpa，脚本读不出来
    var isPlayable: Bool { scriptCount > 0 }
}

enum VNGameError: LocalizedError {
    case noScripts
    case unsupportedPackage(String)
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .noScripts:
            return "这个压缩包里没有找到 .rpy 脚本，可能只有 .rpyc 编译文件，暂时无法运行。"
        case .unsupportedPackage(let name):
            return "不支持导入 \(name)。请提供文件夹、.zip，或单独的 .rpa 文件。"
        case .copyFailed:
            return "复制游戏文件失败，请确认文件仍然存在且空间充足。"
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
                          scriptCount: assets.names(withExtension: "rpy").count,
                          archiveCount: assets.archiveCount)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func assets(for game: VNGame) -> GameAssets? {
        let folder = root.appendingPathComponent(game.id, isDirectory: true)
        return GameAssets.locate(from: folder)
    }

    /// 把所有 .rpy 解析、编译成一份程序。
    /// 文件名参与指纹，重命名或改脚本都会让旧存档失效。
    static func program(for game: VNGame, assets: GameAssets) -> (program: VNProgram?, issues: [String]) {
        let names = assets.names(withExtension: "rpy").sorted()
        var sources: [(name: String, text: String)] = []
        for name in names {
            if let text = assets.text(name) { sources.append((name, text)) }
        }
        guard !sources.isEmpty else {
            return (nil, ["没有可读的 .rpy 脚本，可能只有 .rpa 归档或 .rpyc 编译文件。"])
        }

        var statements: [VNStmt] = []
        for source in sources {
            statements.append(contentsOf: RpyParser.parse(source.text))
        }
        let fingerprint = fingerprint(of: sources)
        let program = VNCompiler.compile(statements, fingerprint: fingerprint)
        var issues = program.warnings
        if program.startIndex == nil {
            issues.append("脚本里没有 start 标签，也没有任何标签。")
        }
        return (program, issues)
    }

    /// FNV-1a 64 位：不依赖 CryptoKit，跨设备、跨启动都稳定
    private static func fingerprint(of sources: [(name: String, text: String)]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for source in sources {
            for byte in (source.name + "\u{0}" + source.text).utf8 {
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
            let staged = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: staged, withIntermediateDirectories: true)
            do {
                _ = try ZipExtractor.extractToFolder(url, in: staged, folderName: name)
                guard let real = gameRoot(inside: staged, depth: 3) else { throw VNGameError.noScripts }
                let target = availableFolder(named: name)
                try manager.moveItem(at: real, to: target)
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
            try manager.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
            try manager.copyItem(at: url, to: gameDirectory.appendingPathComponent(url.lastPathComponent))
            destination = folder
        case "":
            let copied = availableFolder(named: name)
            try manager.copyItem(at: url, to: copied)
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
                      scriptCount: assets.names(withExtension: "rpy").count,
                      archiveCount: assets.archiveCount)
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
