import XCTest
@testable import LocalServer

/// `.rpyc`：容器格式（RPC4 小端槽表）、pickle 对象重建和语法树映射
final class RpycReaderTests: XCTestCase {

    private func data(_ base64: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: base64), "夹具应该是合法 base64")
    }

    private func program(from base64: String) throws -> VNProgram {
        let script = try XCTUnwrap(RpycReader.read(try data(base64)), "夹具应该能读出来")
        return VNCompiler.compile(script.statements, fingerprint: "fixture")
    }

    func testModernContainerPlaysThroughStory() throws {
        let program = try program(from: RpycFixtures.modern)
        XCTAssertEqual(Set(program.labelNames), ["start", "secret"])

        let runtime = VNRuntime(program: program)
        guard case .line(let first) = runtime.startNewGame() else {
            return XCTFail("应该从 start 的第一句开始")
        }
        XCTAssertEqual(first.text, "你好，今天也要加油。")
        XCTAssertEqual(first.speaker, "艾莉")
        XCTAssertEqual(runtime.layers["master"]?.map(\.name), ["bg room", "e happy"])

        // `points = points + 1` 在第一句之后，第二句时应已生效
        guard case .line(let second) = runtime.advance() else {
            return XCTFail("第二个 if 分支应该有一句台词")
        }
        XCTAssertEqual(second.text, "再试一次。")
        XCTAssertEqual(runtime.store.variables["points"], .int(1))

        guard case .choices(let title, let options) = runtime.advance() else {
            return XCTFail("接下来应该是菜单")
        }
        XCTAssertEqual(title, "要不要去厨房？")
        XCTAssertEqual(options.map(\.text), ["去厨房", "留下来", "偷偷吃蛋糕"])
        XCTAssertEqual(options.map(\.enabled), [true, true, false], "points > 5 不成立，最后一项不可选")

        guard case .line(let kitchen) = runtime.choose(at: 0) else {
            return XCTFail("选完应该继续剧情")
        }
        XCTAssertEqual(kitchen.text, "厨房里有蛋糕。")
        XCTAssertEqual(runtime.tracks["music"], VNTrack(file: "audio/theme.ogg", volume: 1, loop: true))

        guard case .line(let dessert) = runtime.advance() else {
            return XCTFail("visited 为真时应该统计分数")
        }
        XCTAssertEqual(dessert.text, "你吃了蛋糕，分数是 1。")

        guard case .line(let called) = runtime.advance() else {
            return XCTFail("call 之后应该进入标签参数绑定的那句")
        }
        XCTAssertEqual(called.text, "（远处传来的钟声）")

        guard case .line(let afterCall) = runtime.advance() else {
            return XCTFail("call 返回后应该继续执行下一条")
        }
        XCTAssertEqual(afterCall.text, "（远处传来钟声）")

        guard case .finished = runtime.advance() else {
            return XCTFail("return 之后剧情结束")
        }
    }

    func testSlotTwoOnlyUsesTranslatedTreeAndSkipsForeignTranslations() throws {
        let program = try program(from: RpycFixtures.slotTwoOnly)
        let runtime = VNRuntime(program: program)

        guard case .line(let first) = runtime.startNewGame() else {
            return XCTFail("应该有一句台词")
        }
        XCTAssertEqual(first.text, "槽二的台词", "槽 1 缺失时要用槽 2 的语法树")

        let says = program.ops.compactMap { op -> String? in
            if case .say(_, _, .literal(.string(let text)), _) = op { return text }
            return nil
        }
        XCTAssertFalse(says.contains { $0.contains("日本語") }, "非默认语言的翻译块必须跳过")
    }

    func testLegacyWholeFilePayload() throws {
        let program = try program(from: RpycFixtures.legacy)
        XCTAssertEqual(Set(program.labelNames), ["start", "secret"])
        let runtime = VNRuntime(program: program)
        guard case .line(let first) = runtime.startNewGame() else {
            return XCTFail("旧格式也应该能跑")
        }
        XCTAssertEqual(first.text, "你好，今天也要加油。")
    }

    func testDynamicJumpFallsBackToFirstUnreferencedLabel() throws {
        let program = try program(from: RpycFixtures.dynamicJump)
        XCTAssertTrue(program.warnings.contains { $0.contains("动态跳转") },
                      "求不出来的动态跳转要留下诊断")
        let runtime = VNRuntime(program: program)

        guard case .line(let start) = runtime.startNewGame() else {
            return XCTFail("应该先显示 start 里的台词")
        }
        XCTAssertEqual(start.text, "准备出发。")

        // game.get_start_label() 求不出来，兜底到编译顺序里第一个没有静态跳转指向的标签
        guard case .line(let chapterA) = runtime.advance() else {
            return XCTFail("动态跳转应该落到第一章")
        }
        XCTAssertEqual(chapterA.text, "第一章")

        // 这个动态跳转用变量就能求值，必须精确跳到 chapter_b
        guard case .line(let chapterB) = runtime.advance() else {
            return XCTFail("能求值的动态跳转不应该走兜底")
        }
        XCTAssertEqual(chapterB.text, "第二章")

        guard case .finished = runtime.advance() else {
            return XCTFail("章节结束后剧情结束")
        }
    }

    func testLayeredImagePicksDefaultAttributeAndKeepsPlacement() throws {
        let program = try program(from: RpycFixtures.layered)
        XCTAssertFalse(program.warnings.contains { $0.contains("分层立绘") },
                       "夹具里的 layeredimage 应该能解析")

        let runtime = VNRuntime(program: program)
        guard case .line(let first) = runtime.startNewGame() else {
            return XCTFail("应该先显示分层立绘那句")
        }
        XCTAssertEqual(first.text, "第一句")
        XCTAssertEqual(runtime.layeredParts(for: "e"), ["e body base", "e face smiling"],
                       "always 部件在前，没属性时用默认的 face")
        XCTAssertEqual(runtime.layers["master"]?.first { $0.tag == "e" }?.at, ["left"])

        guard case .line(let second) = runtime.advance() else {
            return XCTFail("换表情后应该继续念第二句")
        }
        XCTAssertEqual(second.text, "第二句")
        XCTAssertEqual(runtime.layeredParts(for: "e angry"), ["e body base", "e face angry"])
        XCTAssertEqual(runtime.layers["master"]?.first { $0.tag == "e" }?.at, ["left"],
                       "只换表情的 show 要沿用上次的 at")
    }

    /// 容器里的两段都是 zlib 流；解压坏掉时读取会直接返回 nil，先单独验证这一层
    func testFixtureZlibStreamInflates() throws {
        let bytes = try data(RpycFixtures.modern)
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        XCTAssertEqual(u32(10), 1, "槽表第一项应该是槽 1")
        let start = u32(14)
        let length = u32(18)
        let chunk = bytes.subdata(in: start..<(start + length))
        let inflated = Zlib.inflate(chunk)
        XCTAssertNotNil(inflated, "槽 1 的 zlib 流应该能解压")
        XCTAssertEqual(inflated?.first, 0x80, "解压后应是 pickle 协议 2")
    }

    func testCorruptDataIsRejected() {
        XCTAssertNil(RpycReader.read(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(RpycReader.read(Data()))
    }
}
