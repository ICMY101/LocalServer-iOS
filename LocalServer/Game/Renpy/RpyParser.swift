import Foundation

/// `.rpy` 脚本的语句解析器：把脚本文本变成 `VNStmt` 树。
///
/// 语法以官方 `renpy/parser.py` 的语句分派表（`@statement` 注册的关键字）和
/// `renpy/lexer.py` 的词法为准：
/// - 物理行按未闭合的引号/括号、行尾反斜杠合并成逻辑行，块靠缩进划分；
/// - 字符串按 Ren'Py 的规则折叠空白并去转义（`\{` 会变成 `{{`，交给文本管线当字面花括号）；
/// - 认不出的结构返回 `.unknown`，由运行时报错，绝不猜成另一条语句。
struct RpyParser {
    /// 一条逻辑行（合并续行之后的结果）
    struct LogicalLine {
        let indent: Int
        let number: Int
        let text: String
    }

    private let lines: [LogicalLine]
    private var cursor = 0
    /// 最近一次出现的顶层标签，用来展开 `.子标签` 这种写法
    private var globalLabel: String? = nil

    /// 解析一份 `.rpy` 脚本，返回顶层语句
    static func parse(_ source: String) -> [VNStmt] {
        // 有些编辑器会在文件头写入 BOM，它既不是空白也不是注释
        let cleaned = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        var parser = RpyParser(lines: logicalLines(cleaned))
        return parser.parseBlock(minIndent: 0)
    }

    /// 这条语句是否带块：出现顶层冒号就算，因为 `python: hide` 的冒号后面还有内容
    static func introducesBlock(_ text: String) -> Bool {
        let characters = Array(text)
        var index = 0
        var depth = 0
        var quote: Character? = nil

        while index < characters.count {
            let character = characters[index]
            if let delimiter = quote {
                if character == "\\", index + 1 < characters.count { index += 2; continue }
                if character == delimiter { quote = nil }
                index += 1
                continue
            }
            if character == "#" { return false }
            if character == "\"" || character == "'" {
                quote = character
                index += 1
                continue
            }
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
            if character == ":" , depth == 0 { return true }
            index += 1
        }
        return false
    }

    // MARK: - 逻辑行

    /// 切掉空行与注释行，并把续行合并成逻辑行
    static func logicalLines(_ source: String) -> [LogicalLine] {
        var result: [LogicalLine] = []
        var pending = ""
        var pendingIndent = 0
        var pendingNumber = 0
        var hasPending = false

        let physical = source.components(separatedBy: "\n")
        for (offset, rawLine) in physical.enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

            if hasPending {
                let state = scan(pending, quote: nil, triple: false, depth: 0)
                if state.quote != nil { // 跨行的三引号字符串：原样保留换行
                    pending += "\n" + line
                    continue
                }
                if state.depth > 0 { // 括号没闭合，属于同一个表达式
                    pending += " " + plainText(line)
                    continue
                }
                if pending.hasSuffix("\\") { // 显式续行
                    pending = String(pending.dropLast()) + plainText(line)
                    continue
                }
                result.append(LogicalLine(indent: pendingIndent, number: pendingNumber, text: pending))
                hasPending = false
            }

            let text = plainText(line)
            guard !text.isEmpty else { continue }
            pending = text
            pendingIndent = indentOf(line)
            pendingNumber = offset + 1
            hasPending = true
        }

        if hasPending {
            result.append(LogicalLine(indent: pendingIndent, number: pendingNumber, text: pending))
        }
        return result
    }

    /// 去首尾空白，并去掉字符串之外的行尾注释
    private static func plainText(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let state = scan(trimmed, quote: nil, triple: false, depth: 0)
        guard let comment = state.comment else { return trimmed }
        if comment == 0 { return "" }
        return String(Array(trimmed)[0..<comment]).trimmingCharacters(in: .whitespaces)
    }

    /// 扫描一段文本收尾时的状态：还开着哪种引号、括号深度、行尾注释的位置
    private static func scan(_ text: String, quote: Character?, triple: Bool, depth: Int)
        -> (quote: Character?, triple: Bool, depth: Int, comment: Int?) {
        let characters = Array(text)
        var index = 0
        var openQuote = quote
        var openTriple = triple
        var openDepth = depth

        while index < characters.count {
            let character = characters[index]
            if let delimiter = openQuote {
                if character == "\\", index + 1 < characters.count { index += 2; continue }
                if character == delimiter, openTriple {
                    if isQuoteRun(characters, from: index, delimiter) {
                        index += 3
                        openQuote = nil
                        openTriple = false
                    } else {
                        index += 1
                    }
                    continue
                }
                if character == delimiter {
                    openQuote = nil
                    index += 1
                    continue
                }
                index += 1
                continue
            }
            if character == "#" { return (openQuote, openTriple, openDepth, index) }
            if character == "\"" || character == "'" {
                let run = isQuoteRun(characters, from: index, character)
                openQuote = character
                openTriple = run
                index += run ? 3 : 1
                continue
            }
            if character == "(" || character == "[" || character == "{" { openDepth += 1 }
            if character == ")" || character == "]" || character == "}" { openDepth -= 1 }
            index += 1
        }
        return (openQuote, openTriple, openDepth, nil)
    }

    /// 从 index 起是否是三个相同引号
    static func isQuoteRun(_ characters: [Character], from index: Int, _ delimiter: Character) -> Bool {
        guard index + 2 < characters.count else { return false }
        return characters[index] == delimiter
            && characters[index + 1] == delimiter
            && characters[index + 2] == delimiter
    }

    private static func indentOf(_ line: String) -> Int {
        var indent = 0
        for character in line {
            if character == " " { indent += 1 }
            else if character == "\t" { indent += 4 }
            else { break }
        }
        return indent
    }

    // MARK: - 块与分派

    private mutating func parseBlock(minIndent: Int) -> [VNStmt] {
        var result: [VNStmt] = []
        while cursor < lines.count, lines[cursor].indent >= minIndent {
            result.append(contentsOf: parseStatement())
        }
        return result
    }

    /// 语句后面若跟着块就解析它，没有则返回空
    private mutating func parseChildBlock(parentIndent: Int) -> [VNStmt] {
        guard cursor < lines.count, lines[cursor].indent > parentIndent else { return [] }
        return parseBlock(minIndent: lines[cursor].indent)
    }

    /// 整块丢弃（screen、python、ATL 等我们不执行的内容）
    private mutating func skipChildBlock(parentIndent: Int) {
        guard cursor < lines.count, lines[cursor].indent > parentIndent else { return }
        let childIndent = lines[cursor].indent
        while cursor < lines.count, lines[cursor].indent >= childIndent {
            cursor += 1
        }
    }

    private func peekKeyword() -> String? {
        guard cursor < lines.count else { return nil }
        var scanner = LineScanner(lines[cursor].text)
        return scanner.word()
    }

    private mutating func parseStatement() -> [VNStmt] {
        let line = lines[cursor]
        cursor += 1
        var scanner = LineScanner(line.text)

        if scanner.match("$") { return parseInlinePython(line) }
        guard let keyword = scanner.word() else { return [.unknown(line: line.text)] }

        switch keyword {
        case "label":
            return parseLabel(&scanner, line: line)
        case "if":
            return parseIf(&scanner, line: line)
        case "elif", "else":
            // 只有 if 会消费它们；走到这里说明缩进与所属的 if 对不上
            return [.unknown(line: line.text)]
        case "while":
            let condition = ExpressionParser.parse(scanner.expressionUpToColon())
            return [.loop(condition: condition, body: parseChildBlock(parentIndent: line.indent))]
        case "menu":
            return parseMenu(&scanner, line: line)
        case "jump":
            guard !scanner.keyword("expression"), let target = labelName(&scanner) else {
                return [.unknown(line: line.text)]
            }
            return [.jump(label: target)]
        case "call":
            guard !scanner.keyword("expression"), let target = labelName(&scanner) else {
                return [.unknown(line: line.text)]
            }
            _ = scanner.keyword("pass")
            let arguments = scanner.callArguments()
            if scanner.keyword("from") { _ = labelName(&scanner) } // 返回标签由调用栈代替
            return [.call(label: target, arguments: arguments)]
        case "return":
            return [.returnStatement]
        case "scene":
            return parseScene(&scanner, line: line)
        case "show":
            if scanner.keyword("layer") { return ignore(line, "show layer") }
            return parseShow(&scanner, line: line)
        case "hide":
            return parseHide(&scanner, line: line)
        case "image":
            return parseImage(&scanner, line: line)
        case "define":
            return parseDefine(&scanner, line: line, isDefault: false)
        case "default":
            return parseDefine(&scanner, line: line, isDefault: true)
        case "play":
            return parsePlay(&scanner, line: line)
        case "stop":
            return [.stop(channel: scanner.word() ?? "all")]
        case "voice":
            return [.voice(file: fileExpression(&scanner))]
        case "pause":
            let source = scanner.rest()
            return [.pause(duration: source.isEmpty ? nil : ExpressionParser.parse(source))]
        case "with":
            return ignore(line, "转场")
        case "pass", "camera":
            return ignore(line, keyword)
        case "python", "init", "screen", "style", "transform", "translate",
             "testcase", "testsuite", "rpy", "IF", "window", "nvl":
            return ignore(line, "\(keyword)")
        default:
            var attempt = LineScanner(line.text)
            if let say = parseSay(&attempt) { return [say] }
            if introducesBlock(line.text) { // 未知的带块语句：整块跳过，免得把块内容当成顶层语句
                skipChildBlock(parentIndent: line.indent)
                return [.ignored("跳过未知语句块：\(keyword)")]
            }
            return [.unknown(line: line.text)]
        }
    }

    /// 这条语句不影响剧情，可以整条（含块）忽略
    private mutating func ignore(_ line: LogicalLine, _ label: String) -> [VNStmt] {
        if introducesBlock(line.text) { skipChildBlock(parentIndent: line.indent) }
        return [.ignored(label)]
    }

    // MARK: - 各条语句

    private mutating func parseLabel(_ scanner: inout LineScanner, line: LogicalLine) -> [VNStmt] {
        guard let name = labelName(&scanner) else { return [.unknown(line: line.text)] }
        globalLabel = name
        let parameters = scanner.parenthesizedNames()
        _ = scanner.keyword("hide")
        guard scanner.match(":") else { return [.unknown(line: line.text)] }
        return [.label(name: name,
                       parameters: parameters,
                       body: parseChildBlock(parentIndent: line.indent))]
    }

    private mutating func parseIf(_ scanner: inout LineScanner, line: LogicalLine) -> [VNStmt] {
        var branches = [VNBranch(condition: ExpressionParser.parse(scanner.expressionUpToColon()),
                                 body: parseChildBlock(parentIndent: line.indent))]
        var elseBody: [VNStmt] = []

        while cursor < lines.count, lines[cursor].indent == line.indent,
              let next = peekKeyword(), next == "elif" || next == "else" {
            let head = lines[cursor]
            cursor += 1
            var inner = LineScanner(head.text)
            _ = inner.word()
            if next == "elif" {
                branches.append(VNBranch(condition: ExpressionParser.parse(inner.expressionUpToColon()),
                                         body: parseChildBlock(parentIndent: head.indent)))
            } else {
                elseBody = parseChildBlock(parentIndent: head.indent)
            }
        }
        return [.conditionals(branches: branches, elseBody: elseBody)]
    }

    private mutating func parseMenu(_ scanner: inout LineScanner, line: LogicalLine) -> [VNStmt] {
        _ = labelName(&scanner)
        _ = scanner.parenthesizedBody()
        guard introducesBlock(line.text) else { return [.unknown(line: line.text)] }
        guard cursor < lines.count, lines[cursor].indent > line.indent else {
            return [.menu(title: nil, items: [])]
        }

        let itemIndent = lines[cursor].indent
        var title: VNExpr? = nil
        var items: [VNMenuItem] = []

        while cursor < lines.count, lines[cursor].indent >= itemIndent {
            let itemLine = lines[cursor]
            cursor += 1
            guard itemLine.indent == itemIndent else { continue } // 更深缩进已由上一条选项消费

            var item = LineScanner(itemLine.text)
            if item.keyword("with") || item.keyword("set") { continue }

            if let raw = item.stringLiteral() {
                _ = item.parenthesizedBody()
                var condition: VNExpr? = nil
                var showIf: VNExpr? = nil
                if item.keyword("if") { condition = ExpressionParser.parse(item.expressionUpToColon()) }
                if item.keyword("showif") { showIf = ExpressionParser.parse(item.expressionUpToColon()) }
                if item.match(":") {
                    items.append(VNMenuItem(text: .literal(.string(raw)),
                                            condition: condition,
                                            showIf: showIf,
                                            body: parseChildBlock(parentIndent: itemLine.indent)))
                } else if title == nil {
                    title = .literal(.string(raw)) // 单独一行的字符串是菜单说明
                }
                continue
            }

            // say menuitem：`说话人 "问题"`，只取问题文本作为菜单说明
            var prompt = LineScanner(itemLine.text)
            if let speaker = prompt.word(), prompt.skipAttributesUntilQuote(), let text = prompt.stringLiteral() {
                title = title ?? .literal(.string(text))
                _ = speaker
            }
        }
        return [.menu(title: title, items: items)]
    }

    private mutating func parseScene(_ scanner: inout LineScanner, line: LogicalLine) -> [VNStmt] {
        var layer = "master"
        if scanner.keyword("onlayer") {
            layer = scanner.word() ?? layer
        }
        if scanner.remainingIsEmpty { return [.scene(name: nil, layer: layer)] }

        let specifier = imageSpecifier(&scanner)
        layer = specifier.layer
        _ = scanner.keyword("with")
        _ = scanner.upToClause()
        if scanner.match(":") { skipChildBlock(parentIndent: line.indent) }
        return [.scene(name: specifier.name, layer: layer)]
    }

    private mutating func parseShow(_ scanner: inout LineScanner, line: LogicalLine) -> [VNStmt] {
        let specifier = imageSpecifier(&scanner)
        _ = scanner.keyword("with")
        _ = scanner.upToClause()
        if scanner.match(":") { skipChildBlock(parentIndent: line.indent) }
        return [.show(name: specifier.name, expression: specifier.expression, layer: specifier.layer)]
    }

    private mutating func parseHide(_ scanner: inout LineScanner, line: LogicalLine) -> [VNStmt] {
        let specifier = imageSpecifier(&scanner)
        _ = scanner.keyword("with")
        _ = scanner.upToClause()
        return [.hide(name: specifier.name, layer: specifier.layer)]
    }

    /// `image 名字 = 定义`；ATL 块我们不求值
    private mutating func parseImage(_ scanner: inout LineScanner, line: LogicalLine) -> [VNStmt] {
        var components: [VNValue] = []
        while let component = scanner.imageComponent() {
            components.append(.string(component))
        }
        guard !components.isEmpty else { return [.unknown(line: line.text)] }

        if scanner.match(":") {
            skipChildBlock(parentIndent: line.indent)
            return [.image(definition: components, expression: .unsupported("ATL 变换"))]
        }
        guard scanner.match("="), !scanner.remainingIsEmpty else { return [.unknown(line: line.text)] }
        return [.image(definition: components, expression: ExpressionParser.parse(scanner.rest()))]
    }

    private mutating func parseDefine(_ scanner: inout LineScanner, line: LogicalLine, isDefault: Bool) -> [VNStmt] {
        _ = scanner.digits() // `define 0 x = 1` 里的优先级
        guard let name = variableName(&scanner) else { return [.unknown(line: line.text)] }

        let isAppend = scanner.match("+=")
        if !isAppend, scanner.match("|=") { return [.unknown(line: line.text)] }
        if !isAppend, !scanner.match("=") { return [.unknown(line: line.text)] }

        let source = scanner.rest()
        guard !source.isEmpty else { return [.unknown(line: line.text)] }
        var value = ExpressionParser.parse(source)
        if isAppend { value = .binary("+", .variable(name), value) }

        return [isDefault ? .defaultVariable(name: name, value: value) : .define(name: name, value: value)]
    }

    private mutating func parseInlinePython(_ line: LogicalLine) -> [VNStmt] {
        var scanner = LineScanner(line.text)
        _ = scanner.match("$")
        let source = scanner.rest()

        var target = LineScanner(source)
        if let name = variableName(&target) {
            if target.match("=") {
                let value = target.rest()
                guard !value.isEmpty else { return [.unknown(line: line.text)] }
                return [.assign(target: name, value: ExpressionParser.parse(value))]
            }
            if target.match("+=") {
                let value = target.rest()
                guard !value.isEmpty else { return [.unknown(line: line.text)] }
                return [.assign(target: name,
                                value: .binary("+", .variable(name), ExpressionParser.parse(value)))]
            }
        }
        return [.expressionStatement(ExpressionParser.parse(source))]
    }

    private mutating func parsePlay(_ scanner: inout LineScanner, line: LogicalLine) -> [VNStmt] {
        guard let channel = scanner.word() else { return [.unknown(line: line.text)] }
        let file = fileExpression(&scanner)
        var loop = false
        var volume = 1.0
        while !scanner.isAtEnd {
            if scanner.keyword("loop") { loop = true; continue }
            if scanner.keyword("volume") { volume = scanner.doubleValue() ?? volume; continue }
            scanner.skipToken()
        }
        return [.play(channel: channel, file: file, volume: volume, loop: loop)]
    }

    /// 音频文件名：字符串、列表或变量
    private func fileExpression(_ scanner: inout LineScanner) -> VNExpr? {
        if let raw = scanner.stringLiteral() { return .literal(.string(raw)) }
        let source = scanner.upToClause()
        return source.isEmpty ? nil : ExpressionParser.parse(source)
    }

    /// `说话人 图像属性 "文本"`；没有说话人时是叙述
    private func parseSay(_ scanner: inout LineScanner) -> VNStmt? {
        var character: VNExpr? = nil
        var who: String? = nil
        var attributes: [String] = []

        if scanner.peekIsQuote {
            character = nil
        } else if scanner.peekIsBracket {
            guard let inner = scanner.bracketedExpression() else { return nil }
            character = ExpressionParser.parse(inner)
        } else {
            let saved = scanner.index
            guard let name = scanner.word() else { return nil }
            who = name
            character = .variable(name)
            while !scanner.peekIsQuote {
                guard let attribute = scanner.imageComponent() else {
                    scanner.index = saved
                    return nil
                }
                attributes.append(attribute)
            }
        }

        guard let text = scanner.stringLiteral() else { return nil }
        _ = scanner.keyword("nointeract")
        return .say(character: character, who: who, text: .literal(.string(text)), attributes: attributes)
    }

    // MARK: - 名字

    /// `标签.子标签`，或以 `.` 开头表示挂在最近的顶层标签下
    private func labelName(_ scanner: inout LineScanner) -> String? {
        if scanner.match(".") {
            guard let local = scanner.word(), let base = globalLabel else { return nil }
            return base + "." + local
        }
        guard let name = scanner.word() else { return nil }
        let saved = scanner.index
        if scanner.match("."), let local = scanner.word() {
            return name + "." + local
        }
        scanner.index = saved
        return name
    }

    /// `a.b.c` 形式的变量名；省略 `store.` 前缀，按下标赋值不支持
    private func variableName(_ scanner: inout LineScanner) -> String? {
        guard var name = scanner.word() else { return nil }
        while true {
            let saved = scanner.index
            guard scanner.match("."), let part = scanner.word() else {
                scanner.index = saved
                break
            }
            name += "." + part
        }
        if scanner.peekIsBracket { return nil }
        if name.hasPrefix("store.") { name = String(name.dropFirst("store.".count)) }
        return name
    }

    /// `show/scene/hide` 后的图像名，以及 `expression`、`onlayer`、`at` 等子句
    private func imageSpecifier(_ scanner: inout LineScanner) -> (name: String, expression: VNExpr?, layer: String) {
        var layer = "master"
        if scanner.keyword("expression") || scanner.keyword("image") {
            let source = scanner.upToClause()
            return (source, ExpressionParser.parse(source), layer)
        }

        var components: [String] = []
        while let component = scanner.imageComponent() {
            components.append(component)
        }

        while true {
            if scanner.keyword("onlayer") {
                layer = scanner.word() ?? layer
                continue
            }
            if scanner.keyword("at") || scanner.keyword("zorder") || scanner.keyword("behind") {
                _ = scanner.upToClause()
                continue
            }
            if scanner.keyword("as") {
                _ = scanner.word()
                continue
            }
            break
        }
        return (components.joined(separator: " "), nil, layer)
    }
}

/// `show`、`scene`、`play` 等语句里分隔参数的关键字
private let clauseKeywords: Set<String> = [
    "at", "as", "behind", "onlayer", "zorder", "with", "expression", "image",
    "if", "showif", "loop", "nointeract", "volume", "fadein", "fadeout", "to", "from", "id"
]

/// 字符串前缀字母（`r`、`f`、`b`、`u` 的组合）
private let stringPrefixCharacters = Set(["r", "b", "f", "u", "R", "B", "F", "U"])

/// 一条逻辑行内部的扫描器
private struct LineScanner {
    let characters: [Character]
    var index = 0

    init(_ text: String) {
        characters = Array(text)
    }

    var isAtEnd: Bool { index >= characters.count }

    /// 剩下的是不是只有空白（不移动游标）
    var remainingIsEmpty: Bool { significantIndex >= characters.count }

    /// 下一个非空白字符是不是引号（不移动游标）
    var peekIsQuote: Bool {
        let probe = significantIndex
        return probe < characters.count && (characters[probe] == "\"" || characters[probe] == "'")
    }

    /// 下一个非空白字符是不是 `[`（不移动游标）
    var peekIsBracket: Bool {
        let probe = significantIndex
        return probe < characters.count && characters[probe] == "["
    }

    private var significantIndex: Int {
        var probe = index
        while probe < characters.count, characters[probe] == " " || characters[probe] == "\t" {
            probe += 1
        }
        return probe
    }

    mutating func skipSpaces() {
        index = significantIndex
    }

    /// 剩余的全部内容
    mutating func rest() -> String {
        skipSpaces()
        let result = String(characters[index..<characters.count]).trimmingCharacters(in: .whitespaces)
        index = characters.count
        return result
    }

    /// 读一个标识符；不是标识符时不前进
    mutating func word() -> String? {
        skipSpaces()
        let start = index
        guard start < characters.count, isIdentifierStart(characters[start]) else { return nil }
        var end = start
        while end < characters.count, isIdentifierCharacter(characters[end]) { end += 1 }
        let text = String(characters[start..<end])
        // `f"..."`、`r"..."` 的前缀属于字符串，不是关键字
        if end < characters.count, characters[end] == "\"" || characters[end] == "'",
           text.allSatisfy({ stringPrefixCharacters.contains($0) }) {
            return nil
        }
        index = end
        return text
    }

    /// 整词匹配关键字
    mutating func keyword(_ text: String) -> Bool {
        let saved = index
        guard let found = word(), found == text else {
            index = saved
            return false
        }
        return true
    }

    /// 匹配固定前缀（不要求整词）
    mutating func match(_ text: String) -> Bool {
        skipSpaces()
        let target = Array(text)
        guard index + target.count <= characters.count else { return false }
        for offset in 0..<target.count where characters[index + offset] != target[offset] {
            return false
        }
        index += target.count
        return true
    }

    /// 纯数字串（`define 0 x = 1` 的优先级）
    mutating func digits() -> String? {
        skipSpaces()
        var end = index
        while end < characters.count, characters[end].isNumber { end += 1 }
        guard end > index else { return nil }
        let text = String(characters[index..<end])
        index = end
        return text
    }

    mutating func doubleValue() -> Double? {
        skipSpaces()
        var end = index
        var seenDot = false
        while end < characters.count {
            let character = characters[end]
            if character.isNumber { end += 1; continue }
            if character == ".", !seenDot { seenDot = true; end += 1; continue }
            break
        }
        guard end > index, let value = Double(String(characters[index..<end])) else { return nil }
        index = end
        return value
    }

    /// 图像名的一个成分，允许 `@`、`-` 前缀；碰到子句关键字就停下
    mutating func imageComponent() -> String? {
        skipSpaces()
        let saved = index
        var prefix = ""
        if index < characters.count, characters[index] == "@" || characters[index] == "-" {
            prefix = String(characters[index])
            index += 1
        }
        guard let text = word(), !clauseKeywords.contains(text) else {
            index = saved
            return nil
        }
        return prefix + text
    }

    /// 连续跳过图像属性，直到出现字符串
    mutating func skipAttributesUntilQuote() -> Bool {
        while !peekIsQuote {
            let saved = index
            guard imageComponent() != nil else {
                index = saved
                return false
            }
        }
        return true
    }

    /// 读到下一个子句关键字、`:`、`,` 或行尾之前，作为一段表达式原文
    mutating func upToClause() -> String {
        skipSpaces()
        var depth = 0
        var quote: Character? = nil
        var position = index
        var pending = ""

        while position < characters.count {
            let character = characters[position]
            if let delimiter = quote {
                if character == "\\", position + 1 < characters.count { position += 2; continue }
                if character == delimiter { quote = nil }
                pending.append(character)
                position += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                pending.append(character)
                position += 1
                continue
            }
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
            if depth == 0, character == ":" || character == "," { break }
            if depth == 0, character == " ", isClauseWord(at: position) { break }
            pending.append(character)
            position += 1
        }
        index = position
        return pending.trimmingCharacters(in: .whitespaces)
    }

    /// 当前位置之后的那个整词是不是子句关键字
    private func isClauseWord(at position: Int) -> Bool {
        var start = position
        while start < characters.count, characters[start] == " " || characters[start] == "\t" { start += 1 }
        var end = start
        while end < characters.count, isIdentifierCharacter(characters[end]) { end += 1 }
        guard end > start else { return false }
        return clauseKeywords.contains(String(characters[start..<end]))
    }

    /// 读到本行的 `:` 之前，并把 `:` 吃掉
    mutating func expressionUpToColon() -> String {
        skipSpaces()
        var depth = 0
        var quote: Character? = nil
        var position = index
        while position < characters.count {
            let character = characters[position]
            if let delimiter = quote {
                if character == "\\", position + 1 < characters.count { position += 2; continue }
                if character == delimiter { quote = nil }
                position += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                position += 1
                continue
            }
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
            if character == ":", depth == 0 { break }
            position += 1
        }
        let text = String(characters[index..<position]).trimmingCharacters(in: .whitespaces)
        index = position < characters.count ? position + 1 : position
        return text
    }

    /// `(a, b=1)`：返回括号内的原文
    mutating func parenthesizedBody() -> String? {
        skipSpaces()
        guard index < characters.count, characters[index] == "(" else { return nil }
        var depth = 0
        var position = index
        while position < characters.count {
            let character = characters[position]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 {
                    let text = String(characters[(index + 1)..<position])
                    index = position + 1
                    return text
                }
            }
            position += 1
        }
        return nil
    }

    /// `label start(a, b=1)`：只取形参名字
    mutating func parenthesizedNames() -> [String] {
        guard let body = parenthesizedBody() else { return [] }
        var names: [String] = []
        for part in RpyParser.splitTopLevel(body) {
            let pieces = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let name = pieces.first, !name.isEmpty else { continue }
            names.append(name)
        }
        return names
    }

    /// `call foo(1, x=2)`：只取位置参数
    mutating func callArguments() -> [VNExpr] {
        guard let body = parenthesizedBody() else { return [] }
        var arguments: [VNExpr] = []
        for part in RpyParser.splitTopLevel(body) {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.contains("=") else { continue }
            arguments.append(ExpressionParser.parse(text))
        }
        return arguments
    }

    /// `[表达式]`，用于 `[caller] "文本"`
    mutating func bracketedExpression() -> String? {
        skipSpaces()
        guard index < characters.count, characters[index] == "[" else { return nil }
        var depth = 0
        var position = index
        while position < characters.count {
            let character = characters[position]
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 {
                    let text = String(characters[(index + 1)..<position])
                    index = position + 1
                    return text
                }
            }
            position += 1
        }
        return nil
    }

    /// 跳过一个处理不了的碎片，保证调用方的循环一定会前进
    mutating func skipToken() {
        skipSpaces()
        if isAtEnd { return }
        if word() != nil { return }
        if doubleValue() != nil { return }
        index += 1
    }

    /// 读一个字符串字面量，返回按 Ren'Py 规则折叠空白、去转义之后的内容
    mutating func stringLiteral() -> String? {
        skipSpaces()
        let saved = index
        var prefix = ""
        while index < characters.count, stringPrefixCharacters.contains(characters[index]) {
            prefix.append(characters[index])
            index += 1
        }
        guard index < characters.count, characters[index] == "\"" || characters[index] == "'" else {
            index = saved
            return nil
        }
        let delimiter = characters[index]
        let triple = RpyParser.isQuoteRun(characters, from: index, delimiter)
        var position = index + (triple ? 3 : 1)
        var body: [Character] = []

        while position < characters.count {
            let character = characters[position]
            if character == "\\", position + 1 < characters.count {
                body.append(character)
                body.append(characters[position + 1])
                position += 2
                continue
            }
            if character == delimiter {
                if triple {
                    if RpyParser.isQuoteRun(characters, from: position, delimiter) {
                        index = position + 3
                        return RpyParser.dequote(String(body), raw: prefix == "r", triple: true)
                    }
                    body.append(character)
                    position += 1
                    continue
                }
                index = position + 1
                return RpyParser.dequote(String(body), raw: prefix == "r", triple: false)
            }
            body.append(character)
            position += 1
        }
        index = saved
        return nil
    }
}

// MARK: - 字符串内容处理

extension RpyParser {
    /// 按 `renpy/lexer.py` 的 `string()` 规则折叠空白并去转义。
    /// `\{`、`\[`、`\%` 会写成 `{{`、`[[`、`%%`，让文本管线把它们当字面字符。
    static func dequote(_ text: String, raw: Bool, triple: Bool) -> String {
        guard !raw else { return text }
        let characters = Array(text)
        var collapsed = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                index += 2
                switch next {
                case "{": collapsed += "{{"
                case "[": collapsed += "[["
                case "%": collapsed += "%%"
                case "n": collapsed.append("\n")
                case "t": collapsed.append("\t")
                case "u", "U":
                    var digits = ""
                    let limit = next == "u" ? 4 : 8
                    while index < characters.count, digits.count < limit, isHexDigit(characters[index]) {
                        digits.append(characters[index])
                        index += 1
                    }
                    if let value = Int(digits, radix: 16), let scalar = Unicode.Scalar(value) {
                        collapsed.append(Character(scalar))
                    } else {
                        collapsed.append(next)
                    }
                default:
                    collapsed.append(next)
                }
                continue
            }

            if character == " " || character == "\n" || character == "\t" {
                var cursor = index
                var newlines = 0
                while cursor < characters.count,
                      characters[cursor] == " " || characters[cursor] == "\n" || characters[cursor] == "\t" {
                    if characters[cursor] == "\n" { newlines += 1 }
                    cursor += 1
                }
                if triple, newlines > 0 {
                    // 三引号：换行两侧的空格去掉，换行本身保留
                    collapsed += String(repeating: "\n", count: newlines)
                } else {
                    collapsed.append(" ")
                }
                index = cursor
                continue
            }

            collapsed.append(character)
            index += 1
        }
        return collapsed
    }

    static func isHexDigit(_ character: Character) -> Bool {
        character.isNumber || ("a"..."f").contains(character) || ("A"..."F").contains(character)
    }

    /// 按顶层逗号切开（忽略括号与引号内的逗号）
    static func splitTopLevel(_ text: String) -> [String] {
        let characters = Array(text)
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character? = nil

        for character in characters {
            if let delimiter = quote {
                current.append(character)
                if character == delimiter { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                continue
            }
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }
}

private func isIdentifierStart(_ character: Character) -> Bool {
    character.isLetter || character == "_"
}

private func isIdentifierCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
}
