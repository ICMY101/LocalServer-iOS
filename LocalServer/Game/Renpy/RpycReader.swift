import Foundation

/// `.rpyc` 里读出来的 pickle 值。
///
/// 这份解码器和 `PickleReader` 刻意分开：`.rpa` 索引里不该出现对象，
/// 那边遇到 GLOBAL/REDUCE 就判定为不支持；编译脚本的语法树全是 Python 对象，
/// 必须能把它们重建出来。
indirect enum PklValue {
    case none
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case string(String)
    /// 字节串（bytes）
    case bytes(Data)
    /// list / tuple / set 统一按数组处理
    case array([PklValue])
    case dictionary([(PklValue, PklValue)])
    /// 模块级名字（GLOBAL / STACK_GLOBAL 压栈的类），例如 `renpy.ast.Say`
    case reference(String)
    case object(PklObject)
}

/// 反序列化出来的 Python 对象：类名、构造参数和状态
struct PklObject {
    var className: String
    var args: [PklValue] = []
    var state: PklValue? = nil
}

/// 读取 Ren'Py 编译脚本（`.rpyc` / `.rpymc`）。
///
/// 容器有两代格式：
/// - 现代：10 字节魔数 `RENPY RPC` + 版本数字，之后是若干 12 字节槽表项
///   （槽号、偏移、长度，用 `struct.pack("III")` 写出，机器都是小端），
///   槽 1 是静态变换前的语法树，槽 2 是变换后的（台词被包进 translate 块），
///   两段都各自经过 zlib；
/// - 旧版：整份文件就是一个 zlib 压缩的 pickle。
///
/// pickle 解出来是 `(data, stmts)`：data 是版本/翻译之类的元信息，stmts 才是语句列表。
/// 语法树的字段名以官方 `renpy/ast.py`、`renpy/parser.py` 为准。
enum RpycReader {
    struct Script {
        var statements: [VNStmt]
        var warnings: [String]
    }

    private static let magic = Array("RENPY RPC".utf8)

    static func read(_ data: Data) -> Script? {
        for payload in payloads(in: data) {
            guard let root = RpycPickle.decode(payload) else { continue }
            var builder = AstBuilder()
            let statements: [VNStmt]
            if case .array(let parts) = root, parts.count >= 2 {
                statements = builder.statements(parts[1])
            } else {
                // 万一整份 pickle 就是语句列表，也按列表处理
                statements = builder.statements(root)
            }
            return Script(statements: statements, warnings: builder.warnings)
        }
        return nil
    }

    /// 按优先级列出每个可读的 pickle 载荷
    private static func payloads(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count > magic.count, Array(bytes[0..<magic.count]) == magic else {
            // 旧格式没有头，整份文件是 zlib 流
            return Zlib.inflate(data).map { [$0] } ?? []
        }

        var slots = slotTable(bytes, littleEndian: true)
        if slots.isEmpty {
            // 极老的 PowerPC 版本会把槽表写成大端，读不出槽位时换一种解释再试
            slots = slotTable(bytes, littleEndian: false)
        }

        // 槽 1 是变换前的原始语法树，少一层 translate 包装，优先使用
        var result: [Data] = []
        for slot in [1, 2] {
            guard let entry = slots[slot], entry.length > 0,
                  entry.start >= 0, entry.start + entry.length <= bytes.count else { continue }
            let lower = data.startIndex + entry.start
            let chunk = data.subdata(in: lower..<(lower + entry.length))
            if let inflated = Zlib.inflate(chunk) { result.append(inflated) }
        }
        return result
    }

    private static func slotTable(_ bytes: [UInt8], littleEndian: Bool) -> [Int: (start: Int, length: Int)] {
        var slots: [Int: (start: Int, length: Int)] = [:]
        var offset = magic.count + 1
        while offset + 12 <= bytes.count {
            let slot = Int(read32(bytes, offset, littleEndian: littleEndian))
            let start = Int(read32(bytes, offset + 4, littleEndian: littleEndian))
            let length = Int(read32(bytes, offset + 8, littleEndian: littleEndian))
            offset += 12
            if slot == 0 { break }
            guard (1...3).contains(slot), start >= 0, length >= 0, start + length <= bytes.count else {
                return [:]
            }
            slots[slot] = (start, length)
        }
        return slots
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int, littleEndian: Bool) -> UInt32 {
        if littleEndian {
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

// MARK: - pickle（带对象）

/// 只读的 pickle 解码器，支持 Ren'Py 编译脚本里会用到的对象重建指令。
private enum RpycPickle {
    /// 单个数据块的上限，防御损坏的文件
    static let maxLength = 64 * 1024 * 1024

    static func decode(_ data: Data) -> PklValue? {
        var reader = Decoder(input: [UInt8](data))
        return reader.run()
    }

    private enum Entry {
        case value(PklValue)
        case mark
    }

    private struct Decoder {
        let input: [UInt8]
        var pos = 0
        var stack: [Entry] = []
        var memo: [PklValue] = []

        var isAtEnd: Bool { pos >= input.count }

        // MARK: 字节读取

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= RpycPickle.maxLength, pos + count <= input.count else { return nil }
            let slice = Array(input[pos ..< pos + count])
            pos += count
            return slice
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, pos + count <= input.count else { return false }
            pos += count
            return true
        }

        mutating func u8() -> Int? { take(1).map { Int($0[0]) } }

        mutating func u16() -> Int? {
            guard let b = take(2) else { return nil }
            return Int(b[0]) | Int(b[1]) << 8
        }

        mutating func u32() -> Int? {
            guard let b = take(4) else { return nil }
            return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        }

        mutating func u64() -> Int? {
            guard let b = take(8) else { return nil }
            var value = 0
            for i in 0..<8 { value |= Int(b[i]) << (8 * i) }
            return value
        }

        /// 读到 '\n' 为止的 ASCII 文本；没有换行时判为不完整
        mutating func line() -> String? {
            var out: [UInt8] = []
            while pos < input.count {
                let byte = input[pos]
                pos += 1
                if byte == 0x0a { return String(decoding: out, as: UTF8.self) }
                out.append(byte)
                if out.count > RpycPickle.maxLength { return nil }
            }
            return nil
        }

        mutating func fixedText(_ count: Int) -> String? {
            guard let bytes = take(count) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }

        mutating func bigEndianDouble() -> Double? {
            guard let b = take(8) else { return nil }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(b[i]) << (8 * (7 - i)) }
            return Double(bitPattern: bits)
        }

        /// LONG1/LONG4：小端、最高字节的 0x80 是符号位
        mutating func signedLittleEndian(_ length: Int) -> Int64? {
            guard length >= 0, length <= 8, let bytes = take(length) else { return nil }
            if bytes.isEmpty { return 0 }
            var value = Int64(0)
            for (shift, byte) in bytes.enumerated() {
                value |= Int64(byte) << (8 * shift)
            }
            if bytes[bytes.count - 1] & 0x80 != 0 {
                value -= Int64(1) << (8 * bytes.count)
            }
            return value
        }

        // MARK: 栈

        mutating func push(_ value: PklValue) { stack.append(.value(value)) }

        mutating func pop() -> PklValue? {
            guard case .value(let value)? = stack.popLast() else { return nil }
            return value
        }

        mutating func top() -> PklValue? {
            guard case .value(let value)? = stack.last else { return nil }
            return value
        }

        mutating func replaceTop(_ value: PklValue) -> Bool {
            guard !stack.isEmpty else { return false }
            stack[stack.count - 1] = .value(value)
            return true
        }

        mutating func popValues(_ count: Int) -> [PklValue]? {
            guard count >= 0, stack.count >= count else { return nil }
            var values: [PklValue] = []
            values.reserveCapacity(count)
            for entry in stack.suffix(count) {
                guard case .value(let value) = entry else { return nil }
                values.append(value)
            }
            stack.removeLast(count)
            return values
        }

        /// 取出 MARK 之上的所有值，并移除 MARK
        mutating func popMark() -> [PklValue]? {
            guard let index = stack.lastIndex(where: { entry in
                if case .mark = entry { return true }
                return false
            }) else { return nil }
            let values = stack[(index + 1)...].compactMap { entry -> PklValue? in
                if case .value(let value) = entry { return value }
                return nil
            }
            stack.removeSubrange(index...)
            return values
        }

        mutating func memoPut(_ index: Int, _ value: PklValue) {
            while memo.count <= index { memo.append(.none) }
            memo[index] = value
        }

        mutating func memoGet(_ index: Int) -> PklValue? {
            guard index >= 0, index < memo.count else { return nil }
            return memo[index]
        }

        // MARK: 主循环

        mutating func run() -> PklValue? {
            while !isAtEnd {
                let code = input[pos]
                pos += 1
                guard execute(code) else { return nil }
                if code == Opcode.stop { return top() }
            }
            return top()
        }

        mutating func execute(_ code: UInt8) -> Bool {
            switch code {
            case Opcode.proto: return skip(1)
            // protocol 4 的分帧头只有长度信息，直接跳过
            case Opcode.frame: return skip(8)
            case Opcode.stop: return true

            case Opcode.none: push(.none); return true
            case Opcode.newTrue: push(.bool(true)); return true
            case Opcode.newFalse: push(.bool(false)); return true

            case Opcode.int, Opcode.long:
                guard let text = line(), let value = Self.number(fromLine: text) else { return false }
                push(value); return true
            case Opcode.binint:
                guard let bytes = take(4) else { return false }
                let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                push(.int(Int64(Int32(bitPattern: raw)))); return true
            case Opcode.binint1:
                guard let value = u8() else { return false }
                push(.int(Int64(value))); return true
            case Opcode.binint2:
                guard let value = u16() else { return false }
                push(.int(Int64(value))); return true
            case Opcode.long1:
                guard let length = u8(), let value = signedLittleEndian(length) else { return false }
                push(.int(value)); return true
            case Opcode.long4:
                guard let length = u32(), let value = signedLittleEndian(length) else { return false }
                push(.int(value)); return true

            case Opcode.float:
                guard let text = line(), let value = Double(text) else { return false }
                push(.float(value)); return true
            case Opcode.binfloat:
                guard let value = bigEndianDouble() else { return false }
                push(.float(value)); return true

            case Opcode.unicode:
                guard let text = line() else { return false }
                push(.string(Unescaper.unescape(text))); return true
            case Opcode.string:
                guard let text = line() else { return false }
                let body = text.count >= 2 ? String(text.dropFirst().dropLast()) : text
                push(.string(Unescaper.unescape(body))); return true
            case Opcode.shortBinstring:
                guard let length = u8(), let bytes = take(length) else { return false }
                push(.bytes(Data(bytes))); return true
            case Opcode.binstring:
                guard let length = u32(), let bytes = take(length) else { return false }
                push(.bytes(Data(bytes))); return true
            case Opcode.shortBinunicode:
                guard let length = u8(), let value = fixedText(length) else { return false }
                push(.string(value)); return true
            case Opcode.binunicode:
                guard let length = u32(), let value = fixedText(length) else { return false }
                push(.string(value)); return true
            case Opcode.binunicode8:
                guard let length = u64(), length <= RpycPickle.maxLength, let value = fixedText(length) else {
                    return false
                }
                push(.string(value)); return true
            case Opcode.shortBinbytes:
                guard let length = u8(), let bytes = take(length) else { return false }
                push(.bytes(Data(bytes))); return true
            case Opcode.binbytes:
                guard let length = u32(), let bytes = take(length) else { return false }
                push(.bytes(Data(bytes))); return true
            case Opcode.binbytes8, Opcode.bytearray8:
                guard let length = u64(), length <= RpycPickle.maxLength, let bytes = take(length) else {
                    return false
                }
                push(.bytes(Data(bytes))); return true

            case Opcode.mark: stack.append(.mark); return true
            case Opcode.pop: _ = stack.popLast(); return true
            case Opcode.popMark: _ = popMark(); return true
            case Opcode.dup:
                guard let last = top() else { return false }
                push(last); return true

            case Opcode.emptyTuple: push(.array([])); return true
            case Opcode.tuple1, Opcode.tuple2, Opcode.tuple3:
                let count = Int(code - Opcode.tuple1) + 1
                guard let values = popValues(count) else { return false }
                push(.array(values)); return true
            case Opcode.tuple:
                guard let values = popMark() else { return false }
                push(.array(values)); return true

            case Opcode.emptyList: push(.array([])); return true
            case Opcode.list:
                guard let values = popMark() else { return false }
                push(.array(values)); return true
            case Opcode.append:
                guard let value = pop(), let container = top(), case .array(var items) = container else {
                    return false
                }
                items.append(value)
                return replaceTop(.array(items))
            case Opcode.appends:
                guard let values = popMark(), let container = top(), case .array(var items) = container else {
                    return false
                }
                items.append(contentsOf: values)
                return replaceTop(.array(items))

            case Opcode.emptyDict: push(.dictionary([])); return true
            case Opcode.dict:
                guard let flat = popMark(), flat.count % 2 == 0 else { return false }
                push(.dictionary(Self.pairs(from: flat))); return true
            case Opcode.setitem:
                guard let value = pop(), let key = pop(),
                      let container = top(), case .dictionary(var entries) = container else { return false }
                entries.append((key, value))
                return replaceTop(.dictionary(entries))
            case Opcode.setitems:
                guard let flat = popMark(), flat.count % 2 == 0,
                      let container = top(), case .dictionary(var entries) = container else { return false }
                entries.append(contentsOf: Self.pairs(from: flat))
                return replaceTop(.dictionary(entries))

            case Opcode.emptySet: push(.array([])); return true
            case Opcode.addItems:
                guard let values = popMark(), let container = top(), case .array(var items) = container else {
                    return false
                }
                items.append(contentsOf: values)
                return replaceTop(.array(items))
            case Opcode.frozenset:
                guard let values = popMark() else { return false }
                push(.array(values)); return true

            case Opcode.get:
                guard let text = line(), let index = Int(text), let value = memoGet(index) else { return false }
                push(value); return true
            case Opcode.binget:
                guard let index = u8(), let value = memoGet(index) else { return false }
                push(value); return true
            case Opcode.longBinget:
                guard let index = u32(), let value = memoGet(index) else { return false }
                push(value); return true
            case Opcode.put:
                guard let text = line(), let index = Int(text), let value = top() else { return false }
                memoPut(index, value); return true
            case Opcode.binput:
                guard let index = u8(), let value = top() else { return false }
                memoPut(index, value); return true
            case Opcode.longBinput:
                guard let index = u32(), let value = top() else { return false }
                memoPut(index, value); return true
            case Opcode.memoize:
                guard let value = top() else { return false }
                memo.append(value); return true

            case Opcode.globalRef:
                guard let module = line(), let name = line() else { return false }
                push(.reference(module + "." + name)); return true
            case Opcode.stackGlobal:
                guard let name = pop(), let module = pop(),
                      let moduleName = Self.stringValue(of: module),
                      let nameText = Self.stringValue(of: name) else { return false }
                push(.reference(moduleName + "." + nameText)); return true
            case Opcode.newobj:
                guard let arguments = pop(), let classValue = pop(),
                      let className = Self.referenceName(of: classValue),
                      case .array(let args) = arguments else { return false }
                push(Self.build(className: className, arguments: args)); return true
            case Opcode.newobjEx:
                guard let keywords = pop(), let arguments = pop(), let classValue = pop(),
                      let className = Self.referenceName(of: classValue),
                      case .array(let args) = arguments else { return false }
                _ = keywords
                push(Self.build(className: className, arguments: args)); return true
            case Opcode.reduce:
                guard let arguments = pop(), let callable = pop(), case .array(let args) = arguments,
                      let className = Self.referenceName(of: callable) else { return false }
                push(Self.build(className: className, arguments: args)); return true
            case Opcode.build:
                guard let state = pop(), let target = pop() else { return false }
                if case .object(var object) = target {
                    object.state = state
                    push(.object(object))
                } else {
                    // 少数容器类对象的 state 就是内容，我们不需要它
                    push(target)
                }
                return true

            default:
                // INST/OBJ/EXT/PERSID/缓冲区这些指令在编译脚本里不会出现
                return false
            }
        }

        // MARK: 辅助

        static func number(fromLine text: String) -> PklValue? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed == "01" { return .bool(true) }
            if trimmed == "00" { return .bool(false) }
            let body = (trimmed.hasSuffix("L") || trimmed.hasSuffix("l")) ? String(trimmed.dropLast()) : trimmed
            let negative = body.hasPrefix("-")
            let digits = negative ? String(body.dropFirst()) : body
            if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
                guard let value = Int64(digits.dropFirst(2), radix: 16) else { return nil }
                return .int(negative ? -value : value)
            }
            guard let value = Int64(digits) else { return nil }
            return .int(negative ? -value : value)
        }

        static func pairs(from flat: [PklValue]) -> [(PklValue, PklValue)] {
            var result: [(PklValue, PklValue)] = []
            result.reserveCapacity(flat.count / 2)
            stride(from: 0, to: flat.count, by: 2).forEach { result.append((flat[$0], flat[$0 + 1])) }
            return result
        }

        static func referenceName(of value: PklValue) -> String? {
            switch value {
            case .reference(let name): return name
            case .object(let object): return object.className
            default: return nil
            }
        }

        static func stringValue(of value: PklValue) -> String? {
            if case .string(let text) = value { return text }
            return nil
        }

        /// 重建对象。几个内置类型需要转成普通值，其余保留类名和状态。
        static func build(className: String, arguments: [PklValue]) -> PklValue {
            switch className {
            case "builtins.set", "builtins.frozenset":
                if let first = arguments.first, case .array(let items) = first { return .array(items) }
                return .array([])
            case "copyreg._reconstructor", "_reconstructor":
                // 旧式类：参数是 (类, 基类, 状态)
                if let first = arguments.first, let name = referenceName(of: first) {
                    return .object(PklObject(className: name))
                }
                return .object(PklObject(className: className, args: arguments))
            default:
                return .object(PklObject(className: className, args: arguments))
            }
        }
    }

    // MARK: - opcode（取自 CPython pickletools）

    private enum Opcode {
        static let proto: UInt8 = 0x80
        static let frame: UInt8 = 0x95
        static let stop: UInt8 = 0x2e

        static let none: UInt8 = 0x4e
        static let newTrue: UInt8 = 0x88
        static let newFalse: UInt8 = 0x89

        static let int: UInt8 = 0x49
        static let binint: UInt8 = 0x4a
        static let binint1: UInt8 = 0x4b
        static let binint2: UInt8 = 0x4d
        static let long: UInt8 = 0x4c
        static let long1: UInt8 = 0x8a
        static let long4: UInt8 = 0x8b

        static let float: UInt8 = 0x46
        static let binfloat: UInt8 = 0x47

        static let unicode: UInt8 = 0x56
        static let string: UInt8 = 0x53
        static let binstring: UInt8 = 0x54
        static let shortBinstring: UInt8 = 0x55
        static let shortBinunicode: UInt8 = 0x8c
        static let binunicode: UInt8 = 0x58
        static let binunicode8: UInt8 = 0x8d

        static let binbytes: UInt8 = 0x42
        static let shortBinbytes: UInt8 = 0x43
        static let binbytes8: UInt8 = 0x8e
        static let bytearray8: UInt8 = 0x96

        static let mark: UInt8 = 0x28
        static let emptyTuple: UInt8 = 0x29
        static let tuple: UInt8 = 0x74
        static let tuple1: UInt8 = 0x85
        static let tuple2: UInt8 = 0x86
        static let tuple3: UInt8 = 0x87

        static let emptyList: UInt8 = 0x5d
        static let list: UInt8 = 0x6c
        static let append: UInt8 = 0x61
        static let appends: UInt8 = 0x65

        static let emptyDict: UInt8 = 0x7d
        static let dict: UInt8 = 0x64
        static let setitem: UInt8 = 0x73
        static let setitems: UInt8 = 0x75

        static let emptySet: UInt8 = 0x8f
        static let addItems: UInt8 = 0x90
        static let frozenset: UInt8 = 0x91

        static let pop: UInt8 = 0x30
        static let popMark: UInt8 = 0x31
        static let dup: UInt8 = 0x32

        static let get: UInt8 = 0x67
        static let binget: UInt8 = 0x68
        static let longBinget: UInt8 = 0x6a
        static let put: UInt8 = 0x70
        static let binput: UInt8 = 0x71
        static let longBinput: UInt8 = 0x72
        static let memoize: UInt8 = 0x94

        static let globalRef: UInt8 = 0x63
        static let stackGlobal: UInt8 = 0x93
        static let reduce: UInt8 = 0x52
        static let newobj: UInt8 = 0x81
        static let newobjEx: UInt8 = 0x92
        static let build: UInt8 = 0x62
    }
}

// MARK: - 语法树映射

/// 把 `renpy.ast.*` 节点翻译成 `VNStmt`。
///
/// 只映射会出现在剧情里的节点；界面/样式/变换这类节点直接跳过，不影响故事；
/// 认不出的节点保留成 `.unknown`，由运行时报错，绝不猜成另一条语句。
private struct AstBuilder {
    var warnings: [String] = []

    mutating func statements(_ value: PklValue?) -> [VNStmt] {
        guard let value, case .array(let items) = value else { return [] }
        var result: [VNStmt] = []
        for item in items {
            result.append(contentsOf: convert(item))
        }
        return result
    }

    private mutating func convert(_ value: PklValue) -> [VNStmt] {
        guard case .object(let object) = value, let name = Self.shortName(object.className) else { return [] }

        switch name {
        case "Label":
            return label(value)
        case "Say":
            return say(value)
        case "TranslateSay":
            if let language = Self.text(of: Self.field(value, "language")), !language.isEmpty { return [] }
            return say(value)
        case "Menu":
            return menu(value)
        case "Jump":
            return jump(value)
        case "Call":
            return call(value)
        case "Return":
            return [.returnStatement]
        case "If":
            return conditional(value)
        case "While":
            guard let condition = Self.text(of: Self.field(value, "condition")) else { return [] }
            return [.loop(condition: ExpressionParser.parse(condition),
                          body: statements(Self.field(value, "block")))]
        case "Pass":
            return []
        case "Scene":
            return Self.scene(value)
        case "Show":
            return Self.show(value)
        case "Hide":
            return Self.hide(value)
        case "Image":
            return image(value)
        case "Define":
            return define(value, isDefault: false)
        case "Default":
            return define(value, isDefault: true)
        case "Init":
            return statements(Self.field(value, "block"))
        case "Python", "EarlyPython":
            return python(value)
        case "UserStatement":
            return userStatement(value)
        case "Translate":
            // language 为空的是默认语言包装块（槽 2 的静态变换产物），摊平即可
            if let language = Self.text(of: Self.field(value, "language")), !language.isEmpty { return [] }
            return statements(Self.field(value, "block"))
        case "Screen", "Style", "Transform", "Testcase", "RPY", "With", "ShowLayer", "Camera",
             "PostUserStatement", "EndTranslate", "TranslateString", "TranslatePython",
             "TranslateBlock", "TranslateEarlyBlock":
            return []
        default:
            return [.unknown(line: "无法识别的脚本节点：\(name)")]
        }
    }

    // MARK: 各种语句

    private mutating func label(_ value: PklValue) -> [VNStmt] {
        // 现代版本把名字存进 _name（Node.name 是属性），老版本直接存 name
        guard let name = Self.text(of: Self.field(value, "name")) ?? Self.text(of: Self.field(value, "_name")) else {
            warnings.append("编译脚本里的标签没有名字")
            return []
        }
        return [.label(name: name,
                       parameters: Self.parameters(Self.field(value, "parameters")),
                       body: statements(Self.field(value, "block")))]
    }

    private mutating func say(_ value: PklValue) -> [VNStmt] {
        guard let what = Self.text(of: Self.field(value, "what")) else { return [] }
        let who = Self.text(of: Self.field(value, "who"))
        var attributes = Self.strings(Self.field(value, "attributes"))
        attributes.append(contentsOf: Self.strings(Self.field(value, "temporary_attributes")))

        var character: VNExpr? = nil
        if let who, !who.isEmpty, Self.isIdentifier(who) {
            character = .variable(who)
        }
        return [.say(character: character, who: who, text: .literal(.string(what)), attributes: attributes)]
    }

    private mutating func menu(_ value: PklValue) -> [VNStmt] {
        var title: VNExpr? = nil
        var items: [VNMenuItem] = []

        if case .array(let entries)? = Self.field(value, "items") {
            for entry in entries {
                guard case .array(let parts) = entry, parts.count >= 3 else { continue }
                let text = Self.text(of: parts[0]) ?? ""
                let block = parts[2]

                var isCaption = false
                if case PklValue.none = block { isCaption = true }
                if isCaption {
                    // 单独一行的字符串是菜单说明
                    if !text.isEmpty, title == nil { title = .literal(.string(text)) }
                    continue
                }
                items.append(VNMenuItem(text: .literal(.string(text)),
                                        condition: Self.condition(parts[1]),
                                        showIf: nil,
                                        body: statements(block)))
            }
        }

        // 只有说明、没有选项的菜单在 Ren'Py 里什么也不做
        guard !items.isEmpty else { return [] }
        return [.menu(title: title, items: items)]
    }

    private mutating func jump(_ value: PklValue) -> [VNStmt] {
        guard var target = Self.text(of: Self.field(value, "target")) else { return [] }
        if Self.flag(value, "expression") {
            // 发行包常用 `jump expression game.get_start_label()` 选第一章，编译期先留好兜底
            return [.jumpExpression(ExpressionParser.parse(target), source: target)]
        }
        if target.hasPrefix("."), let base = Self.text(of: Self.field(value, "global_label")), !base.isEmpty {
            target = base + target
        }
        return [.jump(label: target)]
    }

    private mutating func call(_ value: PklValue) -> [VNStmt] {
        guard !Self.flag(value, "expression") else {
            warnings.append("暂不支持 call expression")
            return [.ignored("call expression")]
        }
        guard var target = Self.text(of: Self.field(value, "label")) else { return [] }
        if target.hasPrefix("."), let base = Self.text(of: Self.field(value, "global_label")), !base.isEmpty {
            target = base + target
        }
        return [.call(label: target, arguments: Self.arguments(Self.field(value, "arguments")))]
    }

    private mutating func conditional(_ value: PklValue) -> [VNStmt] {
        var branches: [VNBranch] = []
        var elseBody: [VNStmt] = []

        if case .array(let entries)? = Self.field(value, "entries") {
            for entry in entries {
                guard case .array(let parts) = entry, parts.count >= 2 else { continue }
                let body = statements(parts[1])
                let source = Self.text(of: parts[0])?.trimmingCharacters(in: .whitespaces) ?? ""
                // else 分支的条件被固定写成 "True"
                if source == "True" {
                    elseBody = body
                } else {
                    branches.append(VNBranch(condition: ExpressionParser.parse(source), body: body))
                }
            }
        }

        guard !branches.isEmpty else { return elseBody }
        return [.conditionals(branches: branches, elseBody: elseBody)]
    }

    /// `image 名字 = "资源"`：ATL 定义的图像暂时读不出来
    private mutating func image(_ value: PklValue) -> [VNStmt] {
        let definition = Self.imageComponents(Self.field(value, "imgname"))
        guard !definition.isEmpty else { return [] }
        if let source = Self.codeSource(Self.field(value, "code")) {
            return [.image(definition: definition, expression: ExpressionParser.parse(source))]
        }
        warnings.append("暂不支持 ATL 图像定义")
        return [.image(definition: definition, expression: .unsupported("ATL 图像定义"))]
    }

    private mutating func define(_ value: PklValue, isDefault: Bool) -> [VNStmt] {
        // `define gui.x = ...` 这类命名空间我们不求值
        guard (Self.text(of: Self.field(value, "store")) ?? "store") == "store" else { return [] }

        if let index = Self.field(value, "index"), !Self.isNone(index) {
            warnings.append("暂不支持带下标的 define/default")
            return [.ignored("define[...]")]
        }
        let operatorText = Self.text(of: Self.field(value, "operator")) ?? "="
        guard operatorText == "=" else {
            warnings.append("暂不支持 \(operatorText)= 形式的 define")
            return [.ignored("define \(operatorText)=")]
        }
        guard let name = Self.text(of: Self.field(value, "varname")),
              let source = Self.codeSource(Self.field(value, "code")) else { return [] }
        let expression = ExpressionParser.parse(source)
        return [isDefault ? .defaultVariable(name: name, value: expression)
                          : .define(name: name, value: expression)]
    }

    /// `python:` / `$` 语句：我们只搬运简单赋值，其余如实记进诊断
    private mutating func python(_ value: PklValue) -> [VNStmt] {
        guard let source = Self.codeSource(Self.field(value, "code")) else { return [] }
        var result: [VNStmt] = []
        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var accepted = false
            for statement in RpyParser.parse("$ " + line) {
                if case .assign = statement {
                    result.append(statement)
                    accepted = true
                }
            }
            if !accepted { warnings.append("忽略 python 语句：\(line)") }
        }
        return result
    }

    /// 游戏自定义语句（`play`、`voice` 等音频语句也是以这种形式存进语法树的）
    private mutating func userStatement(_ value: PklValue) -> [VNStmt] {
        guard let line = Self.text(of: Self.field(value, "line"))?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return [] }
        let keyword = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            .map { String($0).lowercased() } ?? ""
        if keyword == "layeredimage" {
            guard let image = Self.layeredImage(value) else {
                warnings.append("无法解析分层立绘：\(line)")
                return [.ignored(line)]
            }
            return [.layeredImage(image)]
        }
        // 只重放音频/暂停这类能确定语义的语句，别的语句跳过但留下诊断
        guard ["play", "stop", "voice", "pause"].contains(keyword) else {
            warnings.append("忽略语句：\(line)")
            return [.ignored(line)]
        }
        let parsed = RpyParser.parse(line)
        guard !parsed.isEmpty, !parsed.contains(where: Self.isUnknown) else {
            warnings.append("忽略语句：\(line)")
            return [.ignored(line)]
        }
        return parsed
    }

    /// `layeredimage hana:`：parsed 的第二项是 RawLayeredImage，children 按声明顺序排列
    static func layeredImage(_ value: PklValue) -> VNLayeredImage? {
        guard case .array(let parsed)? = field(value, "parsed"), parsed.count >= 2,
              className(parsed[1]) == "RawLayeredImage",
              let name = text(of: field(parsed[1], "name")),
              case .array(let children)? = field(parsed[1], "children") else { return nil }

        var entries: [VNLayeredImage.Entry] = []
        for child in children {
            switch className(child) {
            case "RawAlways":
                if let image = imageExpression(of: field(child, "image")) {
                    entries.append(.always(image))
                }
            case "RawAttributeGroup":
                let groupName = text(of: field(child, "group"))
                    ?? text(of: field(child, "image_name")) ?? "group"
                let groupAttributes = attributes(of: child)
                guard !groupAttributes.isEmpty else { continue }
                entries.append(.group(VNLayeredImage.Group(name: groupName, attributes: groupAttributes)))
            case "RawAttribute":
                // 没写 group 的属性自成一组
                if let attribute = attribute(child) {
                    entries.append(.group(VNLayeredImage.Group(name: attribute.name, attributes: [attribute])))
                }
            default:
                break
            }
        }
        return VNLayeredImage(name: name, entries: entries)
    }

    static func attributes(of group: PklValue) -> [VNLayeredImage.Attribute] {
        guard case .array(let children)? = field(group, "children") else { return [] }
        return children.compactMap { attribute($0) }
    }

    static func attribute(_ value: PklValue) -> VNLayeredImage.Attribute? {
        guard let name = text(of: field(value, "name")),
              let image = imageExpression(of: field(value, "image")) else { return nil }
        var isDefault = false
        if let properties = field(value, "properties"),
           let stored = lookup("default", in: properties) {
            if case .bool(let flag) = stored { isDefault = flag }
            if case .int(let number) = stored { isDefault = number != 0 }
        }
        return VNLayeredImage.Attribute(name: name, image: image, isDefault: isDefault)
    }

    /// 立绘部件的图像名：归档里既可能是带引号的表达式，也可能是裸的名字
    static func imageExpression(of value: PklValue?) -> VNExpr? {
        guard let source = text(of: value), !source.isEmpty else { return nil }
        let head = source.first
        guard head != "\"", head != "'" else { return ExpressionParser.parse(source) }
        return ExpressionParser.parse("\"\(source)\"")
    }

    // MARK: 字段读取

    static func shortName(_ className: String) -> String? {
        className.split(separator: ".").last.map(String.init)
    }

    static func className(_ value: PklValue) -> String? {
        guard case .object(let object) = value else { return nil }
        return shortName(object.className)
    }

    static func field(_ value: PklValue, _ key: String) -> PklValue? {
        guard case .object(let object) = value, let state = object.state else { return nil }
        return lookup(key, in: state)
    }

    /// 状态可能是普通字典，也可能是带 __slots__ 的类的 `(字典, 槽字典)`
    static func lookup(_ key: String, in state: PklValue) -> PklValue? {
        switch state {
        case .dictionary(let pairs):
            for (name, value) in pairs where text(of: name) == key { return value }
            return nil
        case .array(let parts):
            if parts.count == 2 { return lookup(key, in: parts[1]) }
            return nil
        default:
            return nil
        }
    }

    static func text(of value: PklValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text): return text
        case .bytes(let data): return PythonLiteral.decodeText(data)
        case .int(let number): return String(number)
        case .bool(let flag): return flag ? "True" : "False"
        case .float(let number): return String(number)
        case .reference(let name): return name
        case .object(let object):
            // PyExpr 是 str 的子类，用 __reduce__ 存成 (类, (文本, 位置…))
            if object.className.hasSuffix("PyExpr") || object.className.hasSuffix("Sentinel") {
                if let first = object.args.first { return text(of: first) }
                return nil
            }
            if object.args.count == 1, let only = text(of: object.args[0]) { return only }
            if let name = lookup("name", in: object.state ?? PklValue.none) { return text(of: name) }
            return nil
        default:
            return nil
        }
    }

    static func intValue(_ value: PklValue?) -> Int? {
        guard let value, case .int(let number) = value else { return nil }
        return Int(number)
    }

    static func flag(_ value: PklValue, _ key: String) -> Bool {
        guard let stored = field(value, key) else { return false }
        switch stored {
        case .bool(let result): return result
        case .int(let result): return result != 0
        default: return false
        }
    }

    static func isNone(_ value: PklValue) -> Bool {
        if case PklValue.none = value { return true }
        return false
    }

    static func isUnknown(_ statement: VNStmt) -> Bool {
        if case .unknown = statement { return true }
        return false
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return text.unicodeScalars.dropFirst().allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "."
        }
    }

    // MARK: 结构

    static func strings(_ value: PklValue?) -> [String] {
        guard let value, case .array(let items) = value else { return [] }
        return items.compactMap { text(of: $0) }
    }

    static func condition(_ value: PklValue?) -> VNExpr? {
        guard let source = text(of: value)?.trimmingCharacters(in: .whitespaces),
              !source.isEmpty, source != "True" else { return nil }
        return ExpressionParser.parse(source)
    }

    /// `call 标签(参数)` 的位置参数
    static func arguments(_ value: PklValue?) -> [VNExpr] {
        guard let value, case .array(let entries)? = field(value, "arguments") else { return [] }
        return entries.compactMap { entry -> VNExpr? in
            guard case .array(let parts) = entry, parts.count >= 2,
                  let source = text(of: parts[1]) else { return nil }
            return ExpressionParser.parse(source)
        }
    }

    /// 标签参数名；新版本是 Signature 对象，老版本是 ([(名字, 默认值)], …) 元组
    static func parameters(_ value: PklValue?) -> [String] {
        guard let value else { return [] }
        switch value {
        case PklValue.none:
            return []
        case .string(let name):
            return [name]
        case .dictionary(let pairs):
            return pairs.compactMap { pair -> String? in
                let kind = intValue(field(pair.1, "kind"))
                // 2 = *args，4 = **kwargs，位置绑定用不到它们
                if kind == 2 || kind == 4 { return nil }
                return text(of: pair.0)
            }
        case .array(let items):
            if let first = items.first, case .array(let pairs) = first {
                return pairs.compactMap { pair -> String? in
                    guard case .array(let parts) = pair else { return nil }
                    return text(of: parts.first)
                }
            }
            return items.compactMap { item -> String? in
                if let name = text(of: field(item, "name")) { return name }
                return text(of: item)
            }
        case .object:
            if let nested = field(value, "parameters") { return parameters(nested) }
            if let name = text(of: field(value, "name")) { return [name] }
            return []
        default:
            return []
        }
    }

    static func imageName(_ value: PklValue?) -> String {
        guard let value else { return "" }
        if case .array(let parts) = value {
            return parts.compactMap { text(of: $0) }.joined(separator: " ")
        }
        return text(of: value) ?? ""
    }

    /// imspec：3 元组 (图像名, at 列表, 层) 或 6/7 元组 (图像名, expression, tag, at, 层, zorder[, behind])
    static func imageSpec(_ value: PklValue?)
        -> (name: String, expression: String?, layer: String?, at: [String])? {
        guard let value, case .array(let parts) = value, parts.count >= 3 else { return nil }
        if parts.count >= 6 {
            return (imageName(parts[0]), text(of: parts[1]), text(of: parts[4]), strings(parts[3]))
        }
        return (imageName(parts[0]), nil, text(of: parts[2]), strings(parts[1]))
    }

    /// PyCode 的状态是 (版本, 源码, 位置, 模式, py, hash, 列)；老版本可能是字典
    static func codeSource(_ value: PklValue?) -> String? {
        guard let value else { return nil }
        if case .object(let object) = value {
            if case .array(let parts)? = object.state, parts.count >= 2, case .string(let source) = parts[1] {
                return source
            }
            if let source = field(value, "source") { return text(of: source) }
            return nil
        }
        return text(of: value)
    }

    static func imageComponents(_ value: PklValue?) -> [VNValue] {
        guard let value, case .array(let parts) = value else { return [] }
        return parts.compactMap { part -> VNValue? in
            guard let name = text(of: part) else { return nil }
            return .string(name)
        }
    }

    static func scene(_ value: PklValue) -> [VNStmt] {
        let layer = text(of: field(value, "layer")) ?? "master"
        guard let spec = imageSpec(field(value, "imspec")), !spec.name.isEmpty else {
            return [.scene(name: nil, layer: layer)]
        }
        return [.scene(name: spec.name, layer: spec.layer ?? layer)]
    }

    static func show(_ value: PklValue) -> [VNStmt] {
        guard let spec = imageSpec(field(value, "imspec")) else { return [] }
        var name = spec.name
        var expression: VNExpr? = nil
        if let source = spec.expression, !source.isEmpty {
            // `show expression "…"` 没有图像名，用表达式本身当标识
            if name.isEmpty { name = source }
            expression = ExpressionParser.parse(source)
        }
        guard !name.isEmpty else { return [] }
        return [.show(name: name, expression: expression,
                      layer: spec.layer ?? "master", at: spec.at)]
    }

    static func hide(_ value: PklValue) -> [VNStmt] {
        guard let spec = imageSpec(field(value, "imspec")), !spec.name.isEmpty else { return [] }
        return [.hide(name: spec.name, layer: spec.layer ?? "master")]
    }
}
