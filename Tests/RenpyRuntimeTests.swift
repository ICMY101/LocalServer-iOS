import XCTest
@testable import LocalServer

/// 从 .rpy 文本到可运行脚本的整条链路：解析 → 编译 → 执行 → 存档
final class RenpyRuntimeTests: XCTestCase {

    private func compile(_ source: String, fingerprint: String = "fixture") -> VNProgram {
        VNCompiler.compile(RpyParser.parse(source), fingerprint: fingerprint)
    }

    private func lineText(_ outcome: VNOutcome) -> String? {
        if case .line(let line) = outcome { return line.text }
        return nil
    }

    private func lineSpeaker(_ outcome: VNOutcome) -> String? {
        if case .line(let line) = outcome { return line.speaker }
        return nil
    }

    private func choiceOptions(_ outcome: VNOutcome) -> [VNChoice]? {
        if case .choices(_, let options) = outcome { return options }
        return nil
    }

    private func isFinished(_ outcome: VNOutcome) -> Bool {
        if case .finished = outcome { return true }
        return false
    }

    // MARK: - 编译

    func testCompileProducesLabelsAndInitOps() {
        let program = compile(Self.script)
        XCTAssertEqual(program.labelNames, ["start", "secret"])
        XCTAssertEqual(program.initOps.count, 5, "四个 define/default 加一条 image")
        XCTAssertEqual(program.index(ofLabel: "start"), program.startIndex)
        XCTAssertFalse(program.ops.isEmpty)
    }

    // MARK: - 执行

    func testPlayThroughMenuAndCall() {
        let runtime = VNRuntime(program: compile(Self.script))
        let opening = runtime.startNewGame()
        XCTAssertEqual(lineText(opening), "你好，今天也要加油。")
        XCTAssertEqual(lineSpeaker(opening), "艾莉")
        XCTAssertEqual(runtime.layers["master"]?.map { $0.name }, ["bg room", "e happy"])
        XCTAssertEqual(runtime.layers["master"]?.first?.resource, "bg/room.png")

        // points 第一次只加到 1，所以走 else 分支
        XCTAssertEqual(lineText(runtime.advance()), "再试一次。")
        XCTAssertEqual(runtime.store.variables["points"], VNValue.int(1))

        let options = choiceOptions(runtime.advance())
        XCTAssertEqual(options?.count, 3)
        XCTAssertEqual(options?.last?.enabled, false, "if points > 5 不成立时应该不可选")
        XCTAssertTrue(runtime.awaitingChoice)

        XCTAssertEqual(lineText(runtime.choose(at: 0)), "厨房里有蛋糕。")
        XCTAssertEqual(runtime.store.variables["visited"], VNValue.bool(true))
        XCTAssertEqual(lineText(runtime.advance()), "你吃了蛋糕，分数是 1。")
        // call secret 里面只有一句，返回后接着念旁白
        XCTAssertEqual(lineText(runtime.advance()), "（远处传来钟声）")
        XCTAssertTrue(isFinished(runtime.advance()))
    }

    func testOtherMenuItemKeepsDefaults() {
        let runtime = VNRuntime(program: compile(Self.script))
        _ = runtime.startNewGame()
        _ = runtime.advance()
        _ = runtime.advance()
        XCTAssertEqual(lineText(runtime.choose(at: 1)), "那我们就待在这儿。")
        XCTAssertEqual(runtime.store.variables["visited"], VNValue.bool(false))
        XCTAssertEqual(runtime.store.variables["cake"], VNValue.int(0))
        // visited 为假时 `{}` 插值那句不出现，直接进 call
        XCTAssertEqual(lineText(runtime.advance()), "（远处传来钟声）")
    }

    func testDisabledItemCannotBeChosen() {
        let runtime = VNRuntime(program: compile(Self.script))
        _ = runtime.startNewGame()
        _ = runtime.advance()
        _ = runtime.advance()
        let position = runtime.pc
        XCTAssertEqual(choiceOptions(runtime.choose(at: 2))?.count, 3, "禁用的选项点了应该原地不动")
        XCTAssertEqual(runtime.pc, position)
        XCTAssertTrue(runtime.awaitingChoice)
    }

    func testRepeatJumpWithCounter() {
        let program = compile("""
        define clicks = 0

        label start:
            "第一次"
        label again:
            $ clicks = clicks + 1
            if clicks < 3:
                jump again
            "点了 {clicks} 次"
            return
        """)
        let runtime = VNRuntime(program: program)
        XCTAssertEqual(lineText(runtime.startNewGame()), "第一次")
        XCTAssertEqual(lineText(runtime.advance()), "点了 3 次")
        XCTAssertTrue(isFinished(runtime.advance()))
    }

    func testWhileLoopRunsToCompletion() {
        let program = compile("""
        default steps = 0

        label start:
            while steps < 3:
                $ steps = steps + 1
            "走了 {steps} 步"
            return
        """)
        let runtime = VNRuntime(program: program)
        XCTAssertEqual(lineText(runtime.startNewGame()), "走了 3 步")
    }

    func testMissingLabelFailsInsteadOfSilentlySkipping() {
        let runtime = VNRuntime(program: compile("""
        label start:
            jump nowhere
        """))
        guard case .failed(let message) = runtime.startNewGame() else {
            return XCTFail("跳到不存在的标签应该报错")
        }
        XCTAssertTrue(message.contains("找不到标签"), message)
    }

    func testImageDefinitionIsUsedByShow() {
        let runtime = VNRuntime(program: compile("""
        image bg park = "bg/park.jpg"

        label start:
            scene bg park
            show e smile at left
            "在这里等一会儿。"
        """))
        _ = runtime.startNewGame()
        XCTAssertEqual(runtime.layers["master"]?.first?.resource, "bg/park.jpg")
        XCTAssertEqual(runtime.layers["master"]?.last?.name, "e smile")
    }

    // MARK: - 存档

    func testSaveLoadRoundTripKeepsPositionAndVariables() throws {
        let program = compile(Self.script, fingerprint: "脚本指纹")
        let runtime = VNRuntime(program: program)
        _ = runtime.startNewGame()
        _ = runtime.advance()
        _ = runtime.choose(at: 0)
        XCTAssertEqual(lineText(runtime.advance()), "你吃了蛋糕，分数是 1。")

        let restored = VNRuntime(program: program)
        XCTAssertTrue(restored.restore(try VNSaveState.decode(runtime.saveState().encoded())))
        XCTAssertEqual(lineText(restored.advance()), "（远处传来钟声）")
        XCTAssertEqual(restored.store.variables["points"], VNValue.int(1))
        XCTAssertEqual(restored.store.variables["visited"], VNValue.bool(true))
        XCTAssertEqual(restored.layers["master"]?.count, 2)
    }

    func testRestoreRejectsDifferentScript() {
        let runtime = VNRuntime(program: compile(Self.script, fingerprint: "A"))
        _ = runtime.startNewGame()
        let state = runtime.saveState()

        let other = VNRuntime(program: compile(Self.script, fingerprint: "B"))
        _ = other.startNewGame()
        let positionBefore = other.pc
        XCTAssertFalse(other.restore(state), "脚本变了就不能用旧存档")
        XCTAssertEqual(other.pc, positionBefore, "拒绝读档时不该改动状态")
    }

    func testSaveInsideCalledLabelKeepsReturnStack() throws {
        let program = compile("""
        label start:
            call greeting
            "结束"

        label greeting:
            "你好"
            return
        """, fingerprint: "调用栈")
        let runtime = VNRuntime(program: program)
        XCTAssertEqual(lineText(runtime.startNewGame()), "你好")
        XCTAssertEqual(runtime.callStack.count, 1)

        let restored = VNRuntime(program: program)
        XCTAssertTrue(restored.restore(try VNSaveState.decode(runtime.saveState().encoded())))
        XCTAssertEqual(restored.callStack.count, 1)
        XCTAssertEqual(lineText(restored.advance()), "结束")
    }

    func testSaveWhileMenuIsWaitingRestoresTheSameChoices() throws {
        let program = compile(Self.script, fingerprint: "菜单存档")
        let runtime = VNRuntime(program: program)
        _ = runtime.startNewGame()
        _ = runtime.advance()
        _ = runtime.advance()
        XCTAssertTrue(runtime.awaitingChoice)

        let restored = VNRuntime(program: program)
        XCTAssertTrue(restored.restore(try VNSaveState.decode(runtime.saveState().encoded())))
        XCTAssertTrue(restored.awaitingChoice)
        XCTAssertEqual(choiceOptions(restored.outcome)?.count, 3)
        XCTAssertEqual(lineText(restored.choose(at: 1)), "那我们就待在这儿。")
    }

    // MARK: - 脚本

    static let script = """
    define e = Character("艾莉")
    define points = 0
    default visited = False
    default cake = 0

    image bg room = "bg/room.png"

    label start:
        scene bg room
        show e happy
        e "你好，今天也要加油。"
        $ points = points + 1
        if points >= 2:
            e "你已经很努力了。"
        else:
            e "再试一次。"
        menu:
            "要不要去厨房？"
            "去厨房":
                $ visited = True
                e "厨房里有蛋糕。"
            "留下来":
                e "那我们就待在这儿。"
            "偷偷吃蛋糕" if points > 5:
                $ cake = cake + 1
        if visited:
            e "你吃了蛋糕，分数是 {points}。"
        call secret
        "（远处传来钟声）"
        return

    label secret:
        return
    """
}
