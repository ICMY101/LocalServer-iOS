import Foundation

/// `/__admin` 网页管理：在电脑浏览器里上传、删除、整理网站文件
final class AdminAPI {
    static let prefix = "/__admin"
    /// 修改类接口必须带这个请求头。跨站请求带自定义头会触发 CORS 预检，
    /// 而管理接口从不放行预检，因此其它网站无法借浏览器篡改文件。
    static let guardHeader = "x-localserver"
    static let sessionCookie = "ls_session"

    private static let maxFailures = 5
    private static let lockDuration: TimeInterval = 60
    private static let maxSessions = 64

    private let root: URL
    private let fileManager = FileManager.default
    private let onChange: () -> Void

    /// 登录后的会话令牌，只保存在内存中，服务器重启或修改密码后失效
    private var sessions: Set<String> = []
    private var sessionPassword = ""
    private var failures: [String: (count: Int, lockedUntil: Date)] = [:]

    init(root: URL, onChange: @escaping () -> Void) {
        self.root = root
        self.onChange = onChange
    }

    func handle(_ request: HTTPRequest, password: String, siteRoot: String) -> HTTPResponse {
        if password != sessionPassword {
            sessions.removeAll()
            sessionPassword = password
        }
        let route = String(request.path.dropFirst(Self.prefix.count))
        let authorized = password.isEmpty || (session(of: request).map { sessions.contains($0) } ?? false)

        switch (request.method, route) {
        case ("GET", ""), ("HEAD", ""):
            return .redirect(to: Self.prefix + "/")
        case ("GET", "/"), ("HEAD", "/"):
            var response = HTTPResponse.html(authorized ? AdminPage.html : AdminPage.loginHTML)
            response.setHeader("Cache-Control", "no-store")
            return response
        default:
            break
        }

        if route == "/api/login" {
            guard request.method == "POST", request.header(Self.guardHeader) == "1" else {
                return failure("请求无效", status: 400)
            }
            return login(request, password: password)
        }

        guard authorized else {
            let body: [String: Any] = ["error": "请先输入访问密码", "login": true]
            return .json(body, status: 401)
        }

        if request.method == "GET" && route == "/api/list" {
            return list(request, siteRoot: siteRoot)
        }

        guard request.header(Self.guardHeader) == "1" else {
            return failure("缺少请求头 X-LocalServer", status: 428)
        }

        let response: HTTPResponse
        switch (request.method, route) {
        case ("PUT", "/api/file"):
            response = upload(request)
        case ("POST", "/api/mkdir"):
            response = mkdir(request)
        case ("POST", "/api/delete"):
            response = delete(request)
        case ("POST", "/api/move"):
            response = move(request)
        case ("POST", "/api/logout"):
            return logout(request)
        default:
            return failure("未知接口", status: 404)
        }
        if response.status < 300 {
            onChange()
        }
        return response
    }

    // MARK: - 登录

    private func login(_ request: HTTPRequest, password: String) -> HTTPResponse {
        let client = request.remoteAddress
        let now = Date()
        if let record = failures[client], record.lockedUntil > now {
            let seconds = Int(record.lockedUntil.timeIntervalSince(now).rounded(.up))
            return failure("尝试次数过多，请 \(seconds) 秒后再试", status: 429)
        }

        let supplied: String
        switch request.body {
        case .data(let data):
            supplied = String(data: data, encoding: .utf8) ?? ""
        default:
            supplied = ""
        }

        guard password.isEmpty || Self.constantTimeEquals(supplied, password) else {
            var record = failures[client] ?? (count: 0, lockedUntil: Date.distantPast)
            record.count += 1
            if record.count >= Self.maxFailures {
                record = (count: 0, lockedUntil: now.addingTimeInterval(Self.lockDuration))
            }
            failures[client] = record
            return failure("密码错误", status: 403)
        }

        failures[client] = nil
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        if sessions.count >= Self.maxSessions, let oldest = sessions.first {
            sessions.remove(oldest)
        }
        sessions.insert(token)

        var response = HTTPResponse.json(["ok": true])
        response.setHeader(
            "Set-Cookie",
            "\(Self.sessionCookie)=\(token); Path=\(Self.prefix); Max-Age=2592000; HttpOnly; SameSite=Strict"
        )
        return response
    }

    private func logout(_ request: HTTPRequest) -> HTTPResponse {
        if let token = session(of: request) {
            sessions.remove(token)
        }
        var response = HTTPResponse.json(["ok": true])
        response.setHeader("Set-Cookie", "\(Self.sessionCookie)=; Path=\(Self.prefix); Max-Age=0; HttpOnly; SameSite=Strict")
        return response
    }

    private func session(of request: HTTPRequest) -> String? {
        guard let cookie = request.header("cookie") else { return nil }
        for pair in cookie.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == Self.sessionCookie {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 比较耗时与内容无关，避免通过响应时间逐位猜测密码
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices {
            difference |= x[index] ^ y[index]
        }
        return difference == 0
    }

    // MARK: - 文件接口

    private func list(_ request: HTTPRequest, siteRoot: String) -> HTTPResponse {
        guard let directory = target(request.query["path"]) else {
            return failure("路径无效")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return failure("文件夹不存在", status: 404)
        }

        let items: [[String: Any]] = contents.map { url -> [String: Any] in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return [
                "name": url.lastPathComponent,
                "dir": values?.isDirectory ?? false,
                "size": values?.fileSize ?? 0,
                "mtime": (values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000,
            ]
        }
        .sorted { a, b in
            let aDir = a["dir"] as? Bool ?? false
            let bDir = b["dir"] as? Bool ?? false
            if aDir != bDir { return aDir }
            return (a["name"] as? String ?? "").localizedStandardCompare(b["name"] as? String ?? "") == .orderedAscending
        }
        let result: [String: Any] = [
            "path": request.query["path"] ?? "/",
            "siteRoot": siteRoot.isEmpty ? "/" : "/" + siteRoot,
            "protected": !sessionPassword.isEmpty,
            "items": items,
        ]
        return .json(result)
    }

    private func upload(_ request: HTTPRequest) -> HTTPResponse {
        guard let destination = target(request.query["path"]), !isRoot(destination) else {
            return failure("路径无效")
        }
        let parent = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            return failure("无法创建文件夹：\(error.localizedDescription)", status: 500)
        }

        if request.query["extract"] == "1" && destination.pathExtension.lowercased() == "zip" {
            return extract(request.body, into: parent)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return failure("已存在同名文件夹", status: 409)
            }
            try? fileManager.removeItem(at: destination)
        }
        do {
            switch request.body {
            case .none:
                try Data().write(to: destination)
            case .data(let data):
                try data.write(to: destination, options: .atomic)
            case .file(let temporary):
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            return failure("保存失败：\(error.localizedDescription)", status: 500)
        }
        return .json(["ok": true], status: 201)
    }

    private func extract(_ body: HTTPBody, into directory: URL) -> HTTPResponse {
        let zipURL: URL
        var temporary: URL?
        switch body {
        case .none:
            return failure("zip 文件为空")
        case .file(let url):
            zipURL = url
        case .data(let data):
            let url = fileManager.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).zip")
            do {
                try data.write(to: url)
            } catch {
                return failure("保存失败：\(error.localizedDescription)", status: 500)
            }
            zipURL = url
            temporary = url
        }
        defer {
            if let temporary { try? fileManager.removeItem(at: temporary) }
        }
        do {
            let result = try ZipExtractor.extract(zipURL, into: directory)
            let body: [String: Any] = ["ok": true, "extracted": result.files, "skipped": result.skipped]
            return .json(body, status: 201)
        } catch {
            return failure("解压失败：\(error.localizedDescription)", status: 422)
        }
    }

    private func mkdir(_ request: HTTPRequest) -> HTTPResponse {
        guard let directory = target(request.query["path"]), !isRoot(directory) else {
            return failure("路径无效")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return failure("创建失败：\(error.localizedDescription)", status: 500)
        }
        return .json(["ok": true])
    }

    private func delete(_ request: HTTPRequest) -> HTTPResponse {
        guard let item = target(request.query["path"]), !isRoot(item) else {
            return failure("不能删除根目录")
        }
        guard fileManager.fileExists(atPath: item.path) else {
            return failure("文件不存在", status: 404)
        }
        do {
            try fileManager.removeItem(at: item)
        } catch {
            return failure("删除失败：\(error.localizedDescription)", status: 500)
        }
        return .json(["ok": true])
    }

    private func move(_ request: HTTPRequest) -> HTTPResponse {
        guard let source = target(request.query["from"]), !isRoot(source),
              let destination = target(request.query["to"]), !isRoot(destination) else {
            return failure("路径无效")
        }
        guard fileManager.fileExists(atPath: source.path) else {
            return failure("文件不存在", status: 404)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            return failure("目标已存在", status: 409)
        }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            return failure("移动失败：\(error.localizedDescription)", status: 500)
        }
        return .json(["ok": true])
    }

    // MARK: - 工具

    private func target(_ path: String?) -> URL? {
        PathResolver.resolve(path ?? "/", in: root)
    }

    private func isRoot(_ url: URL) -> Bool {
        url.standardizedFileURL.path == root.standardizedFileURL.path
    }

    private func failure(_ message: String, status: Int = 400) -> HTTPResponse {
        .json(["error": message], status: status)
    }
}
