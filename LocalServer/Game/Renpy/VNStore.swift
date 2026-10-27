import Foundation

// 存档要写 JSON，这里给运行时用到的值一个明确的编码格式。
// 用 kind + value 而不是 Swift 默认的枚举编码，是为了让存档文件可读、也能跨版本辨认字段。
extension VNValue: Codable {
    private enum Kind: String, Codable {
        case none, bool, int, float, string, array, dictionary, opaque
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode(Kind.int, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .float(let value):
            try container.encode(Kind.float, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .array(let value):
            try container.encode(Kind.array, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .dictionary(let value):
            try container.encode(Kind.dictionary, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .opaque(let value):
            try container.encode(Kind.opaque, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none: self = .none
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int: self = .int(try container.decode(Int.self, forKey: .value))
        case .float: self = .float(try container.decode(Double.self, forKey: .value))
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .array: self = .array(try container.decode([VNValue].self, forKey: .value))
        case .dictionary: self = .dictionary(try container.decode([String: VNValue].self, forKey: .value))
        case .opaque: self = .opaque(try container.decode(String.self, forKey: .value))
        }
    }
}

/// 角色定义：`define e = Character("艾莉", color="#f80")`
struct VNCharacter: Equatable, Codable {
    var name: String
    var colorHex: String?
}

/// 脚本运行时的数据：变量表与角色表。
/// 存档要写的就是它（外加 pc、调用栈与显示层）。
final class VNStore {
    var variables: [String: VNValue] = [:]
    private var characters: [String: VNCharacter] = [:]

    func setCharacter(_ character: VNCharacter, for name: String) {
        characters[name] = character
    }

    func character(for name: String) -> VNCharacter? {
        characters[name]
    }

    /// `default`：只在没有值时写入，用于重开一局时恢复初值
    func initialize(_ name: String, to value: VNValue) {
        if variables[name] == nil { variables[name] = value }
    }

    /// 说话人显示名：先按变量名查 `Character`，查不到就用脚本里写死的名字
    func displayName(forVariable name: String?, literal: String?) -> String? {
        if let name, let character = characters[name] {
            return character.name.isEmpty ? nil : character.name
        }
        if let name { return name }
        return literal
    }

    /// 复制一份，读档时先落到临时对象上校验，成功了才覆盖当前状态
    func snapshot() -> [String: VNValue] { variables }

    func characterSnapshot() -> [String: VNCharacter] { characters }

    func restore(variables newVariables: [String: VNValue], characters newCharacters: [String: VNCharacter]) {
        variables = newVariables
        characters = newCharacters
    }
}

/// 表达式求值：只覆盖视觉小说脚本需要的 Python 子集。
/// 算不出来时返回 nil，由调用方决定是提示还是原样保留，绝不编造一个值。
final class VNEvaluator {
    let store: VNStore

    init(store: VNStore) {
        self.store = store
    }

    func value(of expression: VNExpr) -> VNValue? {
        switch expression {
        case .literal(let value):
            return value
        case .variable(let name):
            return variable(name)
        case .attribute(let base, let name):
            guard let container = value(of: base), case .dictionary(let entries) = container else { return nil }
            return entries[name]
        case .element(let base, let key):
            return element(of: base, key: key)
        case .call(let callee, let arguments, let keywords):
            return call(callee: callee, arguments: arguments, keywords: keywords)
        case .unary(let op, let operand):
            return unary(op: op, operand: operand)
        case .binary(let op, let left, let right):
            return binary(op: op, left: left, right: right)
        case .conditional(condition: let condition, then: let then, else: let otherwise):
            guard let test = value(of: condition) else { return nil }
            return value(of: test.isTruthy ? then : otherwise)
        case .format(let parts):
            return format(parts)
        case .list(let items):
            var values: [VNValue] = []
            for item in items {
                guard let value = value(of: item) else { return nil }
                values.append(value)
            }
            return .array(values)
        case .dictionary(let pairs):
            var entries: [String: VNValue] = [:]
            for (key, rawValue) in pairs {
                guard let keyValue = value(of: key), let resolved = value(of: rawValue) else { return nil }
                entries[keyValue.displayText] = resolved
            }
            return .dictionary(entries)
        case .unsupported:
            return nil
        }
    }

    /// 条件与 `if` 子句用；算不出来按假处理
    func truth(of expression: VNExpr) -> Bool {
        value(of: expression)?.isTruthy ?? false
    }

    /// `Character("艾莉", color="#f80")` 的静态拆解；不是 Character 调用时返回 nil
    func characterDefinition(of expression: VNExpr) -> VNCharacter? {
        guard case .call(let callee, let arguments, let keywords) = expression,
              case .variable(let name) = callee, name == "Character" else { return nil }
        guard case .literal(let first)? = arguments.first, case .string(let displayName) = first else { return nil }
        var color: String? = nil
        for (key, value) in keywords where key == "color" {
            if case .literal(let literal) = value, case .string(let text) = literal { color = text }
        }
        return VNCharacter(name: displayName, colorHex: color)
    }

    // MARK: - 求值细节

    private func variable(_ name: String) -> VNValue? {
        switch name {
        case "True": return .bool(true)
        case "False": return .bool(false)
        case "None": return .none
        default:
            if let value = store.variables[name] { return value }
            // `define e = Character(...)` 之后，脚本里 `e "…"` 的那个 e 只是说话人标记
            if let character = store.character(for: name) { return .opaque(character.name) }
            return nil
        }
    }

    private func element(of base: VNExpr, key: VNExpr) -> VNValue? {
        guard let container = value(of: base), let index = value(of: key) else { return nil }
        switch (container, index) {
        case (.array(let items), .int(let position)):
            let resolved = position < 0 ? items.count + position : position
            guard resolved >= 0, resolved < items.count else { return nil }
            return items[resolved]
        case (.dictionary(let entries), .string(let name)):
            return entries[name]
        case (.string(let text), .int(let position)):
            let characters = Array(text)
            let resolved = position < 0 ? characters.count + position : position
            guard resolved >= 0, resolved < characters.count else { return nil }
            return .string(String(characters[resolved]))
        default:
            return nil
        }
    }

    /// 我们不求值的 Ren'Py 接口，按无副作用的空操作处理
    private static let ignoredRenpyFunctions: Set<String> = [
        "pause", "scene", "show", "hide", "with", "restart", "say",
        "play_music", "stop_music", "play_sound", "stop_sound", "voice", "jump", "call_in_new_context"
    ]

    private func call(callee: VNExpr, arguments: [VNExpr], keywords: [(String, VNExpr)]) -> VNValue? {
        if case .attribute(let base, let name) = callee,
           case .variable(let owner) = base, owner == "renpy",
           VNEvaluator.ignoredRenpyFunctions.contains(name) {
            return .none
        }
        guard case .variable(let name) = callee else { return nil }

        var values: [VNValue] = []
        for argument in arguments {
            guard let value = value(of: argument) else { return nil }
            values.append(value)
        }

        switch name {
        case "_", "__", "_p":
            // 翻译函数：默认语言下原样返回文本
            return values.first
        case "Character":
            // 说话人显示名就是第一个参数；图像一类的附加参数我们不求值
            return .opaque(values.first?.displayText ?? "")
        case "len":
            guard let first = values.first else { return nil }
            switch first {
            case .string(let text): return .int(text.count)
            case .array(let items): return .int(items.count)
            case .dictionary(let entries): return .int(entries.count)
            default: return nil
            }
        case "str":
            guard let first = values.first else { return nil }
            return .string(first.displayText)
        case "int":
            guard let first = values.first else { return nil }
            if let number = first.intValue { return .int(number) }
            if case .string(let text) = first { return .int(Int(text.trimmingCharacters(in: .whitespaces)) ?? 0) }
            return nil
        case "float":
            guard let first = values.first, let number = first.comparable else { return nil }
            return .float(number)
        case "abs":
            guard let first = values.first, let number = first.comparable else { return nil }
            return number < 0 ? .float(-number) : .float(number)
        case "round":
            guard let first = values.first, let number = first.comparable else { return nil }
            return .int(Int(number.rounded()))
        case "min":
            let numbers = values.compactMap { $0.comparable }
            guard let smallest = numbers.min() else { return nil }
            return numberValue(smallest)
        case "max":
            let numbers = values.compactMap { $0.comparable }
            guard let largest = numbers.max() else { return nil }
            return numberValue(largest)
        case "bool":
            return .bool(values.first?.isTruthy ?? false)
        default:
            return nil
        }
    }

    /// 整数保持整数，避免出现 `points = 3.0`
    private func numberValue(_ number: Double) -> VNValue {
        if number == number.rounded(), abs(number) < 1e15 { return .int(Int(number)) }
        return .float(number)
    }

    private func unary(op: String, operand: VNExpr) -> VNValue? {
        guard let value = value(of: operand) else { return nil }
        switch op {
        case "not": return .bool(!value.isTruthy)
        case "-":
            guard let number = value.comparable else { return nil }
            return numberValue(-number)
        case "+":
            guard value.comparable != nil else { return nil }
            return value
        default:
            return nil
        }
    }

    private func binary(op: String, left: VNExpr, right: VNExpr) -> VNValue? {
        // and / or 需要短路，先算左边
        if op == "and" {
            guard let first = value(of: left) else { return nil }
            return first.isTruthy ? value(of: right) : first
        }
        if op == "or" {
            guard let first = value(of: left) else { return nil }
            return first.isTruthy ? first : value(of: right)
        }

        guard let first = value(of: left), let second = value(of: right) else { return nil }

        switch op {
        case "+":
            if case .string(let a) = first, case .string(let b) = second { return .string(a + b) }
            if case .array(let a) = first, case .array(let b) = second { return .array(a + b) }
            return arithmetic(a: first, b: second, op: "+")
        case "-", "*", "/", "%", "**":
            return arithmetic(a: first, b: second, op: op)
        case "==": return .bool(equal(first, second))
        case "!=": return .bool(!equal(first, second))
        case "<", "<=", ">", ">=": return comparison(first, second, op: op)
        case "in":
            guard let result = contains(needle: first, in: second) else { return nil }
            return .bool(result)
        case "not in":
            guard let result = contains(needle: first, in: second) else { return nil }
            return .bool(!result)
        default:
            return nil
        }
    }

    private func arithmetic(a: VNValue, b: VNValue, op: String) -> VNValue? {
        guard let left = a.comparable, let right = b.comparable else {
            if op == "+", case .array(let items) = a, case .array(let others) = b {
                return .array(items + others)
            }
            return nil
        }
        switch op {
        case "+": return numberValue(left + right)
        case "-": return numberValue(left - right)
        case "*": return numberValue(left * right)
        case "/":
            guard right != 0 else { return nil }
            return numberValue(left / right)
        case "%":
            guard right != 0 else { return nil }
            return numberValue(left.truncatingRemainder(dividingBy: right))
        case "**": return numberValue(pow(left, right))
        default: return nil
        }
    }

    private func equal(_ a: VNValue, _ b: VNValue) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.opaque(let x), .opaque(let y)): return x == y
        case (.array(let x), .array(let y)):
            guard x.count == y.count else { return false }
            for (left, right) in zip(x, y) where !equal(left, right) { return false }
            return true
        case (.dictionary(let x), .dictionary(let y)):
            guard x.count == y.count else { return false }
            for (key, value) in x {
                guard let other = y[key], equal(value, other) else { return false }
            }
            return true
        default:
            if let left = a.comparable, let right = b.comparable { return left == right }
            return false
        }
    }

    private func comparison(_ a: VNValue, _ b: VNValue, op: String) -> VNValue? {
        if case .string(let left) = a, case .string(let right) = b {
            switch op {
            case "<": return .bool(left < right)
            case "<=": return .bool(left <= right)
            case ">": return .bool(left > right)
            case ">=": return .bool(left >= right)
            default: return nil
            }
        }
        guard let left = a.comparable, let right = b.comparable else { return nil }
        switch op {
        case "<": return .bool(left < right)
        case "<=": return .bool(left <= right)
        case ">": return .bool(left > right)
        case ">=": return .bool(left >= right)
        default: return nil
        }
    }

    private func contains(needle: VNValue, in container: VNValue) -> Bool? {
        switch container {
        case .array(let items): return items.contains { equal(needle, $0) }
        case .dictionary(let entries):
            guard let key = needle.stringValue else { return false }
            return entries[key] != nil
        case .string(let text):
            guard let fragment = needle.stringValue else { return nil }
            return text.contains(fragment)
        default:
            return nil
        }
    }

    private func format(_ parts: [VNExpr.FormatPart]) -> VNValue? {
        var text = ""
        for part in parts {
            switch part {
            case .text(let literal):
                text += literal
            case .expression(let expression):
                guard let value = value(of: expression) else { return nil }
                text += value.displayText
            case .named(let name):
                guard let value = variable(name) else { return nil }
                text += value.displayText
            }
        }
        return .string(text)
    }
}

/// Ren'Py 文本替换。
///
/// `{x}` 插值、`{x=}` 自描述、`{{` / `[[` / `%%` 字面量在这里处理；
/// 认不出的 `{...}` 原样保留，交给显示层当文本标签（`{b}`、`{size=+2}`、`{nw}` 等）。
enum VNText {
    static func substitute(_ text: String, using evaluator: VNEvaluator) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "{", index + 1 < characters.count, characters[index + 1] == "{" {
                result.append("{")
                index += 2
                continue
            }
            if character == "[", index + 1 < characters.count, characters[index + 1] == "[" {
                result.append("[")
                index += 2
                continue
            }
            if character == "%", index + 1 < characters.count, characters[index + 1] == "%" {
                result.append("%")
                index += 2
                continue
            }
            if character == "{", let end = closingBrace(characters, from: index) {
                let content = String(characters[(index + 1)..<end])
                result += replacement(for: content, using: evaluator)
                index = end + 1
                continue
            }

            result.append(character)
            index += 1
        }
        return result
    }

    /// 找到与 index 处的 `{` 配对的 `}`；标签里可能带引号，所以只在同层查找
    private static func closingBrace(_ characters: [Character], from index: Int) -> Int? {
        var position = index + 1
        var depth = 1
        while position < characters.count {
            let character = characters[position]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return position }
            }
            position += 1
        }
        return nil
    }

    private static func replacement(for content: String, using evaluator: VNEvaluator) -> String {
        guard !content.isEmpty, !content.hasPrefix("/") else { return "{\(content)}" }

        // `{name=}`：显示成 `name=值`
        if content.hasSuffix("=") {
            let name = String(content.dropLast())
            return interpolate(name, label: name + "=", using: evaluator)
        }
        return interpolate(content, label: nil, using: evaluator)
    }

    private static func interpolate(_ source: String, label: String?, using evaluator: VNEvaluator) -> String {
        let expression = ExpressionParser.parse(source)
        // 解析不出来说明是文本标签，原样交给显示层
        if case .unsupported = expression { return "{\(source)}" }
        guard let value = evaluator.value(of: expression) else { return "{\(source)}" }
        let text = value.displayText
        if let label { return label + text }
        return text
    }
}
