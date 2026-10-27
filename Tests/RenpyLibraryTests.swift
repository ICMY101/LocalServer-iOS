import XCTest
@testable import LocalServer

/// 游戏库与存档目录：脚本组装、指纹稳定性、存档读写
final class RenpyLibraryTests: XCTestCase {

    private func makeGame(_ files: [String: String]) throws -> (TemporaryDirectory, GameAssets) {
        let temp = try TemporaryDirectory()
        for (path, content) in files {
            try temp.write(path, content)
        }
        let assets = try XCTUnwrap(GameAssets.locate(from: temp.url), "临时目录应该被识别成游戏")
        return (temp, assets)
    }

    func testProgramCombinesEveryScriptFile() throws {
        let (_, assets) = try makeGame([
            "game/script.rpy": "label start:\n    \"第一句\"\n    return\n",
            "game/extra.rpy": "label extra:\n    \"第二句\"\n    return\n"
        ])
        let game = VNGame(id: "demo", title: "demo", folder: assets.root,
                          scriptCount: 2, archiveCount: 0)
        let result = VNGameLibrary.program(for: game, assets: assets)
        let program = try XCTUnwrap(result.program)
        XCTAssertEqual(Set(program.labelNames), ["start", "extra"])
        XCTAssertNotNil(program.startIndex)

        let runtime = VNRuntime(program: program)
        guard case .line(let line) = runtime.startNewGame() else {
            return XCTFail("应该从 start 开始")
        }
        XCTAssertEqual(line.text, "第一句")
    }

    func testFingerprintChangesWithScriptContent() throws {
        let (_, assets) = try makeGame(["game/script.rpy": "label start:\n    \"一\"\n"])
        let game = VNGame(id: "demo", title: "demo", folder: assets.root,
                          scriptCount: 1, archiveCount: 0)
        let first = VNGameLibrary.program(for: game, assets: assets).program?.fingerprint
        let again = VNGameLibrary.program(for: game, assets: assets).program?.fingerprint
        XCTAssertEqual(first, again, "同一份脚本的指纹必须稳定")

        let (_, changedAssets) = try makeGame(["game/script.rpy": "label start:\n    \"二\"\n"])
        let changed = VNGameLibrary.program(for: game, assets: changedAssets).program?.fingerprint
        XCTAssertNotEqual(first, changed)
    }

    func testImageDefinitionPathWithExtensionIsReadable() throws {
        let (_, assets) = try makeGame([
            "game/script.rpy": "image bg room = \"bg/room.png\"\n\nlabel start:\n    scene bg room\n",
            "game/bg/room.png": "not-a-real-png"
        ])
        XCTAssertNotNil(assets.imageData(named: "bg/room.png"), "定义里写全路径时应该直接命中")
    }

    func testGameWithOnlyArchiveIsNotPlayable() throws {
        let temp = try TemporaryDirectory()
        let empty = temp.url.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try temp.write("empty/game/story.rpa", "RPA-3.0 0000000000000000 deadbeef\n")
        let assets = try XCTUnwrap(GameAssets.locate(from: empty))
        let game = VNGame(id: "empty", title: "empty", folder: assets.root,
                          scriptCount: 0, archiveCount: assets.archiveCount)
        let result = VNGameLibrary.program(for: game, assets: assets)
        XCTAssertNil(result.program)
        XCTAssertFalse(result.issues.isEmpty)
    }

    // MARK: - 存档目录

    func testSaveStoreRoundTripAndSlots() throws {
        let source = "label start:\n    \"你好\"\n    return\n"
        let program = VNCompiler.compile(RpyParser.parse(source), fingerprint: "store")
        let runtime = VNRuntime(program: program)
        guard case .line = runtime.startNewGame() else { return XCTFail("应该有一句台词") }

        let store = VNSaveStore(gameID: "test-\(UUID().uuidString)")
        XCTAssertFalse(store.hasSave("1"))
        try store.write(runtime.saveState(), slot: "1")

        let slot = try XCTUnwrap(store.slots().first { $0.id == "1" })
        XCTAssertFalse(slot.isEmpty)
        XCTAssertEqual(slot.preview, "你好")
        XCTAssertEqual(slot.label, "start")

        let state = try XCTUnwrap(store.read("1"))
        let restored = VNRuntime(program: program)
        XCTAssertTrue(restored.restore(state))

        store.delete("1")
        XCTAssertFalse(store.hasSave("1"))
        XCTAssertNil(store.slots().first { $0.id == "1" }?.savedAt)
    }

    func testNewestPrefersLatestSave() throws {
        let program = VNCompiler.compile(RpyParser.parse("label start:\n    \"你好\"\n"), fingerprint: "newest")
        let runtime = VNRuntime(program: program)
        _ = runtime.startNewGame()

        let store = VNSaveStore(gameID: "test-\(UUID().uuidString)")
        XCTAssertNil(store.newest())
        var older = runtime.saveState()
        older.savedAt = Date(timeIntervalSince1970: 1_000)
        try store.write(older, slot: VNSaveSlot.autoID)
        var newer = runtime.saveState()
        newer.savedAt = Date(timeIntervalSince1970: 2_000)
        try store.write(newer, slot: "3")
        XCTAssertEqual(store.newest()?.savedAt, newer.savedAt)
    }
}
