import Foundation

/// Ren'Py 运行时里流动的值。
indirect enum VNValue: Equatable {
    case none
    case bool(Bool)
    case int(Int)
    case float(Double)
    case string(String)
    case array([VNValue])
    case dictionary([String: VNValue])
    /// 图像名、角色、变换等我们不求值的对象，只保留可读名字
    case opaque(String)

    /// Python 的真假判断
    var isTruthy: Bool {
        switch self {
        case .none: return false
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .float(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        case .dictionary(let value): return !value.isEmpty
        case .opaque: return true
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .float(let value): return value
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    var intValue: Int? {
        if let double = doubleValue { return Int(double) }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// 用于文本替换（f-string、`%(name)s`）
    var displayText: String {
        switch self {
        case .none: return "None"
        case .bool(let value): return value ? "True" : "False"
        case .int(let value): return String(value)
        case .float(let value): return VNValue.formatFloat(value)
        case .string(let value): return value
        case .array(let value): return "[" + value.map { $0.displayText }.joined(separator: ", ") + "]"
        case .dictionary(let value): return "{" + value.map { "\($0.key): \($0.value.displayText)" }.joined(separator: ", ") + "}"
        case .opaque(let name): return name
        }
    }

    /// Python 的 float 显示：整数値不带小数点
    private static func formatFloat(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }

    /// 比较用的数值，非数值返回 nil
    var comparable: Double? { doubleValue }
}

/// 表达式的抽象语法树。
indirect enum VNExpr {
    case literal(VNValue)
    case variable(String)
    case attribute(VNExpr, String)
    case element(VNExpr, VNExpr)
    case call(VNExpr, [VNExpr], [(String, VNExpr)])
    case unary(String, VNExpr)
    case binary(String, VNExpr, VNExpr)
    case conditional(condition: VNExpr, then: VNExpr, else: VNExpr)
    /// 字符串插值：静态片段与表达式交替
    case format([FormatPart])
    case list([VNExpr])
    case dictionary([(VNExpr, VNExpr)])
    /// 解析出来但暂不求值的表达式（例如复杂函数调用），求值时按原样给出提示
    case unsupported(String)

    enum FormatPart {
        case text(String)
        /// `{variable=}`、`{expression}`
        case expression(VNExpr)
        /// `%(name)s`
        case named(String)
    }
}

/// 语句的抽象语法树；解析后再编译成扁平指令。
indirect enum VNStmt {
    case label(name: String, parameters: [String], body: [VNStmt])
    /// `define e = Character("艾琳")`
    case define(name: String, value: VNExpr)
    /// `default points = 0`
    case defaultVariable(name: String, value: VNExpr)
    /// `$ flag = True` 与 python 块里的赋值
    case assign(target: String, value: VNExpr)
    /// 只执行、不赋值的 python 语句（我们只识别少数调用）
    case expressionStatement(VNExpr)

    case say(character: VNExpr?, who: String?, text: VNExpr, attributes: [String])
    case menu(title: VNExpr?, items: [VNMenuItem])
    case jump(label: String)
    /// `jump expression 表达式`：运行时才算出标签名
    case jumpExpression(VNExpr, source: String)
    case jumpIf(VNExpr, label: String)
    case call(label: String, arguments: [VNExpr])
    case returnStatement

    case scene(name: String?, layer: String)
    case show(name: String, expression: VNExpr?, layer: String)
    case hide(name: String, layer: String)
    case image(definition: [VNValue], expression: VNExpr)
    case play(channel: String, file: VNExpr?, volume: Double, loop: Bool)
    case stop(channel: String)
    case voice(file: VNExpr?)
    case pause(duration: VNExpr?)
    case choiceReturn(label: String)
    /// `if/elif/else`
    case conditionals(branches: [VNBranch], elseBody: [VNStmt])
    case loop(condition: VNExpr, body: [VNStmt])
    /// 我们主动忽略的块（screen / style / transform / translate / python 里的复杂语句）
    case ignored(String)
    /// 走到这里说明脚本结构不认识，运行时应报错而不是静默跳过
    case unknown(line: String)
}

struct VNMenuItem {
    var text: VNExpr
    /// `if 条件` —— 不满足时不可选
    var condition: VNExpr?
    /// `showif 条件` —— 不满足时不显示
    var showIf: VNExpr?
    var body: [VNStmt]
}

struct VNBranch {
    var condition: VNExpr
    var body: [VNStmt]
}
