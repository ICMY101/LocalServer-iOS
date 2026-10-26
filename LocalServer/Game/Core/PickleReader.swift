import Foundation

/// Python pickle 的只读子集。
///
/// 只覆盖 RPA 归档索引里会出现的类型：int / bool / None / str / bytes / tuple / list / dict。
/// 遇到对象重建指令（GLOBAL、REDUCE、NEWOBJ、BUILD 等）时判定为不支持并返回 nil ——
/// 归档索引不该有这些指令，有则说明它不是我们认识的格式，宁可失败也不要猜。
enum PickleReader {
    /// 单个条目的最大字节数，防御损坏的索引
    private static let maxLength = 64 * 1024 * 1024

    static func load(_ data: Data) -> PyValue? {
        var reader = Reader(input: Array(data), maxLength: maxLength)
        return reader.run()
    }

    /// 栈元素：真实值，或 MARK 哨兵
    private enum Frame {
        case value(PyValue)
        case mark
    }

    private struct Reader {
        let input: [UInt8]
        let maxLength: Int
        var pos = 0
        var stack: [Frame] = []
        var memo: [PyValue] = []

        var isAtEnd: Bool { pos >= input.count }

        // MARK: 字节读取

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= maxLength, pos + count <= input.count else { return nil }
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

        mutating func i32() -> Int? {
            u32().map { Int(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) }
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
                if out.count > maxLength { return nil }
            }
            return nil
        }

        mutating func bigEndianDouble() -> Double? {
            guard let b = take(8) else { return nil }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(b[i]) << (8 * (7 - i)) }
            return Double(bitPattern: bits)
        }

        /// LONG1/LONG4：小端、符号位在最高字节的 0x80
        mutating func signedLittleEndian(_ length: Int) -> Int64? {
            guard length >= 0, let bytes = take(length) else { return nil }
            if bytes.isEmpty { return 0 }
            if bytes.count > 8 {
                // 超出 Int64，索引里不可能出现这么大的数
                return nil
            }
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

        mutating func push(_ value: PyValue) { stack.append(.value(value)) }

        mutating func popValue() -> PyValue? {
            guard case .value(let value)? = stack.popLast() else { return nil }
            return value
        }

        mutating func topValue() -> PyValue? {
            guard case .value(let value)? = stack.last else { return nil }
            return value
        }

        mutating func replaceTop(_ value: PyValue) { stack[stack.count - 1] = .value(value) }

        /// 取出 MARK 之上的所有值，并移除 MARK
        mutating func popMark() -> [PyValue]? {
            guard let index = stack.lastIndex(where: { if case .mark = $0 { return true }; return false }) else {
                return nil
            }
            let values = stack[(index + 1)...].compactMap { frame -> PyValue? in
                if case .value(let value) = frame { return value }
                return nil
            }
            stack.removeSubrange(index...)
            return values
        }

        mutating func memoPut(at index: Int, value: PyValue) {
            while memo.count <= index { memo.append(.none) }
            memo[index] = value
        }

        mutating func memoGet(_ index: Int) -> PyValue? {
            guard index >= 0, index < memo.count else { return nil }
            return memo[index]
        }

        /// 协议 0/1 的十进制行；01/00 是 bool
        static func number(fromLine text: String) -> PyValue? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed == "01" { return .bool(true) }
            if trimmed == "00" { return .bool(false) }
            let body = (trimmed.hasSuffix("L") || trimmed.hasSuffix("l")) ? String(trimmed.dropLast()) : trimmed
            let negative = body.hasPrefix("-")
            let digits = negative ? String(body.dropFirst()) : body
            if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
                guard let value = Int(digits.dropFirst(2), radix: 16) else { return nil }
                return .int(negative ? -Int64(value) : Int64(value))
            }
            guard let value = Int(digits) else { return nil }
            return .int(negative ? -Int64(value) : Int64(value))
        }

        // MARK: 主循环

        mutating func run() -> PyValue? {
            while !isAtEnd {
                let code = input[pos]
                pos += 1
                guard execute(code) else { return nil }
                if code == Opcode.stop { return topValue() }
            }
            return topValue()
        }

        mutating func execute(_ code: UInt8) -> Bool {
            switch code {
            case Opcode.proto: return skip(1)
            case Opcode.frame: return skip(8)
            case Opcode.stop: return true

            case Opcode.none: push(.none); return true
            case Opcode.newTrue: push(.bool(true)); return true
            case Opcode.newFalse: push(.bool(false)); return true

            case Opcode.int, Opcode.long:
                guard let text = line(), let value = Self.number(fromLine: text) else { return false }
                push(value); return true
            case Opcode.binint:
                guard let value = i32() else { return false }
                push(.int(Int64(value))); return true
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
            case Opcode.binstring, Opcode.shortBinstring:
                guard let bytes = readLengthPrefixed(code == Opcode.shortBinstring) else { return false }
                push(.bytes(Data(bytes))); return true

            case Opcode.shortBinunicode:
                guard let bytes = readLengthPrefixed(true) else { return false }
                push(.string(String(decoding: bytes, as: UTF8.self))); return true
            case Opcode.binunicode:
                guard let bytes = readLengthPrefixed(false) else { return false }
                push(.string(String(decoding: bytes, as: UTF8.self))); return true
            case Opcode.binunicode8:
                guard let length = u64(), length <= Int64(maxLength), let bytes = take(Int(length)) else { return false }
                push(.string(String(decoding: bytes, as: UTF8.self))); return true

            case Opcode.shortBinbytes:
                guard let bytes = readLengthPrefixed(true) else { return false }
                push(.bytes(Data(bytes))); return true
            case Opcode.binbytes:
                guard let bytes = readLengthPrefixed(false) else { return false }
                push(.bytes(Data(bytes))); return true
            case Opcode.binbytes8:
                guard let length = u64(), length <= Int64(maxLength), let bytes = take(Int(length)) else { return false }
                push(.bytes(Data(bytes))); return true

            case Opcode.mark: stack.append(.mark); return true
            case Opcode.emptyTuple: push(.array([])); return true
            case Opcode.tuple1, Opcode.tuple2, Opcode.tuple3:
                let count = Int(code - Opcode.tuple1) + 1
                guard stack.count >= count else { return false }
                let values = stack.suffix(count).compactMap { frame -> PyValue? in
                    if case .value(let value) = frame { return value }
                    return nil
                }
                guard values.count == count else { return false }
                stack.removeLast(count)
                push(.array(values)); return true
            case Opcode.tuple:
                guard let values = popMark() else { return false }
                push(.array(values)); return true

            case Opcode.emptyList: push(.array([])); return true
            case Opcode.list:
                guard let values = popMark() else { return false }
                push(.array(values)); return true
            case Opcode.append:
                guard let value = popValue(), let container = topValue(), case .array(var items) = container else {
                    return false
                }
                items.append(value)
                replaceTop(.array(items)); return true
            case Opcode.appends:
                guard let values = popMark(), let container = topValue(), case .array(var items) = container else {
                    return false
                }
                items.append(contentsOf: values)
                replaceTop(.array(items)); return true

            case Opcode.emptyDict: push(.dictionary([])); return true
            case Opcode.dict:
                guard let flat = popMark(), flat.count % 2 == 0 else { return false }
                push(.dictionary(pairs(from: flat))); return true
            case Opcode.setitem:
                guard let value = popValue(), let key = popValue(),
                      let container = topValue(), case .dictionary(var pairs) = container else { return false }
                pairs.append((key, value))
                replaceTop(.dictionary(pairs)); return true
            case Opcode.setitems:
                guard let flat = popMark(), flat.count % 2 == 0,
                      let container = topValue(), case .dictionary(var pairs) = container else { return false }
                pairs.append(contentsOf: pairs(from: flat))
                replaceTop(.dictionary(pairs)); return true

            case Opcode.emptySet: push(.array([])); return true
            case Opcode.addItems, Opcode.frozenset: return false

            case Opcode.pop: _ = popValue(); return true
            case Opcode.popMark: _ = popMark(); return true
            case Opcode.dup:
                guard let last = topValue() else { return false }
                push(last); return true

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
                guard let text = line(), let index = Int(text), let last = topValue() else { return false }
                memoPut(at: index, value: last); return true
            case Opcode.binput:
                guard let index = u8(), let last = topValue() else { return false }
                memoPut(at: index, value: last); return true
            case Opcode.longBinput:
                guard let index = u32(), let last = topValue() else { return false }
                memoPut(at: index, value: last); return true
            case Opcode.memoize:
                guard let last = topValue() else { return false }
                memo.append(last); return true

            default:
                // GLOBAL / STACK_GLOBAL / REDUCE / NEWOBJ / BUILD / EXT / PERSID 等：不支持
                return false
            }
        }

        /// 长度前缀 + 数据；short 形式 1 字节，长形式 4 字节
        mutating func readLengthPrefixed(_ short: Bool) -> [UInt8]? {
            guard let length = short ? u8() : u32() else { return nil }
            return take(length)
        }

        func pairs(from flat: [PyValue]) -> [(PyValue, PyValue)] {
            var result: [(PyValue, PyValue)] = []
            result.reserveCapacity(flat.count / 2)
            stride(from: 0, to: flat.count, by: 2).forEach { result.append((flat[$0], flat[$0 + 1])) }
            return result
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

        static let `int`: UInt8 = 0x49
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
    }
}

/// 处理 Python 源码里的转义序列
enum Unescaper {
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let characters = Array(text)
        var index = 0
        var result = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            guard character == "\\", index < characters.count else { result.append(character); continue }
            let next = characters[index]
            switch next {
            case "n": result.append("\n"); index += 1
            case "t": result.append("\t"); index += 1
            case "r": result.append("\r"); index += 1
            case "\\": result.append("\\"); index += 1
            case "'": result.append("'"); index += 1
            case "\"": result.append("\""); index += 1
            case "x", "u", "U":
                let count = next == "x" ? 2 : (next == "u" ? 4 : 8)
                index += 1
                var value = 0
                for _ in 0..<count, index < characters.count {
                    guard let digit = Int(String(characters[index]), radix: 16) else { break }
                    value = value * 16 + digit
                    index += 1
                }
                if let scalar = UnicodeScalar(value) { result.append(Character(scalar)) }
            default:
                result.append(next)
                index += 1
            }
        }
        return result
    }
}
