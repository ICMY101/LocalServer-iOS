import Foundation

/// Python 字面量的一个值。归档索引和 `define` 语句里出现的类型都在这里。
indirect enum PyValue {
    case none
    case bool(Bool)
    case int(Int64)
    case float(Double)
    /// 文本（str / unicode）
    case string(String)
    /// 字节串（bytes），旧版归档的文件名可能以它出现
    case bytes(Data)
    /// list 或 tuple
    case array([PyValue])
    /// dict
    case dictionary([(PyValue, PyValue)])

    var intValue: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    /// 当作文本读取；bytes 按 UTF-8 解，失败时按 Latin-1（对应 Python 2 的 str）
    var textValue: String? {
        switch self {
        case .string(let value): return value
        case .bytes(let value): return PythonLiteral.decodeText(value)
        case .int(let value): return String(value)
        default: return nil
        }
    }

    var arrayValue: [PyValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var isTruthy: Bool {
        switch self {
        case .none: return false
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .float(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .bytes(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        case .dictionary(let value): return !value.isEmpty
        }
    }

    /// 用作 dict 键的字符串形式
    var hashKey: String {
        switch self {
        case .string(let value): return value
        case .bytes(let value): return PythonLiteral.decodeText(value) ?? ""
        case .int(let value): return String(value)
        case .bool(let value): return value ? "True" : "False"
        case .none: return "None"
        default: return ""
        }
    }
}

/// 解析 Python 字面量文本，相当于 `ast.literal_eval` 支持的子集。
///
/// 用于读取旧版 RPA 归档的索引（repr 文本），以及 `options.txt` 里的 `define config.x = ...`。
/// 按 UTF-8 字节扫描：repr 里的非 ASCII 字符要么是 `\xNN`、`\uXXXX` 转义，要么是原始 UTF-8 字节。
enum PythonLiteral {
    /// 整段必须是一个完整字面量，否则返回 nil
    static func parse(_ text: String) -> PyValue? {
        var parser = Parser(input: Array(text.utf8))
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        return parser.isAtEnd ? value : nil
    }

    /// 只取开头能解析出来的字面量，忽略后面的内容
    static func parsePrefix(_ text: String) -> PyValue? {
        var parser = Parser(input: Array(text.utf8))
        return parser.parseValue()
    }

    static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        return latin1String(data)
    }

    /// Latin-1：每个字节直接对应同码位的字符
    static func latin1String(_ data: Data) -> String {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(data.count)
        for byte in data { scalars.append(UnicodeScalar(byte)) }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: - 扫描器

    private struct Parser {
        let input: [UInt8]
        var pos = 0

        private static let singleQuote: UInt8 = 0x27
        private static let doubleQuote: UInt8 = 0x22
        private static let backslash: UInt8 = 0x5c

        var isAtEnd: Bool { pos >= input.count }
        var current: UInt8? { isAtEnd ? nil : input[pos] }

        func peek(_ offset: Int) -> UInt8? {
            pos + offset < input.count ? input[pos + offset] : nil
        }

        mutating func advance(_ count: Int = 1) { pos = min(pos + count, input.count) }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d || byte == 0x0c {
                advance()
            }
        }

        // MARK: 分发

        mutating func parseValue() -> PyValue? {
            skipWhitespace()
            guard let byte = current else { return nil }

            switch byte {
            case UInt8(ascii: "["):
                advance()
                return parseElements(closing: UInt8(ascii: "]")).map { PyValue.array($0) }
            case UInt8(ascii: "("):
                advance()
                return parseElements(closing: UInt8(ascii: ")")).map { PyValue.array($0) }
            case UInt8(ascii: "{"):
                advance()
                return parseBraces()
            case Self.singleQuote, Self.doubleQuote:
                return parseStringLiteral(raw: false, isBytes: false)
            default:
                break
            }

            if isPrefixStart(byte) {
                return parsePrefixedString()
            }
            if byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || isDigit(byte) || byte == UInt8(ascii: ".") {
                return parseNumber()
            }
            return parseKeyword()
        }

        private func isPrefixStart(_ byte: UInt8) -> Bool {
            switch Character(UnicodeScalar(byte)).lowercased() {
            case "b", "u", "r", "f": return true
            default: return false
            }
        }

        /// `b'..'`、`rb".."`、`u'..'` 等；前缀后不是引号时不当作字符串
        mutating func parsePrefixedString() -> PyValue? {
            let mark = pos
            var raw = false
            var isBytes = false
            var seen = 0
            while let byte = current, isPrefixStart(byte), seen < 3 {
                switch Character(UnicodeScalar(byte)).lowercased() {
                case "r": raw = true
                case "b": isBytes = true
                default: break
                }
                advance()
                seen += 1
            }
            guard let byte = current, byte == Self.singleQuote || byte == Self.doubleQuote else {
                pos = mark
                return parseKeyword()
            }
            return parseStringLiteral(raw: raw, isBytes: isBytes)
        }

        mutating func parseKeyword() -> PyValue? {
            var name = ""
            while let byte = current, isIdentifier(byte) {
                name.append(Character(UnicodeScalar(byte)))
                advance()
            }
            switch name {
            case "True": return .bool(true)
            case "False": return .bool(false)
            case "None": return .none
            case "inf", "Infinity": return .float(.infinity)
            case "nan", "NaN": return .float(.nan)
            default: return nil
            }
        }

        // MARK: 容器

        /// 已吃掉开括号，读到闭括号为止；逗号可选，允许尾逗号
        mutating func parseElements(closing: UInt8) -> [PyValue]? {
            var values: [PyValue] = []
            while true {
                skipWhitespace()
                if current == closing {
                    advance()
                    return values
                }
                guard !isAtEnd else { return nil }
                guard let value = parseValue() else { return nil }
                values.append(value)
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    advance()
                    continue
                }
                if current == closing {
                    advance()
                    return values
                }
                return nil
            }
        }

        /// dict 或 set（set 按数组返回）
        mutating func parseBraces() -> PyValue? {
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                advance()
                return .dictionary([])
            }
            var pairs: [(PyValue, PyValue)] = []
            var items: [PyValue] = []
            var sawColon = false
            while true {
                skipWhitespace()
                guard !isAtEnd else { return nil }
                guard let key = parseValue() else { return nil }
                skipWhitespace()
                if current == UInt8(ascii: ":") {
                    sawColon = true
                    advance()
                    guard let value = parseValue() else { return nil }
                    pairs.append((key, value))
                } else {
                    if sawColon { return nil }
                    items.append(key)
                }
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    advance()
                    continue
                }
                if current == UInt8(ascii: "}") {
                    advance()
                    return sawColon ? .dictionary(pairs) : .array(items)
                }
                return nil
            }
        }

        // MARK: 数字

        mutating func parseNumber() -> PyValue? {
            var token = ""
            if let byte = current, byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") {
                if byte == UInt8(ascii: "-") { token = "-" }
                advance()
            }
            var radix = 10
            if current == UInt8(ascii: "0"), let next = peek(1) {
                switch Character(UnicodeScalar(next)).lowercased() {
                case "x": radix = 16
                case "o": radix = 8
                case "b": radix = 2
                default: break
                }
            }

            if radix != 10 {
                advance(2) // 吃掉 0x / 0o / 0b
                var digits = ""
                while let byte = current, isRadixDigit(byte, radix: radix) || byte == UInt8(ascii: "_") {
                    if byte != UInt8(ascii: "_") { digits.append(Character(UnicodeScalar(byte))) }
                    advance()
                }
                if digits.isEmpty { return nil }
                guard let magnitude = Int(digits, radix: radix) else { return .int(Int64.max) }
                return .int(token == "-" ? -Int64(magnitude) : Int64(magnitude))
            }

            while let byte = current, isNumberPart(byte) {
                token.append(Character(UnicodeScalar(byte)))
                advance()
            }
            let cleaned = token.replacingOccurrences(of: "_", with: "")
            guard !cleaned.isEmpty else { return nil }
            // Python 2 的 long 带 L 后缀
            let text = (cleaned.hasSuffix("l") || cleaned.hasSuffix("L")) ? String(cleaned.dropLast()) : cleaned
            if text.isEmpty || text == "-" || text == "+" { return nil }
            if text.contains(".") || text.contains("e") || text.contains("E") || text.contains("inf") || text.contains("nan") {
                return Double(text).map { PyValue.float($0) }
            }
            if let value = Int(text) { return .int(Int64(value)) }
            return Double(text).map { PyValue.float($0) }
        }

        // MARK: 字符串

        /// `current` 是引号
        mutating func parseStringLiteral(raw: Bool, isBytes: Bool) -> PyValue? {
            let quote = current!
            var triple = false
            if peek(1) == quote, peek(2) == quote {
                triple = true
                advance(3)
            } else {
                advance()
            }
            var out: [UInt8] = []
            while true {
                guard !isAtEnd else { return nil }
                let byte = input[pos]

                if byte == quote {
                    if triple {
                        if peek(1) == quote, peek(2) == quote {
                            advance(3)
                            return makeString(out, isBytes: isBytes)
                        }
                        out.append(byte)
                        advance()
                        continue
                    }
                    advance()
                    return makeString(out, isBytes: isBytes)
                }

                if byte == Self.backslash {
                    if raw {
                        // 原始字符串：反斜杠保留，但 `\'` 不会结束字符串
                        out.append(byte)
                        advance()
                        if let next = current, next == quote {
                            out.append(next)
                            advance()
                        }
                        continue
                    }
                    advance()
                    appendEscape(&out)
                    continue
                }

                out.append(byte)
                advance()
            }
        }

        mutating func appendEscape(_ out: inout [UInt8]) {
            guard let byte = current else { return }
            advance()
            switch Character(UnicodeScalar(byte)) {
            case "n": out.append(0x0a)
            case "t": out.append(0x09)
            case "r": out.append(0x0d)
            case "a": out.append(0x07)
            case "b": out.append(0x08)
            case "f": out.append(0x0c)
            case "v": out.append(0x0b)
            case "\\": out.append(Self.backslash)
            case "'": out.append(Self.singleQuote)
            case "\"": out.append(Self.doubleQuote)
            case "0", "1", "2", "3", "4", "5", "6", "7":
                var value = Int(String(Character(UnicodeScalar(byte)))) ?? 0
                for _ in 0..<2 {
                    guard let next = current, isOctal(next) else { break }
                    value = value * 8 + (Int(String(Character(UnicodeScalar(next)))) ?? 0)
                    advance()
                }
                out.append(UInt8(truncatingIfNeeded: value))
            case "x":
                out.append(UInt8(truncatingIfNeeded: readDigits(count: 2, radix: 16)))
            case "u":
                appendCodePoint(readDigits(count: 4, radix: 16), to: &out)
            case "U":
                appendCodePoint(readDigits(count: 8, radix: 16), to: &out)
            default:
                // 未知转义原样保留（与 Python 一致）
                out.append(Self.backslash)
                out.append(byte)
            }
        }

        mutating func readDigits(count: Int, radix: Int) -> Int {
            var value = 0
            for _ in 0..<count {
                guard let byte = current, let digit = Int(String(Character(UnicodeScalar(byte))), radix: radix) else { break }
                value = value * radix + digit
                advance()
            }
            return value
        }

        mutating func appendCodePoint(_ code: Int, to out: inout [UInt8]) {
            guard let scalar = UnicodeScalar(code) else { return }
            out.append(contentsOf: Array(String(scalar).utf8))
        }

        private func makeString(_ raw: [UInt8], isBytes: Bool) -> PyValue {
            let data = Data(raw)
            if isBytes { return .bytes(data) }
            return .string(decodeRaw(data))
        }

        private func decodeRaw(_ data: Data) -> String {
            PythonLiteral.decodeText(data) ?? ""
        }

        // MARK: 字符分类

        private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
        private func isOctal(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x37 }

        private func isRadixDigit(_ byte: UInt8, radix: Int) -> Bool {
            if radix == 16 { return isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66) }
            if radix == 8 { return isOctal(byte) }
            if radix == 2 { return byte == 0x30 || byte == 0x31 }
            return isDigit(byte)
        }

        /// 十进制字面量可以出现的字符（含指数符号与十六进制字母，供后续判断）
        private func isNumberPart(_ byte: UInt8) -> Bool {
            isDigit(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
                || byte == UInt8(ascii: "l") || byte == UInt8(ascii: "L")
                || byte == UInt8(ascii: "x") || byte == UInt8(ascii: "X")
                || isHexLetter(byte)
        }

        private func isHexLetter(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
        }

        private func isIdentifier(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) || isDigit(byte) || byte == UInt8(ascii: "_")
        }
    }
}
