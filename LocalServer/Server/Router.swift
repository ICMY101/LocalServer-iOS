import Foundation

/// 把请求分派到静态文件服务、Live Reload 或网页管理接口
final class Router {
    struct Config: Equatable {
        var directoryListing = true
        var spaFallback = false
        var webAdmin = true
        var cors = false
        var liveReload = true
        var adminPassword = ""
        /// 当前网站相对存储根目录的路径，空字符串表示存储根目录本身
        var siteRoot = ""
    }

    var config: Config
    var onFilesChanged: (() -> Void)?

    /// 存储根目录（www），网页管理在这里操作
    let storageRoot: URL
    private let fileManager = FileManager.default
    private let liveReload = LiveReload()
    private lazy var admin = AdminAPI(root: storageRoot) { [weak self] in
        self?.onFilesChanged?()
    }

    init(rootURL: URL, config: Config) {
        self.storageRoot = rootURL
        self.config = config
    }

    /// 对外提供服务的网站根目录；设置的文件夹不存在时回退到存储根目录
    var siteRootURL: URL {
        guard !config.siteRoot.isEmpty,
              let url = PathResolver.resolve(config.siteRoot, in: storageRoot) else {
            return storageRoot
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return storageRoot
        }
        return url
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let isAdmin = request.path == AdminAPI.prefix || request.path.hasPrefix(AdminAPI.prefix + "/")
        var response: HTTPResponse

        if isAdmin {
            response = config.webAdmin
                ? admin.handle(request, password: config.adminPassword, siteRoot: config.siteRoot)
                : .error(404)
        } else if LiveReload.handles(request.path) {
            response = config.liveReload ? liveReload.handle(request, root: siteRootURL) : .error(404)
        } else if request.method == "OPTIONS" && config.cors {
            response = HTTPResponse(status: 204, headers: [
                ("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS"),
                ("Access-Control-Allow-Headers", request.header("access-control-request-headers") ?? "*"),
                ("Access-Control-Max-Age", "86400"),
            ])
        } else {
            response = serveStatic(request, root: siteRootURL)
        }

        response.setHeader("Server", "LocalServer-iOS")
        // 管理接口不开放跨域，防止其它网站借用户的浏览器修改文件
        if config.cors && !isAdmin {
            response.setHeader("Access-Control-Allow-Origin", "*")
        }
        return response
    }

    // MARK: - 静态文件

    private func serveStatic(_ request: HTTPRequest, root: URL) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return .error(405, headers: [("Allow", "GET, HEAD")])
        }
        guard let url = PathResolver.resolve(request.path, in: root) else {
            return .error(403, "不允许访问该路径")
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                return serveFile(url, for: request)
            }
            if !request.rawPath.hasSuffix("/") {
                let query = request.rawQuery.isEmpty ? "" : "?" + request.rawQuery
                return .redirect(to: request.rawPath + "/" + query)
            }
            for name in ["index.html", "index.htm"] {
                let index = url.appendingPathComponent(name)
                if isRegularFile(index) {
                    return serveFile(index, for: request)
                }
            }
            if config.directoryListing {
                return directoryListing(url, for: request)
            }
            return .error(403, "该目录没有 index.html，且目录列表已关闭")
        }

        if config.spaFallback, request.header("accept")?.contains("text/html") == true {
            let index = root.appendingPathComponent("index.html")
            if isRegularFile(index) {
                return serveFile(index, for: request)
            }
        }
        let notFoundPage = root.appendingPathComponent("404.html")
        if isRegularFile(notFoundPage) {
            return serveFile(notFoundPage, for: request, status: 404)
        }
        return .error(404, request.path)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func serveFile(_ url: URL, for request: HTTPRequest, status: Int = 200) -> HTTPResponse {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return .error(404)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        let contentType = MIMEType.forExtension(url.pathExtension)
        // 开启 Live Reload 时，在 HTML 中插入自动刷新脚本
        let inject = config.liveReload && contentType.hasPrefix("text/html") && size <= LiveReload.maxInjectSize

        let etagCore = "\(String(size, radix: 16))-\(String(Int64(modified.timeIntervalSince1970 * 1000), radix: 16))"
        let etag = "\"\(etagCore)\(inject ? "-lr" : "")\""

        var headers: [(String, String)] = [
            ("Content-Type", contentType),
            ("Last-Modified", HTTPDate.string(from: modified)),
            ("ETag", etag),
            // 每次都向服务器验证，修改文件后刷新即可看到最新内容
            ("Cache-Control", "no-cache"),
            ("Accept-Ranges", inject ? "none" : "bytes"),
        ]

        if status == 200 {
            if let ifNoneMatch = request.header("if-none-match") {
                let tags = ifNoneMatch.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if tags.contains(etag) || tags.contains("*") {
                    return HTTPResponse(status: 304, headers: headers)
                }
            } else if let since = request.header("if-modified-since").flatMap(HTTPDate.date(from:)),
                      modified.timeIntervalSince1970.rounded(.down) <= since.timeIntervalSince1970 {
                return HTTPResponse(status: 304, headers: headers)
            }

            if !inject, let range = request.header("range") {
                switch ByteRange.parse(range, size: size) {
                case .full:
                    break
                case .partial(let offset, let length):
                    headers.append(("Content-Range", "bytes \(offset)-\(offset + length - 1)/\(size)"))
                    return HTTPResponse(status: 206, headers: headers, body: .file(url, offset: offset, length: length))
                case .unsatisfiable:
                    return HTTPResponse(status: 416, headers: [("Content-Range", "bytes */\(size)")])
                }
            }
        }

        if inject {
            guard let data = try? Data(contentsOf: url) else {
                return .error(500, "无法读取文件")
            }
            return HTTPResponse(status: status, headers: headers, body: .data(LiveReload.inject(into: data)))
        }
        return HTTPResponse(status: status, headers: headers, body: .file(url, offset: 0, length: size))
    }

    private func directoryListing(_ directory: URL, for request: HTTPRequest) -> HTTPResponse {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        let entries = contents.map { url -> (name: String, isDirectory: Bool, size: Int, modified: Date?) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url.lastPathComponent, values?.isDirectory ?? false, values?.fileSize ?? 0, values?.contentModificationDate)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let sizeFormatter = ByteCountFormatter()
        sizeFormatter.countStyle = .file

        var rows = ""
        if request.path != "/" {
            rows += "<tr><td><a href=\"../\">📁 ../</a></td><td></td><td></td></tr>"
        }
        for entry in entries {
            let encoded = (entry.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.name)
                + (entry.isDirectory ? "/" : "")
            let icon = entry.isDirectory ? "📁" : "📄"
            let display = entry.name + (entry.isDirectory ? "/" : "")
            let size = entry.isDirectory ? "—" : sizeFormatter.string(fromByteCount: Int64(entry.size))
            let date = entry.modified.map(dateFormatter.string(from:)) ?? ""
            rows += "<tr><td><a href=\"\(encoded.htmlEscaped)\">\(icon) \(display.htmlEscaped)</a></td>"
                + "<td class=\"r\">\(size)</td><td class=\"r\">\(date)</td></tr>"
        }
        if entries.isEmpty {
            rows += "<tr><td colspan=\"3\" class=\"empty\">空文件夹</td></tr>"
        }

        let title = "Index of \(request.path)".htmlEscaped
        return .html("""
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title>
        <style>
        :root{color-scheme:light dark;--fg:#1d1d1f;--muted:#86868b;--line:#e5e5ea;--bg:#fff;--link:#0a66d8}
        @media(prefers-color-scheme:dark){:root{--fg:#f5f5f7;--muted:#98989d;--line:#38383a;--bg:#000;--link:#4ea1ff}}
        body{font-family:-apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;background:var(--bg);color:var(--fg)}
        h1{font-size:20px;font-weight:600;margin:0 0 16px;word-break:break-all}
        table{width:100%;border-collapse:collapse;font-size:15px}
        td{padding:10px 8px;border-bottom:1px solid var(--line)}
        td.r{color:var(--muted);text-align:right;white-space:nowrap;font-size:13px}
        a{color:var(--link);text-decoration:none;word-break:break-all}
        .empty{color:var(--muted);text-align:center}
        @media(max-width:520px){td.r:last-child{display:none}}
        </style></head><body>
        <h1>\(title)</h1>
        <table>\(rows)</table>
        </body></html>
        """)
    }
}

// MARK: - 路径解析

enum PathResolver {
    /// 把 URL 路径映射到根目录下的文件。
    /// 包含 `..` 或以 `.` 开头的隐藏文件（`.well-known` 除外）时返回 nil。
    static func resolve(_ path: String, in root: URL) -> URL? {
        var url = root
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { return nil }
            if component.hasPrefix(".") && component != ".well-known" { return nil }
            if component.contains("\0") { return nil }
            url.appendPathComponent(String(component))
        }
        return url
    }
}

// MARK: - Range 请求

enum ByteRange: Equatable {
    case full
    case partial(offset: UInt64, length: UInt64)
    case unsatisfiable

    /// 只支持单个区间；多区间请求按完整文件返回
    static func parse(_ header: String, size: UInt64) -> ByteRange {
        let header = header.trimmingCharacters(in: .whitespaces)
        guard header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return .full }

        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            // bytes=-500：最后 500 字节
            guard let suffix = UInt64(endText), suffix > 0, size > 0 else { return .unsatisfiable }
            let length = min(suffix, size)
            return .partial(offset: size - length, length: length)
        }

        guard let start = UInt64(startText) else { return .full }
        guard start < size else { return .unsatisfiable }
        var end = size - 1
        if !endText.isEmpty {
            guard let requestedEnd = UInt64(endText), requestedEnd >= start else { return .full }
            end = min(requestedEnd, size - 1)
        }
        return .partial(offset: start, length: end - start + 1)
    }
}
