import Foundation

/// 菜单里的一项。target 指向该项正文的第一条指令。
struct VNMenuOption {
    var text: VNExpr
    /// `if 条件`：不满足时不可选
    var condition: VNExpr?
    /// `showif 条件`：不满足时不显示
    var showIf: VNExpr?
    var target: Int
}

/// 编译后的指令。索引全部是扁平的整数，存档只需要记一个 pc。
enum VNOp {
    case say(character: VNExpr?, who: String?, text: VNExpr, attributes: [String])
    case menu(title: VNExpr?, items: [VNMenuOption])
    case jump(Int)
    case jumpIf(VNExpr, Int)
    case jumpIfFalse(VNExpr, Int)
    case call(label: Int, parameters: [String], arguments: [VNExpr])
    case returnFromCall
    /// 覆盖式赋值：`define`、标签体内的 `define`、`$ x = 1`
    case assign(String, VNExpr)
    /// `default`：只在还没有值时写入
    case initialize(String, VNExpr)
    /// `image bg room = "room.png"`
    case image(name: String, expression: VNExpr)
    case scene(name: String?, layer: String)
    case show(name: String, expression: VNExpr?, layer: String)
    case hide(name: String, layer: String)
    case play(channel: String, file: VNExpr?, volume: Double, loop: Bool)
    case stop(channel: String)
    case pause(VNExpr?)
    case expression(VNExpr)
    /// 走到了不认识的结构，运行时报错而不是静默跳过
    case problem(String)
    case end
}

struct VNLabel {
    var name: String
    var index: Int
    var parameters: [String]
}

/// 一个游戏的可执行脚本：init 段 + 主体 + 标签表。
struct VNProgram {
    let initOps: [VNOp]
    let ops: [VNOp]
    let labels: [VNLabel]
    let warnings: [String]
    /// 脚本指纹：存档记录它，读档时不一致就拒绝，避免跳错位置
    let fingerprint: String

    private let labelIndex: [String: Int]

    init(initOps: [VNOp], ops: [VNOp], labels: [VNLabel], warnings: [String] = [], fingerprint: String = "") {
        self.initOps = initOps
        self.ops = ops
        self.labels = labels
        self.warnings = warnings
        self.fingerprint = fingerprint
        self.labelIndex = Dictionary(labels.map { ($0.name, $0.index) }, uniquingKeysWith: { first, _ in first })
    }

    func index(ofLabel name: String) -> Int? {
        labelIndex[name]
    }

    /// pc 落在哪个标签里，存档列表显示用
    func label(containingPc index: Int) -> String? {
        labels.filter { $0.index <= index }.max { $0.index < $1.index }?.name
    }

    /// 新游戏从 `start` 开始；没有 start 就用第一个定义的标签
    var startIndex: Int? {
        if let start = labelIndex["start"] { return start }
        return labels.first?.index
    }

    var labelNames: [String] { labels.map { $0.name } }
}

/// 把语句树编译成扁平指令。
///
/// 两次遍历：先按顺序生成指令，遇到引用标签的地方留一个占位（patch），
/// 所有标签位置都确定之后再回填。这样向前跳和向后跳用同一套代码处理。
struct VNCompiler {
    private var ops: [VNOp] = []
    private var initOps: [VNOp] = []
    private var labels: [VNLabel] = []
    private var patches: [Patch] = []
    private var warnings: [String] = []

    private struct Patch {
        enum Kind {
            case jump
            case jumpIf(VNExpr)
            case jumpIfFalse(VNExpr)
            case call([VNExpr])
        }
        var site: Int
        var label: String
        var kind: Kind
    }

    static func compile(_ statements: [VNStmt], fingerprint: String = "") -> VNProgram {
        var compiler = VNCompiler()
        compiler.compileTopLevel(statements)
        let ops = compiler.resolve()
        return VNProgram(initOps: compiler.initOps,
                         ops: ops,
                         labels: compiler.labels,
                         warnings: compiler.warnings,
                         fingerprint: fingerprint)
    }

    // MARK: - 顶层

    private mutating func compileTopLevel(_ statements: [VNStmt]) {
        for statement in statements {
            switch statement {
            case .label(let name, let parameters, let body):
                startLabel(name: name, parameters: parameters)
                emit(body)
                ops.append(.returnFromCall)
            case .define(let name, let value):
                initOps.append(.assign(name, value))
            case .defaultVariable(let name, let value):
                initOps.append(.initialize(name, value))
            case .image(let definition, let expression):
                initOps.append(imageOp(definition: definition, expression: expression))
            case .ignored(let reason):
                warnings.append(reason)
            default:
                // 顶层的非 init 语句在 Ren'Py 里必须写在 init 块中，这里忽略即可
                warnings.append("忽略顶层语句：\(describe(statement))")
            }
        }
    }

    private mutating func startLabel(name: String, parameters: [String]) {
        if labels.contains(where: { $0.name == name }) {
            warnings.append("标签重复：\(name)")
            return
        }
        labels.append(VNLabel(name: name, index: ops.count, parameters: parameters))
    }

    // MARK: - 语句体

    private mutating func emit(_ statements: [VNStmt]) {
        for statement in statements {
            emit(statement)
        }
    }

    private mutating func emit(_ statement: VNStmt) {
        switch statement {
        case .label(let name, let parameters, let body):
            // 嵌套标签：从当前位置开始，正文结束后自然接着往下走
            startLabel(name: name, parameters: parameters)
            emit(body)
        case .say(let character, let who, let text, let attributes):
            ops.append(.say(character: character, who: who, text: text, attributes: attributes))
        case .menu(let title, let items):
            emitMenu(title: title, items: items)
        case .jump(let label):
            appendPatch(.jump, label: label)
        case .jumpIf(let condition, let label):
            appendPatch(.jumpIf(condition), label: label)
        case .call(let label, let arguments):
            appendPatch(.call(arguments), label: label)
        case .choiceReturn(let label):
            appendPatch(.jump, label: label)
        case .returnStatement:
            ops.append(.returnFromCall)
        case .define(let name, let value), .defaultVariable(let name, let value):
            // 标签体里的 define/default 走到时才执行
            ops.append(.assign(name, value))
        case .assign(let target, let value):
            ops.append(.assign(target, value))
        case .expressionStatement(let value):
            ops.append(.expression(value))
        case .scene(let name, let layer):
            ops.append(.scene(name: name, layer: layer))
        case .show(let name, let expression, let layer):
            ops.append(.show(name: name, expression: expression, layer: layer))
        case .hide(let name, let layer):
            ops.append(.hide(name: name, layer: layer))
        case .image(let definition, let expression):
            ops.append(imageOp(definition: definition, expression: expression))
        case .play(let channel, let file, let volume, let loop):
            ops.append(.play(channel: channel, file: file, volume: volume, loop: loop))
        case .stop(let channel):
            ops.append(.stop(channel: channel))
        case .voice(let file):
            ops.append(.play(channel: "voice", file: file, volume: 1, loop: false))
        case .pause(let duration):
            ops.append(.pause(duration))
        case .conditionals(let branches, let elseBody):
            emitIf(branches: branches, elseBody: elseBody)
        case .loop(let condition, let body):
            emitWhile(condition: condition, body: body)
        case .ignored(let reason):
            warnings.append(reason)
        case .unknown(let line):
            ops.append(.problem("无法理解的语句：\(line)"))
        }
    }

    private mutating func imageOp(definition: [VNValue], expression: VNExpr) -> VNOp {
        let name = definition.compactMap { value -> String? in
            if case .string(let text) = value { return text }
            if case .opaque(let text) = value { return text }
            return nil
        }.joined(separator: " ")
        return .image(name: name.lowercased(), expression: expression)
    }

    private mutating func appendPatch(_ kind: Patch.Kind, label: String) {
        patches.append(Patch(site: ops.count, label: label, kind: kind))
        ops.append(.jump(-1))
    }

    // MARK: - 控制流

    private mutating func emitMenu(title: VNExpr?, items: [VNMenuItem]) {
        let menuSlot = ops.count
        ops.append(.menu(title: title, items: []))
        var options: [VNMenuOption] = []
        var joins: [Int] = []

        for item in items {
            let target = ops.count
            options.append(VNMenuOption(text: item.text,
                                        condition: item.condition,
                                        showIf: item.showIf,
                                        target: target))
            emit(item.body)
            joins.append(ops.count)
            ops.append(.jump(-1))
        }

        let end = ops.count
        ops[menuSlot] = .menu(title: title, items: options)
        for site in joins {
            ops[site] = .jump(end)
        }
    }

    private mutating func emitIf(branches: [VNBranch], elseBody: [VNStmt]) {
        var pending: [(site: Int, condition: VNExpr)] = []
        var joins: [Int] = []

        for branch in branches {
            let test = ops.count
            ops.append(.jumpIfFalse(branch.condition, -1))
            pending.append((test, branch.condition))
            emit(branch.body)
            joins.append(ops.count)
            ops.append(.jump(-1))
            // 下一个分支的测试（或 else 正文）就是条件不成立时的去处
            for entry in pending {
                ops[entry.site] = .jumpIfFalse(entry.condition, ops.count)
            }
            pending.removeAll()
        }

        emit(elseBody)

        let end = ops.count
        for site in joins {
            ops[site] = .jump(end)
        }
    }

    private mutating func emitWhile(condition: VNExpr, body: [VNStmt]) {
        let test = ops.count
        ops.append(.jumpIfFalse(condition, -1))
        emit(body)
        ops.append(.jump(test))
        ops[test] = .jumpIfFalse(condition, ops.count)
    }

    // MARK: - 回填

    private mutating func resolve() -> [VNOp] {
        var result = ops
        for patch in patches {
            guard let target = labels.first(where: { $0.name == patch.label })?.index else {
                result[patch.site] = .problem("找不到标签：\(patch.label)")
                continue
            }
            switch patch.kind {
            case .jump:
                result[patch.site] = .jump(target)
            case .jumpIf(let condition):
                result[patch.site] = .jumpIf(condition, target)
            case .jumpIfFalse(let condition):
                result[patch.site] = .jumpIfFalse(condition, target)
            case .call(let arguments):
                let parameters = labels.first { $0.name == patch.label }?.parameters ?? []
                result[patch.site] = .call(label: target, parameters: parameters, arguments: arguments)
            }
        }
        result.append(.end)
        return result
    }

    private func describe(_ statement: VNStmt) -> String {
        switch statement {
        case .define(let name, _): return "define \(name)"
        case .defaultVariable(let name, _): return "default \(name)"
        case .assign(let target, _): return target
        case .expressionStatement: return "python 表达式"
        case .image(let definition, _): return "image \(definition)"
        default: return "非 init 语句"
        }
    }
}
