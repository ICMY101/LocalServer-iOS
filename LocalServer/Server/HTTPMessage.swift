import Foundation

// MARK: - 请求

/// 解析后的请求头部分（请求行 + 头字段）
struct HTTPRequestHead {
    let method: String
    let target: String
    let version: String
    /// 头字段名统一为小写
    let headers: [String: String]

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        var lines = text.components(separatedBy: "\r\n")
        // RFC 7230：请求行之前的空行应被忽略
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        guard !lines.isEmpty else { return nil }

        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        method = parts[0].uppercased()
        target = String(parts[1])
        version = parts[2].uppercased()
        guard version.hasPrefix("HTTP/1.") else { return nil }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        self.headers = headers
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var wantsKeepAlive: Bool {
        let connection = header("connection")?.lowercased() ?? ""
        if version == "HTTP/1.0" {
            return connection.contains("keep-alive")
        }
        return !connection.contains("close")
    }
}

enum HTTPBody {
    case none
    case data(Data)
    /// 较大的请求体会被写入临时文件
    case file(URL)
}

struct HTTPRequest {
    let head: HTTPRequestHead
    var body: HTTPBody
    let remoteAddress: String

    /// 未解码的路径部分，例如 `/my%20site/`
    let rawPath: String
    /// 百分号解码后的路径，例如 `/my site/`
    let path: String
    let rawQuery: String
    let query: [String: String]

    var method: String { head.method }

    init(head: HTTPRequestHead, body: HTTPBody, remoteAddress: String) {
        self.head = head
        self.body = body
        self.remoteAddress = remoteAddress

        var target = head.target
        // absolute-form：GET http://host/path HTTP/1.1
        if target.lowercased().hasPrefix("http://") || target.lowercased().hasPrefix("https://"),
           let url = URL(string: target) {
            let path = url.path.isEmpty ? "/" : url.path
            target = url.query.map { path + "?" + $0 } ?? path
        }

        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        rawPath = parts.first.map { String($0) } ?? "/"
        rawQuery = parts.count > 1 ? String(parts[1]) : ""
        path = rawPath.removingPercentEncoding ?? rawPath

        var query: [String: String] = [:]
        for pair in rawQuery.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            query[key] = value
        }
        self.query = query
    }

    func header(_ name: String) -> String? {
        head.header(name)
    }
}

// MARK: - 响应

struct HTTPResponse {
    enum Body {
        case empty
        case data(Data)
        case file(URL, offset: UInt64, length: UInt64)
    }

    var status: Int
    var headers: [(String, String)]
    var body: Body
    /// 响应所属的站点（仅用于统计，不会发送给浏览器）
    var site: String?

    init(status: Int, headers: [(String, String)] = [], body: Body = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    var contentLength: UInt64 {
        switch body {
        case .empty: return 0
        case .data(let data): return UInt64(data.count)
        case .file(_, _, let length): return length
        }
    }

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    mutating func setHeader(_ name: String, _ value: String) {
        headers.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
        headers.append((name, value))
    }

    func serializedHead() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPStatus.reason(for: status))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }

    /// 1xx / 204 / 304 不允许携带消息体
    var allowsBody: Bool {
        !(status < 200 || status == 204 || status == 304)
    }

    // MARK: 便捷构造

    static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", contentType)], body: .data(Data(text.utf8)))
    }

    static func html(_ html: String, status: Int = 200) -> HTTPResponse {
        text(html, status: status, contentType: "text/html; charset=utf-8")
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json; charset=utf-8"), ("Cache-Control", "no-store")],
            body: .data(data)
        )
    }

    static func error(_ status: Int, _ message: String? = nil, headers: [(String, String)] = []) -> HTTPResponse {
        let title: String
        switch status {
        case 403: title = "无法访问"
        case 404: title = "找不到页面"
        case 405: title = "不支持的请求方式"
        default: title = HTTPStatus.reason(for: status)
        }
        var response = page(status: status, title: title, message: message ?? "")
        for (name, value) in headers {
            response.setHeader(name, value)
        }
        return response
    }

    /// 简洁的说明页面，用于错误、站点未开启等情况
    static func page(status: Int, title: String, message: String, actionTitle: String = "查看所有站点", actionURL: String = "/") -> HTTPResponse {
        let body = """
        <main style="text-align:center;padding-top:18vh">
        <p class="eyebrow">\(status)</p>
        <h1>\(title.htmlEscaped)</h1>
        <p class="lead" style="margin:0 auto 36px">\(message.htmlEscaped)</p>
        <a class="pill" href="\(actionURL.htmlEscaped)">\(actionTitle.htmlEscaped)</a>
        </main>
        """
        return html(WebStyle.page(title: "\(status) \(title)", body: body), status: status)
    }

    static func redirect(to location: String, permanent: Bool = true) -> HTTPResponse {
        HTTPResponse(status: permanent ? 301 : 302, headers: [("Location", location)])
    }
}

enum HTTPStatus {
    static func reason(for code: Int) -> String {
        switch code {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 428: return "Precondition Required"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 507: return "Insufficient Storage"
        default: return "Unknown"
        }
    }
}

enum HTTPDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

extension String {
    var htmlEscaped: String {
        var result = ""
        result.reserveCapacity(count)
        for character in self {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
