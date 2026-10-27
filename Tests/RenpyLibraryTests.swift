import XCTest
@testable import LocalServer

/// 游戏库与存档目录：脚本组装、指纹稳定性、存档读写
final class RenpyLibraryTests: XCTestCase {

    /// 临时目录一旦释放就会删掉文件，必须在整个用例期间持有
    private var retained: [TemporaryDirectory] = []

    private func makeGame(_ files: [String: String]) throws -> (TemporaryDirectory, GameAssets) {
        let temp = try TemporaryDirectory()
        retained.append(temp)
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
        XCTAssertNotNil(assets.imagePath(named: "bg/room.png"), "定义里写全路径时应该直接命中")
    }

    func testAutomaticImageAndAudioNames() throws {
        let temp = try TemporaryDirectory()
        retained.append(temp)
        try temp.write("game/script.rpy", "label start:\n    return\n")
        try temp.write("game/images/bg/home_front_night.webp", Data([1, 2, 3]))
        try temp.write("game/images/fg/hana/face_smiling.webp", Data([4]))
        try temp.write("game/audio/bgm/porch_swing_days.ogg", Data([5]))
        let assets = try XCTUnwrap(GameAssets.locate(from: temp.url))

        let room = try XCTUnwrap(assets.imagePath(named: "bg home front night"))
        XCTAssertFalse(assets.isForegroundImage(at: room), "背景要铺满整屏")
        let face = try XCTUnwrap(assets.imagePath(named: "fg hana face smiling"))
        XCTAssertTrue(assets.isForegroundImage(at: face), "fg/ 下的立绘要按变换摆放，不能拉满")
        XCTAssertNotNil(assets.audioData(named: "porch_swing_days"), "裸文件名应能找到 audio/bgm 下的音乐")
        XCTAssertNotNil(assets.audioData(named: "bgm/porch_swing_days"))
        XCTAssertNil(assets.imagePath(named: "bg not here"))
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

    func testObfuscatedArchiveIsReadable() throws {
        let temp = try TemporaryDirectory()
        retained.append(temp)
        let payload = try XCTUnwrap(Data(base64Encoded: ArchiveFixtures.obfuscated))
        let url = try temp.write("game/demo.rpa", payload)

        let archive = try XCTUnwrap(RenPyArchive.open(url: url), "魔数被改过、索引是 7 元组的归档也要能打开")
        XCTAssertTrue(archive.contains("scripts/scenario/start.rpyc"))
        XCTAssertEqual(archive.data(for: "images/bg room.png"), Data("not-a-real-png".utf8))
    }

    func testStraySourceFileDoesNotShadowCompiledScripts() throws {
        // 发行包常常只留一个没有标签的配置脚本，剧情全在 .rpyc 里
        let temp = try TemporaryDirectory()
        retained.append(temp)
        let payload = try XCTUnwrap(Data(base64Encoded: ArchiveFixtures.obfuscated))
        try temp.write("game/scripts.rpa", payload)
        try temp.write("game/conversion_tracking.rpy", "define config.name = \"Demo\"\n")

        let assets = try XCTUnwrap(GameAssets.locate(from: temp.url))
        XCTAssertEqual(VNGameLibrary.scriptCount(in: assets), 1)
        let game = VNGame(id: "demo", title: "demo", folder: assets.root,
                          scriptCount: 1, archiveCount: assets.archiveCount)
        let result = VNGameLibrary.program(for: game, assets: assets)
        let program = try XCTUnwrap(result.program, result.issues.joined(separator: "\n"))
        XCTAssertNotNil(program.startIndex, "剧情应该来自归档里的编译脚本")

        let runtime = VNRuntime(program: program)
        guard case .line(let first) = runtime.startNewGame() else {
            return XCTFail("应该能开始播放")
        }
        XCTAssertEqual(first.text, "准备出发。")
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
        XCTAssertNotNil(slot.progressText(totalSteps: program.ops.count), "存档位置要能算出完成度")
        XCTAssertNil(slot.progressText(totalSteps: 0), "脚本长度未知时不显示百分比")

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
