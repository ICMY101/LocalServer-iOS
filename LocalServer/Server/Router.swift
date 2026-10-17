import Foundation

/// 把请求分派到站点、站点列表、Live Reload 或网页管理接口。
///
/// www 下的每个一级文件夹都是一个独立站点，通过 `/文件夹名/` 访问，并以该文件夹为根：
/// 站点页面里以 `/` 开头的资源路径（例如 `/css/app.css`），会根据来源页（Referer）
/// 或最近访问的站点（Cookie）归属到对应站点，无需修改网页代码。
final class Router {
    struct Config: Equatable {
        var directoryListing = true
        var spaFallback = false
        var webAdmin = true
        var cors = false
        var liveReload = true
        /// 电脑端管理页是否需要先用配对码配对
        var requirePairing = true
    }

    /// 请求最终交给谁处理
    enum Target: Equatable {
        /// 访问 `/`：显示所有已开启的站点
        case portal
        /// 某个站点内的路径（path 以站点为根）
        case site(name: String, path: String)
        /// 站点已关闭
        case disabled(name: String)
        /// www 根目录下不属于任何站点的文件
        case storage(path: String)
    }

    static let siteCookie = "ls_site"

    /// 请求在并发队列上处理，配置可能同时被界面修改，所以读写都加锁
    var config: Config {
        get { lock.lock(); defer { lock.unlock() }; return storedConfig }
        set { lock.lock(); storedConfig = newValue; lock.unlock() }
    }

    /// 文件被网页管理修改后回调
    var onFilesChanged: (() -> Void)?

    /// 存储根目录（www），网页管理在这里操作
    let storageRoot: URL
    let liveReload = LiveReload()
    private let admin: AdminAPI
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var storedConfig: Config

    private static let listingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(rootURL: URL, config: Config, pairing: PairingStore) {
        self.storageRoot = rootURL
        self.storedConfig = config
        self.admin = AdminAPI(root: rootURL, pairing: pairing)
        admin.onChange = { [weak self] in
            self?.liveReload.notifyChanged()
            self?.onFilesChanged?()
        }
    }

    // MARK: - 站点

    /// 站点名不能为空，不能以 . 或 __ 开头（`__admin` 等为保留路径）
    static func isValidSiteName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.hasPrefix("__") && !name.contains("/")
    }

    /// 站点文件夹；不存在或名称无效时返回 nil
    func siteURL(_ name: String) -> URL? {
        guard Self.isValidSiteName(name) else { return nil }
        let url = storageRoot.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// 决定请求由哪个站点处理
    func resolve(_ request: HTTPRequest, config: Config) -> Target {
        let path = request.path
        if path == "/" {
            return .portal
        }
        let segments = path.split(separator: "/").map(String.init)
        let context = contextSite(of: request, config: config)

        // 1. 来源页属于某个站点，且这个站点里确实有该路径：站点内以 / 开头的资源
        if let context, segments.first != context, let root = siteURL(context), exists(path, in: root) {
            return .site(name: context, path: path)
        }
        // 2. 路径以站点名开头：/站点名/...
        if let first = segments.first, let folder = siteURL(first) {
            if SiteMarker.isDisabled(folder) {
                return .disabled(name: first)
            }
            var rest = "/" + segments.dropFirst().joined(separator: "/")
            if path.hasSuffix("/") && segments.count > 1 {
                rest += "/"
            }
            return .site(name: first, path: rest)
        }
        // 3. www 根目录下的散落文件，例如 /favicon.ico
        if let url = PathResolver.resolve(path, in: storageRoot), isRegularFile(url) {
            return .storage(path: path)
        }
        // 4. 来源站点中不存在的路径，交给站点处理（404 页面或 SPA 回退）
        if let context {
            return .site(name: context, path: path)
        }
        return .storage(path: path)
    }

    /// 请求来自哪个站点：优先看来源页（Referer），其次看最近访问的站点（Cookie）
    private func contextSite(of request: HTTPRequest, config: Config) -> String? {
        func enabledSite(_ name: String?) -> String? {
            guard let name, let folder = siteURL(name), !SiteMarker.isDisabled(folder) else { return nil }
            return name
        }
        if let referer = request.header("referer"),
           let url = URL(string: referer),
           let site = enabledSite(url.path.split(separator: "/").first.map(String.init)) {
            return site
        }
        if let value = cookie(Self.siteCookie, in: request)?.removingPercentEncoding,
           let site = enabledSite(value) {
            return site
        }
        return nil
    }

    private func exists(_ path: String, in root: URL) -> Bool {
        guard let url = PathResolver.resolve(path, in: root) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    private func cookie(_ name: String, in request: HTTPRequest) -> String? {
        guard let header = request.header("cookie") else { return nil }
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - 请求入口

    /// 处理请求。大多数请求同步完成；Live Reload 的长轮询会稍后才调用 completion。
    /// 可在任意线程调用，completion 也可能在任意线程被调用。
    func handle(_ request: HTTPRequest, completion: @escaping (HTTPResponse) -> Void) {
        let config = self.config
        let isAdmin = request.path == AdminAPI.prefix || request.path.hasPrefix(AdminAPI.prefix + "/")
        let finish: (HTTPResponse) -> Void = { response in
            var response = response
            response.setHeader("Server", "LocalServer-iOS")
            // 管理接口不开放跨域，防止其它网站借用户的浏览器修改文件
            if config.cors && !isAdmin {
                response.setHeader("Access-Control-Allow-Origin", "*")
            }
            completion(response)
        }

        if isAdmin {
            finish(config.webAdmin
                ? admin.handle(request, requirePairing: config.requirePairing)
                : .error(404))
            return
        }
        if LiveReload.handles(request.path) {
            guard config.liveReload else {
                finish(.error(404))
                return
            }
            // 由页面所属的站点决定监视哪个目录
            let root = contextSite(of: request, config: config).flatMap { siteURL($0) } ?? storageRoot
            liveReload.handle(request, root: root, completion: finish)
            return
        }
        if request.method == "OPTIONS" && config.cors {
            finish(HTTPResponse(status: 204, headers: [
                ("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS"),
                ("Access-Control-Allow-Headers", request.header("access-control-request-headers") ?? "*"),
                ("Access-Control-Max-Age", "86400"),
            ]))
            return
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            finish(.error(405, headers: [("Allow", "GET, HEAD")]))
            return
        }

        switch resolve(request, config: config) {
        case .portal:
            finish(portal(config: config))
        case .disabled(let name):
            var response = HTTPResponse.page(
                status: 403,
                title: "站点未开启",
                message: "「\(name)」已在 App 中关闭。在「本地服务器」中开启后即可访问。"
            )
            response.site = name
            finish(response)
        case .site(let name, let path):
            guard let root = siteURL(name) else {
                finish(.error(404))
                return
            }
            var response = serveStatic(request, path: path, root: root, config: config)
            response.site = name
            // 记住最近访问的站点，供没有来源信息的 / 开头请求使用
            if response.status == 200, response.header("Content-Type")?.hasPrefix("text/html") == true {
                let value = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
                response.setHeader("Set-Cookie", "\(Self.siteCookie)=\(value); Path=/; SameSite=Lax")
            }
            finish(response)
        case .storage(let path):
            finish(serveStatic(request, path: path, root: storageRoot, config: config))
        }
    }

    // MARK: - 站点列表

    private func portal(config: Config) -> HTTPResponse {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let folders = ((try? fileManager.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            return values?.isDirectory == true && Self.isValidSiteName(name) && !SiteMarker.isDisabled(url)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let cards = folders.map { url -> String in
            let name = url.lastPathComponent
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let date = modified.map { Self.listingDateFormatter.string(from: $0) } ?? ""
            let hasIndex = isRegularFile(url.appendingPathComponent("index.html"))
                || isRegularFile(url.appendingPathComponent("index.htm"))
            return """
            <a class="site card" href="/\(encoded.htmlEscaped)/">
              <span class="kind">\(hasIndex ? "网站" : "文件夹")</span>
              <span class="name">\(name.htmlEscaped)</span>
              <span class="path">/\(name.htmlEscaped)/</span>
              <span class="meta">更新于 \(date)</span>
              <span class="go">访问 ›</span>
            </a>
            """
        }.joined()

        let content: String
        if folders.isEmpty {
            content = """
            <div class="empty card"><h2>还没有开启的站点</h2>
            <p>在「本地服务器」App 的 www 文件夹中，每个文件夹都是一个独立站点，可以通过 /文件夹名/ 访问。</p></div>
            """
        } else {
            content = "<div class=\"sites\">\(cards)</div>"
        }
        let adminLink = config.webAdmin ? "<a href=\"/__admin/\">在电脑上管理文件</a> · " : ""
        let body = """
        <main>
          <p class="eyebrow">本地服务器</p>
          <h1>站点</h1>
          <p class="lead">\(folders.count) 个站点正在运行。每个站点都以自己的文件夹为根目录。</p>
          \(content)
          <p class="foot">\(adminLink)由 iPhone 上的「本地服务器」提供</p>
        </main>
        """
        let css = """
        .sites{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:20px}
        .site{display:flex;flex-direction:column;padding:30px 28px 26px;color:var(--fg);min-height:210px;transition:transform .25s ease,box-shadow .25s ease}
        .site:hover{text-decoration:none;transform:scale(1.015);box-shadow:0 4px 24px rgba(0,0,0,.08)}
        .site .kind{font-size:13px;font-weight:600;color:var(--muted)}
        .site .name{font-size:28px;font-weight:700;letter-spacing:-.02em;margin-top:6px;word-break:break-all}
        .site .path{font-size:15px;color:var(--muted);margin-top:4px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
        .site .meta{font-size:13px;color:var(--muted);margin-top:auto;padding-top:22px}
        .site .go{font-size:17px;color:var(--accent);margin-top:6px}
        .empty{padding:40px 32px}
        .empty h2{margin:0 0 8px;font-size:24px}
        .empty p{margin:0;color:var(--muted)}
        """
        var response = HTTPResponse.html(WebStyle.page(title: "站点 · 本地服务器", body: body, extraCSS: css))
        response.setHeader("Cache-Control", "no-store")
        return response
    }

    // MARK: - 静态文件

    /// path 是相对 root 的路径；目录重定向使用原始请求路径，保证浏览器地址正确
    private func serveStatic(_ request: HTTPRequest, path: String, root: URL, config: Config) -> HTTPResponse {
        guard let url = PathResolver.resolve(path, in: root) else {
            return .error(403, "不允许访问该路径")
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                return serveFile(url, for: request, injectLiveReload: config.liveReload)
            }
            if !request.rawPath.hasSuffix("/") {
                let query = request.rawQuery.isEmpty ? "" : "?" + request.rawQuery
                return .redirect(to: request.rawPath + "/" + query)
            }
            for name in ["index.html", "index.htm"] {
                let index = url.appendingPathComponent(name)
                if isRegularFile(index) {
                    return serveFile(index, for: request, injectLiveReload: config.liveReload)
                }
            }
            if config.directoryListing {
                return directoryListing(url, for: request)
            }
            return .error(403, "该文件夹中没有 index.html，且目录列表已关闭。")
        }

        if config.spaFallback, request.header("accept")?.contains("text/html") == true {
            let index = root.appendingPathComponent("index.html")
            if isRegularFile(index) {
                return serveFile(index, for: request, injectLiveReload: config.liveReload)
            }
        }
        let notFoundPage = root.appendingPathComponent("404.html")
        if isRegularFile(notFoundPage) {
            return serveFile(notFoundPage, for: request, status: 404, injectLiveReload: config.liveReload)
        }
        return .error(404, "没有找到 \(request.path)")
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func serveFile(_ url: URL, for request: HTTPRequest, status: Int = 200, injectLiveReload: Bool) -> HTTPResponse {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return .error(404)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        let contentType = MIMEType.forExtension(url.pathExtension)
        // 开启 Live Reload 时，在 HTML 中插入自动刷新脚本
        let inject = injectLiveReload && contentType.hasPrefix("text/html") && size <= LiveReload.maxInjectSize

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

        var rows = "<a class=\"row\" href=\"../\"><span class=\"n\">上一级</span><span></span><span></span></a>"
        for entry in entries {
            let encoded = (entry.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.name)
                + (entry.isDirectory ? "/" : "")
            let display = entry.name + (entry.isDirectory ? "/" : "")
            let size = entry.isDirectory ? "" : Self.sizeFormatter.string(fromByteCount: Int64(entry.size))
            let date = entry.modified.map { Self.listingDateFormatter.string(from: $0) } ?? ""
            rows += "<a class=\"row\" href=\"\(encoded.htmlEscaped)\"><span class=\"n\">\(display.htmlEscaped)</span>"
                + "<span class=\"m\">\(size)</span><span class=\"m d\">\(date)</span></a>"
        }
        if entries.isEmpty {
            rows += "<div class=\"row empty\">空文件夹</div>"
        }

        let body = """
        <main>
          <p class="eyebrow">目录</p>
          <h1 class="path">\(request.path.htmlEscaped)</h1>
          <div class="list card">\(rows)</div>
          <p class="foot"><a href="/">所有站点</a></p>
        </main>
        """
        let css = """
        h1.path{font-size:34px;word-break:break-all}
        .list{padding:6px 0;margin-top:28px}
        .row{display:grid;grid-template-columns:1fr 90px 140px;gap:12px;padding:13px 24px;color:var(--fg);border-top:1px solid var(--line);font-size:17px}
        .row:first-child{border-top:0}
        .row:hover{text-decoration:none;background:var(--bg)}
        .row .n{word-break:break-all;color:var(--accent)}
        .row .m{color:var(--muted);font-size:14px;text-align:right;align-self:center}
        .empty{color:var(--muted)}
        @media(max-width:600px){.row{grid-template-columns:1fr 80px}.row .d{display:none}}
        """
        return .html(WebStyle.page(title: request.path, body: body, extraCSS: css))
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
