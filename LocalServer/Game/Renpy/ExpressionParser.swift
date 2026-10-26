import Foundation

/// Ren'Py 表达式解析（Python 语法的一个子集）。
///
/// 覆盖视觉小说脚本里实际会出现的写法：字面量、变量、属性访问、下标、调用、
/// 一元/二元运算、比较、`and`/`or`/`not`、`a if c else b`、列表与字典。
/// 解析不出来时返回 `.unsupported`，由运行时决定怎么提示，而不是编造一个假的值。
struct ExpressionParser {
    private let tokens: [Token]
    private var position = 0

    private init(_ source: String) {
        tokens = ExpressionLexer.tokenize(source)
    }

    /// 解析一整段表达式；无法理解时返回 `.unsupported(source)`
    static func parse(_ source: String) -> VNExpr {
        var parser = ExpressionParser(source)
        let expression = parser.parseTernary()
        return parser.isAtEnd ? expression : .unsupported(source)
    }

    // MARK: - 词法

    enum TokenKind: Equatable {
        case number
        case text
        case name
        case `operator`
        case punctuation
        case end
    }

    struct Token {
        var kind: TokenKind
        var text: String
    }

    enum ExpressionLexer {
        /// 字符串前缀只可能是这几个字母的组合
        private static let prefixCharacters = Set("bufrfBRUF")

        static func tokenize(_ source: String) -> [Token] {
            let characters = Array(source)
            var index = 0
            var tokens: [Token] = []

            func emit(_ kind: TokenKind, _ text: String) {
                tokens.append(Token(kind: kind, text: text))
            }

            while index < characters.count {
                let character = characters[index]

                if character == " " || character == "\t" || character == "\n" || character == "\r" {
                    index += 1
                    continue
                }
                // 注释到行尾
                if character == "#" {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                    continue
                }
                if character.isNumber || (character == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                    readNumber(characters, &index, emit)
                    continue
                }
                if character == "\"" || character == "'" {
                    let text = readString(characters, &index)
                    emit(.text, text ?? "")
                    continue
                }
                if isIdentifierStart(character) {
                    let start = index
                    while index < characters.count, isIdentifierCharacter(characters[index]) { index += 1 }
                    let name = String(characters[start..<index])
                    // `f"..."`、`b"..."`：前缀字母紧贴引号时按字符串处理
                    if name.count <= 3, name.allSatisfy({ prefixCharacters.contains($0) }),
                       index < characters.count, characters[index] == "\"" || characters[index] == "'" {
                        let text = readString(characters, &index)
                        emit(.text, text ?? "")
                        continue
                    }
                    emit(.name, name)
                    continue
                }
                if "=!<>+-*/%&|^~".contains(character) {
                    let start = index
                    index += 1
                    // 多字符运算符最多两个字符（==、!=、<=、>=、**）
                    if index < characters.count, isOperator(characters[index]),
                       isTwoCharacterOperator(String(characters[start]) + String(characters[index])) {
                        index += 1
                    }
                    emit(.operator, String(characters[start..<index]))
                    continue
                }
                emit(.punctuation, String(character))
                index += 1
            }
            emit(.end, "")
            return tokens
        }

        private static func isTwoCharacterOperator(_ text: String) -> Bool {
            ["==", "!=", "<=", ">=", "**"].contains(text)
        }

        /// 十进制与科学计数法；指数符号只在 e/E 之后吞掉
        private static func readNumber(_ characters: [Character], _ index: inout Int, _ emit: (TokenKind, String) -> Void) {
            let start = index
            var seenDot = false
            while index < characters.count {
                let character = characters[index]
                if character.isNumber {
                    index += 1
                } else if character == ".", !seenDot {
                    seenDot = true
                    index += 1
                } else if character == "_", index > start {
                    index += 1
                } else if (character == "e" || character == "E"), index > start {
                    index += 1
                    if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                        index += 1
                    }
                    // 指数部分必须紧跟数字，否则退回（例如 `1e5` 之外的 `1element`）
                    if index >= characters.count || !characters[index].isNumber {
                        break
                    }
                } else {
                    break
                }
            }
            emit(.number, String(characters[start..<index]))
        }

        static func isIdentifierStart(_ character: Character) -> Bool {
            character.isLetter || character == "_"
        }

        static func isIdentifierCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }

        static func isOperator(_ character: Character) -> Bool {
            "=!<>+-*/%&|^~".contains(character)
        }

        /// 读取字符串字面量，`index` 指向引号；支持三引号
        static func readString(_ characters: [Character], _ index: inout Int) -> String? {
            guard index < characters.count else { return nil }
            let quote = characters[index]
            var triple = false
            if index + 2 < characters.count, characters[index + 1] == quote, characters[index + 2] == quote {
                triple = true
                index += 3
            } else {
                index += 1
            }
            var out = ""
            while index < characters.count {
                let character = characters[index]
                if character == quote {
                    if triple {
                        if index + 2 < characters.count, characters[index + 1] == quote, characters[index + 2] == quote {
                            index += 3
                            return out
                        }
                        out.append(character)
                        index += 1
                        continue
                    }
                    index += 1
                    return out
                }
                if character == "\\", index + 1 < characters.count {
                    switch characters[index + 1] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    default: out.append(characters[index + 1])
                    }
                    index += 2
                    continue
                }
                out.append(character)
                index += 1
            }
            return nil
        }
    }

    // MARK: - 游标

    private var current: Token { position < tokens.count ? tokens[position] : Token(kind: .end, text: "") }
    private var isAtEnd: Bool { current.kind == .end }

    private func peek(_ offset: Int) -> Token {
        position + offset < tokens.count ? tokens[position + offset] : Token(kind: .end, text: "")
    }

    private mutating func advance() {
        if position < tokens.count { position += 1 }
    }

    /// 只有标点或运算符位置才允许“吃掉”，避免误吞标识符
    @discardableResult
    private mutating func eat(_ text: String) -> Bool {
        guard current.text == text, current.kind == .punctuation || current.kind == .operator else { return false }
        advance()
        return true
    }

    private func isKeyword(_ text: String) -> Bool {
        current.kind == .name && current.text == text
    }

    // MARK: - 语法

    /// `a if b else c`
    private mutating func parseTernary() -> VNExpr {
        let value = parseBinary(0)
        guard isKeyword("if") else { return value }
        advance()
        let condition = parseTernary()
        guard isKeyword("else") else { return .unsupported("缺少 else") }
        advance()
        let alternative = parseTernary()
        return .conditional(condition: condition, then: value, else: alternative)
    }

    private static let arithmeticPrecedence: [String: Int] = [
        "|": 10,
        "+": 20, "-": 20,
        "*": 30, "/": 30, "%": 30,
        "**": 40,
    ]

    private mutating func parseBinary(_ minimum: Int) -> VNExpr {
        var left = parseUnary()
        while true {
            if isKeyword("or") {
                guard 1 >= minimum else { return left }
                advance()
                left = .binary("or", left, parseBinary(1))
                continue
            }
            if isKeyword("and") {
                guard 2 >= minimum else { return left }
                advance()
                left = .binary("and", left, parseBinary(2))
                continue
            }
            if let comparison = peekComparison() {
                guard 3 >= minimum else { return left }
                left = .binary(comparison.operation, left, parseAfterComparison(comparison.length))
                continue
            }
            if current.kind == .operator, let level = Self.arithmeticPrecedence[current.text] {
                guard level >= minimum else { return left }
                let operation = current.text
                advance()
                left = .binary(operation, left, parseBinary(level + 1))
                continue
            }
            return left
        }
    }

    /// 比较运算符可能是 `not in` / `is not` 两个词
    private struct Comparison {
        var operation: String
        var length: Int
    }

    private func peekComparison() -> Comparison? {
        if current.kind == .operator, ["==", "!=", "<", "<=", ">", ">="].contains(current.text) {
            return Comparison(operation: current.text, length: 1)
        }
        if isKeyword("in") { return Comparison(operation: "in", length: 1) }
        if isKeyword("not"), peek(1).kind == .name, peek(1).text == "in" {
            return Comparison(operation: "not in", length: 2)
        }
        if isKeyword("is") {
            return peek(1).text == "not"
                ? Comparison(operation: "is not", length: 2)
                : Comparison(operation: "is", length: 1)
        }
        return nil
    }

    private mutating func parseAfterComparison(_ length: Int) -> VNExpr {
        advance(length)
        return parseBinary(4)
    }

    private mutating func advance(_ count: Int) {
        for _ in 0..<count { advance() }
    }

    private mutating func parseUnary() -> VNExpr {
        if isKeyword("not") {
            advance()
            return .unary("not", parseUnary())
        }
        if current.kind == .operator, current.text == "-" {
            advance()
            return .unary("-", parseUnary())
        }
        if current.kind == .operator, current.text == "+" {
            advance()
            return parseUnary()
        }
        return parsePostfix()
    }

    private mutating func parsePostfix() -> VNExpr {
        var value = parseAtom()
        while true {
            if current.kind == .punctuation, current.text == "(" {
                advance()
                let arguments = parseArguments()
                value = .call(value, arguments.positional, arguments.keywords)
                continue
            }
            if current.kind == .punctuation, current.text == "[" {
                advance()
                let index = parseTernary()
                _ = eat("]")
                value = .element(value, index)
                continue
            }
            if current.kind == .punctuation, current.text == "." {
                advance()
                let name = current.text
                guard current.kind == .name else { return .unsupported("属性名缺失") }
                advance()
                value = .attribute(value, name)
                continue
            }
            return value
        }
    }

    private mutating func parseArguments() -> (positional: [VNExpr], keywords: [(String, VNExpr)]) {
        var positional: [VNExpr] = []
        var keywords: [(String, VNExpr)] = []
        while !isAtEnd, current.text != ")" {
            if current.kind == .name, peek(1).kind == .operator, peek(1).text == "=", peek(2).text != "=" {
                let name = current.text
                advance(2)
                keywords.append((name, parseTernary()))
            } else {
                positional.append(parseTernary())
            }
            _ = eat(",")
        }
        _ = eat(")")
        return (positional, keywords)
    }

    private mutating func parseAtom() -> VNExpr {
        switch current.kind {
        case .number:
            let text = current.text.replacingOccurrences(of: "_", with: "")
            advance()
            if text.contains("e") || text.contains("E") || text.contains(".") {
                return .literal(.float(Double(text) ?? 0))
            }
            return .literal(.int(Int(text) ?? 0))
        case .text:
            let text = current.text
            advance()
            return .literal(.string(text))
        case .name:
            let name = current.text
            advance()
            switch name {
            case "True": return .literal(.bool(true))
            case "False": return .literal(.bool(false))
            case "None": return .literal(.none)
            default: return .variable(name)
            }
        case .punctuation:
            switch current.text {
            case "(":
                advance()
                let value = parseTernary()
                _ = eat(")")
                return value
            case "[":
                advance()
                var items: [VNExpr] = []
                while !isAtEnd, current.text != "]" {
                    items.append(parseTernary())
                    _ = eat(",")
                }
                _ = eat("]")
                return .list(items)
            case "{":
                advance()
                var pairs: [(VNExpr, VNExpr)] = []
                while !isAtEnd, current.text != "}" {
                    let key = parseTernary()
                    if eat(":") {
                        pairs.append((key, parseTernary()))
                    }
                    _ = eat(",")
                }
                _ = eat("}")
                return .dictionary(pairs)
            default:
                let text = current.text
                advance()
                return .unsupported(text)
            }
        case .operator:
            let text = current.text
            advance()
            return .unsupported(text)
        case .end:
            return .unsupported("<表达式结束>")
        }
    }
}
