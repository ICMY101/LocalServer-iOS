import Foundation

/// 一句台词
struct VNLine: Codable, Equatable {
    var speaker: String?
    var text: String
    var attributes: [String]
}

/// 菜单里可点的一项
struct VNChoice {
    var text: String
    /// 选中后跳到的指令下标
    var target: Int
    /// `if` 条件不成立时显示但不可点
    var enabled: Bool
}

/// 一次推进之后的结果：播放器界面只需要根据它渲染
enum VNOutcome {
    case line(VNLine)
    case choices(title: String?, options: [VNChoice])
    case finished
    case failed(String)
}

/// 显示层上的一张图
struct VNShownImage: Codable, Equatable {
    /// 脚本里的图像名，例如 `e happy`
    var name: String
    /// `image` 语句解析出来的资源路径
    var resource: String?
    /// `at` 定位变换；为空表示沿用这个标签上一次的位置
    var at: [String]? = nil

    /// Ren'Py 的图像标签是名字的第一个词：`show e happy` 的标签是 `e`。
    /// 同一个标签再 show 一次是替换，不是叠加。
    var tag: String { Self.tag(of: name) }

    static func tag(of name: String) -> String {
        name.split(separator: " ", maxSplits: 1).first.map(String.init) ?? name
    }
}

/// Ren'Py 定位变换换算出的放置参数，坐标都是相对游戏画面的比例。
struct VNPlacement: Equatable {
    var xpos: Double = 0
    var ypos: Double = 0
    var xanchor: Double = 0
    var yanchor: Double = 0
    var zoom: Double = 1

    /// 没有 `at` 时的默认位置：左上角，原始大小
    static let natural = VNPlacement()

    /// 只认识常见的定位变换；调色、动画类变换（noon、bounce）忽略。
    /// 数值取自游戏的 scripts/system/transforms.rpy。
    static func from(at names: [String]?) -> VNPlacement {
        guard let first = names?.first(where: { !$0.isEmpty }) else { return .natural }
        let (name, x, anchor, y) = split(first)
        var placement: VNPlacement
        switch name {
        case "left":
            placement = VNPlacement(xpos: 0.22, ypos: -0.04, xanchor: 0.5, yanchor: 0, zoom: 0.75)
        case "right":
            placement = VNPlacement(xpos: 0.78, ypos: -0.04, xanchor: 0.5, yanchor: 0, zoom: 0.75)
        case "center":
            placement = VNPlacement(xpos: 0.5, ypos: -0.04, xanchor: 0.5, yanchor: 0, zoom: 0.75)
        case "closeleft":
            placement = VNPlacement(xpos: 0.22, ypos: -0.1, xanchor: 0.5, yanchor: 0, zoom: 1)
        case "closeright":
            placement = VNPlacement(xpos: 0.78, ypos: -0.1, xanchor: 0.5, yanchor: 0, zoom: 1)
        case "closecenter":
            placement = VNPlacement(xpos: 0.5, ypos: -0.1, xanchor: 0.5, yanchor: 0, zoom: 1)
        case "closestleft", "closestcenter", "closestright":
            placement = VNPlacement(xpos: 0.5, ypos: -0.15, xanchor: 0.5, yanchor: 0, zoom: 1.25)
        default:
            placement = .natural
        }
        if let value = x { placement.xpos = value }
        if let value = anchor { placement.xanchor = value }
        if let value = y { placement.ypos = value }
        return placement
    }

    /// `right(.85)`、`left(xa=-0.7)` → (名字, 位置参数覆盖值)
    private static func split(_ text: String)
        -> (name: String, x: Double?, xanchor: Double?, y: Double?) {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else {
            return (text.trimmingCharacters(in: .whitespaces).lowercased(), nil, nil, nil)
        }
        let name = String(text[..<open]).trimmingCharacters(in: .whitespaces).lowercased()
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        var x: Double?
        var xanchor: Double?
        var y: Double?
        for piece in inner.split(separator: ",") {
            let parts = piece.split(separator: "=", maxSplits: 1)
            let key = parts.count == 2
                ? String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased() : nil
            let raw = parts.count == 2 ? parts[1] : parts[0]
            guard let value = Double(String(raw).trimmingCharacters(in: .whitespaces)) else { continue }
            if key == nil || key == "x" {
                if x == nil { x = value }
            } else if key == "xa" {
                xanchor = value
            } else if key == "y" {
                y = value
            }
        }
        return (name, x, xanchor, y)
    }
}

/// 一条音频通道
struct VNTrack: Codable, Equatable {
    var file: String?
    var volume: Double
    var loop: Bool
}

/// 一次 `call` 留下的栈帧
struct VNFrame: Codable, Equatable {
    var returnPc: Int
    /// 标签参数在调用前的值，返回时恢复
    var savedValues: [String: VNValue]
}

/// 一个存档点的全部内容。
///
/// 指令表不进存档，只存 pc 加状态，所以 `fingerprint` 不一致时必须拒绝读取。
struct VNSaveState: Codable {
    var fingerprint: String
    var pc: Int
    var variables: [String: VNValue]
    var characters: [String: VNCharacter]
    var layers: [String: [VNShownImage]]
    var tracks: [String: VNTrack]
    var callStack: [VNFrame]
    /// 正在显示的这句台词，读档后直接接着看
    var line: VNLine?
    /// 存档点所在的标签，列表里给人看的
    var label: String?
    /// 最近一句台词，用作存档预览
    var preview: String?
    var savedAt: Date

    static func decode(_ data: Data) throws -> VNSaveState {
        try VNJSON.decoder.decode(VNSaveState.self, from: data)
    }

    func encoded() throws -> Data {
        try VNJSON.encoder.encode(self)
    }
}

/// 运行时与界面之间传递的结构都是手写 CodingKey 的，编解码规则放在一处
enum VNJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// 脚本执行器：从 pc 开始跑指令，遇到需要玩家操作的语句就停下。
final class VNRuntime {
    let program: VNProgram
    let store: VNStore
    private let evaluator: VNEvaluator

    private(set) var pc: Int = 0
    private(set) var outcome: VNOutcome = .finished
    private(set) var lastLine: VNLine?
    private(set) var awaitingChoice = false
    private(set) var callStack: [VNFrame] = []

    /// 图层名 → 从后到前的图像
    private(set) var layers: [String: [VNShownImage]] = [:]
    /// 通道名 → 正在放的音频
    private(set) var tracks: [String: VNTrack] = [:]
    /// `image` 语句定义的图像名 → 资源
    private(set) var imageResources: [String: String] = [:]

    /// 界面上显示的选项，顺序和这里的下标一一对应
    private(set) var choices: [VNChoice] = []

    init(program: VNProgram) {
        self.program = program
        self.store = VNStore()
        self.evaluator = VNEvaluator(store: store)
    }

    var isFinished: Bool {
        if case .finished = outcome { return true }
        return false
    }

    var failureReason: String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }

    /// 存档列表用的预览文本
    var preview: String? {
        guard let line = lastLine else { return nil }
        guard let speaker = line.speaker else { return line.text }
        return "\(speaker)：\(line.text)"
    }

    // MARK: - 开始与推进

    /// 新游戏：跑 init 段，然后把 pc 放到 `start`
    @discardableResult
    func startNewGame() -> VNOutcome {
        store.restore(variables: [:], characters: [:])
        layers.removeAll()
        tracks.removeAll()
        callStack.removeAll()
        imageResources.removeAll()
        choices.removeAll()
        awaitingChoice = false
        lastLine = nil
        for op in program.initOps {
            // 发行包的 define 里常出现 Movie、Fade、游戏自定义函数等我们求不出来的值；
            // init 只是打底，跳过即可，不能让整个游戏起不来
            _ = execute(op)
        }
        guard let start = program.startIndex else {
            return fail("脚本里没有可用的标签")
        }
        pc = start
        return advance()
    }

    /// 玩家点了继续：往后跑到下一句台词或下一个菜单
    @discardableResult
    func advance() -> VNOutcome {
        if awaitingChoice { return outcome }

        var steps = 0
        while true {
            // 失控的 while 不该把界面卡死
            steps += 1
            if steps > 200_000 { return fail("脚本执行步数超限，可能存在死循环") }
            guard pc >= 0, pc < program.ops.count else { return finish() }

            let op = program.ops[pc]
            switch op {
            case .end:
                return finish()
            case .problem(let message):
                return fail(message)
            case .say(let character, let who, let text, let attributes):
                lastLine = VNLine(speaker: speaker(character: character, who: who),
                                  text: VNText.substitute(literalText(text), using: evaluator),
                                  attributes: attributes)
                // 已经显示出来的这句不再重复；存档里靠 line 字段还原它
                pc += 1
                outcome = .line(lastLine!)
                return outcome
            case .menu(let title, let items):
                return presentMenu(title: title, items: items)
            case .jump(let target):
                pc = target
            case .jumpExpression(let expression, let fallback, _):
                if let name = evaluator.value(of: expression)?.stringValue,
                   let target = program.index(ofLabel: name) {
                    pc = target
                } else {
                    pc = fallback
                }
            case .jumpIf(let condition, let target):
                pc = evaluator.truth(of: condition) ? target : pc + 1
            case .jumpIfFalse(let condition, let target):
                pc = evaluator.truth(of: condition) ? pc + 1 : target
            case .call(let target, let parameters, let arguments):
                pc = performCall(target: target, parameters: parameters, arguments: arguments)
            case .returnFromCall:
                guard let frame = callStack.popLast() else { return finish() }
                for (name, value) in frame.savedValues { store.variables[name] = value }
                pc = frame.returnPc
            default:
                if let message = execute(op) { return fail(message) }
                pc += 1
            }
        }
    }

    /// 玩家点了第 index 个选项（顺序和 `choices` 一致）
    @discardableResult
    func choose(at index: Int) -> VNOutcome {
        guard awaitingChoice, index >= 0, index < choices.count, choices[index].enabled else {
            return outcome
        }
        pc = choices[index].target
        choices.removeAll()
        awaitingChoice = false
        return advance()
    }

    private func presentMenu(title: VNExpr?, items: [VNMenuOption]) -> VNOutcome {
        let visible = items.filter { item in
            item.showIf == nil || evaluator.truth(of: item.showIf!)
        }
        // 全是 `showif` 假的话这个菜单等于没内容，直接跳过
        guard !visible.isEmpty else {
            pc += 1
            return advance()
        }
        choices = visible.map { item in
            VNChoice(text: VNText.substitute(literalText(item.text), using: evaluator),
                     target: item.target,
                     enabled: item.condition == nil || evaluator.truth(of: item.condition!))
        }
        let resolvedTitle = title.flatMap { expression -> String? in
            let text = VNText.substitute(literalText(expression), using: evaluator)
            return text.isEmpty ? nil : text
        }
        awaitingChoice = true
        outcome = .choices(title: resolvedTitle, options: choices)
        return outcome
    }

    // MARK: - 指令执行

    /// 只产生副作用的指令；返回非 nil 表示出错信息
    private func execute(_ op: VNOp) -> String? {
        switch op {
        case .assign(let name, let expression):
            guard let value = evaluator.value(of: expression) else {
                return "无法计算 \(name) 的值"
            }
            store.variables[name] = value
            if let character = evaluator.characterDefinition(of: expression) {
                store.setCharacter(character, for: name)
            }
        case .initialize(let name, let expression):
            guard let value = evaluator.value(of: expression) else {
                return "无法计算 \(name) 的初值"
            }
            store.initialize(name, to: value)
            if let character = evaluator.characterDefinition(of: expression) {
                store.setCharacter(character, for: name)
            }
        case .image(let name, let expression):
            if let path = evaluator.value(of: expression)?.stringValue {
                imageResources[name] = path
            }
        case .scene(let name, let layer):
            layers[layer] = name.map { [shown(named: $0)] } ?? []
        case .show(let name, let expression, let layer, let at):
            var images = layers[layer] ?? []
            let tag = VNShownImage.tag(of: name)
            let inherited = images.first { $0.tag == tag }?.at
            images.removeAll { $0.tag == tag }
            var image = shown(named: name)
            if let expression, let value = evaluator.value(of: expression), case .string(let path) = value {
                image.resource = path
            }
            // 只换表情不写 at 时保持原地不动，和 Ren'Py 的显示列表一致
            image.at = at.isEmpty ? inherited : at
            images.append(image)
            layers[layer] = images
        case .hide(let name, let layer):
            let tag = VNShownImage.tag(of: name)
            layers[layer] = (layers[layer] ?? []).filter { $0.tag != tag }
        case .play(let channel, let file, let volume, let loop):
            let path = file.flatMap { expression -> String? in
                if let text = evaluator.value(of: expression)?.stringValue { return text }
                // Ren'Py 允许裸词文件名（`play music porch_swing_days`），求不出来时按字面量用
                if case .variable(let name) = expression { return name }
                return nil
            }
            tracks[channel] = VNTrack(file: path, volume: volume, loop: loop)
        case .stop(let channel):
            tracks[channel] = VNTrack(file: nil, volume: 0, loop: false)
        case .expression(let expression):
            _ = evaluator.value(of: expression)
        case .pause:
            // 定长停顿交给界面处理，运行时不等
            break
        default:
            break
        }
        return nil
    }

    private func performCall(target: Int, parameters: [String], arguments: [VNExpr]) -> Int {
        var saved: [String: VNValue] = [:]
        for (index, name) in parameters.enumerated() {
            saved[name] = store.variables[name]
            if index < arguments.count, let value = evaluator.value(of: arguments[index]) {
                store.variables[name] = value
            } else {
                store.variables[name] = .none
            }
        }
        callStack.append(VNFrame(returnPc: pc + 1, savedValues: saved))
        return target
    }

    private func shown(named name: String) -> VNShownImage {
        VNShownImage(name: name, resource: imageResources[name])
    }

    /// 分层立绘：按图像名和属性选出要叠加的部件；不是分层图像时返回 nil。
    /// `show hana angry` 只换 face 组，其余组保持默认属性。
    func layeredParts(for name: String) -> [String]? {
        guard let definition = program.layeredImage(named: name) else { return nil }
        let attributes = Set(name.lowercased().split(separator: " ").dropFirst().map(String.init))
        var parts: [String] = []
        for entry in definition.entries {
            switch entry {
            case .always(let expression):
                if let part = resolvedImageName(of: expression) { parts.append(part) }
            case .group(let group):
                let selected = group.attributes.first { attributes.contains($0.name.lowercased()) }
                    ?? group.attributes.first { $0.isDefault }
                if let selected, let part = resolvedImageName(of: selected.image) {
                    parts.append(part)
                }
            }
        }
        return parts
    }

    /// `"hana body base" + FG_CEN` 里的变量求不出来时，退回字符串字面量部分
    private func resolvedImageName(of expression: VNExpr) -> String? {
        var current = expression
        while true {
            if let text = evaluator.value(of: current)?.stringValue, !text.isEmpty { return text }
            guard case .binary("+", let left, _) = current else { break }
            current = left
        }
        if case .literal(let value) = current, let text = value.stringValue, !text.isEmpty { return text }
        return nil
    }

    private func speaker(character: VNExpr?, who: String?) -> String? {
        if let character, let value = evaluator.value(of: character),
           case .opaque(let name) = value, !name.isEmpty {
            return name
        }
        return store.displayName(forVariable: who, literal: who)
    }

    /// 台词文本的原始形态：解析器把它存成字符串字面量，`{}` 交给 VNText
    private func literalText(_ expression: VNExpr) -> String {
        if case .literal(let value) = expression { return value.displayText }
        return evaluator.value(of: expression)?.displayText ?? ""
    }

    private func finish() -> VNOutcome {
        awaitingChoice = false
        choices.removeAll()
        outcome = .finished
        return outcome
    }

    private func fail(_ message: String) -> VNOutcome {
        awaitingChoice = false
        choices.removeAll()
        outcome = .failed(message)
        return outcome
    }

    // MARK: - 存档

    /// 当前 pc 所属的标签，存档列表显示用
    var currentLabel: String? {
        program.label(containingPc: pc)
    }

    func saveState() -> VNSaveState {
        VNSaveState(fingerprint: program.fingerprint,
                    pc: pc,
                    variables: store.variables,
                    characters: store.characterSnapshot(),
                    layers: layers,
                    tracks: tracks,
                    callStack: callStack,
                    line: lastLine,
                    label: currentLabel,
                    preview: preview,
                    savedAt: Date())
    }

    /// 读档。指纹不匹配或 pc 越界时返回 false，且完全不改动当前状态。
    @discardableResult
    func restore(_ state: VNSaveState) -> Bool {
        guard state.fingerprint == program.fingerprint,
              state.pc >= 0, state.pc < program.ops.count else { return false }

        store.restore(variables: state.variables, characters: state.characters)
        layers = state.layers
        tracks = state.tracks
        callStack = state.callStack
        lastLine = state.line
        pc = state.pc
        refreshImageResources()

        // pc 正好停在菜单上说明存档时就在等选项
        if case .menu(let title, let items) = program.ops[pc] {
            _ = presentMenu(title: title, items: items)
            return true
        }
        choices.removeAll()
        awaitingChoice = false
        outcome = state.line.map { VNOutcome.line($0) } ?? .finished
        return true
    }

    /// init 段的 `image` 定义不写进存档，读档后按当前变量重算一遍
    private func refreshImageResources() {
        imageResources.removeAll()
        for op in program.initOps {
            if case .image(let name, let expression) = op,
               let path = evaluator.value(of: expression)?.stringValue {
                imageResources[name] = path
            }
        }
    }
}
