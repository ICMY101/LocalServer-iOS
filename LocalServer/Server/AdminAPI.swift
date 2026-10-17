import Foundation

/// `/__admin` 网页管理：在电脑浏览器里上传、下载、删除、整理网站文件。
/// 未配对的浏览器只能看到配对页，输入手机上显示的配对码后才能进入。
final class AdminAPI {
    static let prefix = "/__admin"
    /// 修改类接口必须带这个请求头。跨站请求带自定义头会触发 CORS 预检，
    /// 而管理接口从不放行预检，因此其它网站无法借浏览器篡改文件。
    static let guardHeader = "x-localserver"
    static let sessionCookie = "ls_session"

    private let root: URL
    private let pairing: PairingStore
    private let fileManager = FileManager.default
    /// 文件被修改后回调（在请求处理线程上调用）
    var onChange: (() -> Void)?

    init(root: URL, pairing: PairingStore) {
        self.root = root
        self.pairing = pairing
    }

    func handle(_ request: HTTPRequest, requirePairing: Bool) -> HTTPResponse {
        let route = String(request.path.dropFirst(Self.prefix.count))
        let token = session(of: request)
        let authorized = !requirePairing || pairing.isPaired(token: token, address: request.remoteAddress)

        switch (request.method, route) {
        case ("GET", ""), ("HEAD", ""):
            return .redirect(to: Self.prefix + "/")
        case ("GET", "/"), ("HEAD", "/"):
            var response = HTTPResponse.html(authorized ? AdminPage.html : AdminPage.pairingHTML)
            response.setHeader("Cache-Control", "no-store")
            return response
        default:
            break
        }

        // 配对相关接口不需要已配对
        if route == "/api/pair-request" || route == "/api/pair" {
            guard request.method == "POST", request.header(Self.guardHeader) == "1" else {
                return failure("请求无效", status: 400)
            }
            if !requirePairing || authorized {
                return .json(["ok": true, "paired": true])
            }
            return route == "/api/pair" ? pair(request) : requestPairing(request)
        }

        guard authorized else {
            let body: [String: Any] = ["error": "此浏览器尚未与手机配对", "pair": true]
            return .json(body, status: 401)
        }

        switch (request.method, route) {
        case ("GET", "/api/list"):
            return list(request, requirePairing: requirePairing)
        case ("GET", "/api/download"), ("HEAD", "/api/download"):
            return download(request)
        case ("GET", "/api/zip"):
            return zipDownload(request)
        default:
            break
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
            response = transfer(request, copy: false)
        case ("POST", "/api/copy"):
            response = transfer(request, copy: true)
        case ("POST", "/api/site"):
            response = setSite(request)
        case ("POST", "/api/unpair"):
            return unpair(token: token)
        default:
            return failure("未知接口", status: 404)
        }
        if response.status < 300 {
            onChange?()
        }
        return response
    }

    // MARK: - 配对

    private func requestPairing(_ request: HTTPRequest) -> HTTPResponse {
        pairing.requestPairing(address: request.remoteAddress, userAgent: request.header("user-agent"))
        let body: [String: Any] = ["ok": true, "length": PairingStore.pinLength]
        return .json(body)
    }

    private func pair(_ request: HTTPRequest) -> HTTPResponse {
        let supplied: String
        if case .data(let data) = request.body {
            supplied = String(data: data, encoding: .utf8) ?? ""
        } else {
            supplied = ""
        }
        switch pairing.pair(pin: supplied, address: request.remoteAddress, userAgent: request.header("user-agent")) {
        case .success(let token):
            var response = HTTPResponse.json(["ok": true])
            // 配对长期有效（一年），可在手机上随时取消
            response.setHeader(
                "Set-Cookie",
                "\(Self.sessionCookie)=\(token); Path=\(Self.prefix); Max-Age=31536000; HttpOnly; SameSite=Strict"
            )
            return response
        case .failure(.wrongPIN(let remaining)):
            let body: [String: Any] = ["error": "配对码不正确，还可以再试 \(remaining) 次", "remaining": remaining]
            return .json(body, status: 403)
        case .failure(.locked(let seconds)):
            let body: [String: Any] = ["error": "尝试次数过多，请 \(seconds) 秒后再试", "retryAfter": seconds]
            return .json(body, status: 429)
        case .failure(.expired):
            return failure("配对码已过期，请查看手机上的新配对码", status: 410)
        }
    }

    private func unpair(token: String?) -> HTTPResponse {
        if let token {
            pairing.revoke(token: token)
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

    // MARK: - 下载

    private func download(_ request: HTTPRequest) -> HTTPResponse {
        guard let file = target(request.query["path"]), !isRoot(file) else {
            return failure("路径无效")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: file.path) else {
            return failure("文件不存在", status: 404)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let name = file.lastPathComponent
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "download"
        return HTTPResponse(status: 200, headers: [
            ("Content-Type", "application/octet-stream"),
            ("Content-Disposition", "attachment; filename*=UTF-8''\(encoded)"),
            ("Cache-Control", "no-store"),
        ], body: .file(file, offset: 0, length: size))
    }

    // MARK: - 文件接口

    private func list(_ request: HTTPRequest, requirePairing: Bool) -> HTTPResponse {
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
            "disabledSites": SiteMarker.disabledSites(in: root),
            "paired": requirePairing,
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
            return extract(request.body, into: parent, folderName: destination.lastPathComponent)
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

    private func extract(_ body: HTTPBody, into directory: URL, folderName: String) -> HTTPResponse {
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
            let (result, folder) = try ZipExtractor.extractToFolder(zipURL, in: directory, folderName: folderName)
            let body: [String: Any] = [
                "ok": true,
                "extracted": result.files,
                "skipped": result.skipped,
                "folder": folder.lastPathComponent,
            ]
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

    /// 复制或移动：from、to 都是完整路径。
    /// 目标已存在时返回 409；带 conflict=overwrite 覆盖，conflict=keep 保留两者（自动改名）
    private func transfer(_ request: HTTPRequest, copy: Bool) -> HTTPResponse {
        guard let source = target(request.query["from"]), !isRoot(source),
              let destination = target(request.query["to"]), !isRoot(destination) else {
            return failure("路径无效")
        }
        let policy: FileStore.ConflictPolicy
        switch request.query["conflict"] {
        case "overwrite": policy = .overwrite
        case "keep": policy = .keepBoth
        default: policy = .fail
        }
        do {
            let result = try FileStore.transfer(source, to: destination, copy: copy, policy: policy)
            let body: [String: Any] = ["ok": true, "name": result.lastPathComponent]
            return .json(body)
        } catch let error as FileStore.TransferError {
            switch error {
            case .exists(let name):
                let body: [String: Any] = ["error": error.localizedDescription, "conflict": true, "name": name]
                return .json(body, status: 409)
            case .notFound:
                return failure(error.localizedDescription, status: 404)
            case .intoItself, .root:
                return failure(error.localizedDescription)
            }
        } catch {
            return failure("\(copy ? "复制" : "移动")失败：\(error.localizedDescription)", status: 500)
        }
    }

    /// 开启或关闭站点：name 为 www 下的文件夹名，enabled 为 1 或 0
    private func setSite(_ request: HTTPRequest) -> HTTPResponse {
        guard let name = request.query["name"], Router.isValidSiteName(name),
              let folder = target("/" + name) else {
            return failure("站点名称无效")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return failure("站点不存在", status: 404)
        }
        let enabled = request.query["enabled"] != "0"
        do {
            try SiteMarker.setEnabled(enabled, for: folder)
        } catch {
            return failure("操作失败：\(error.localizedDescription)", status: 500)
        }
        let body: [String: Any] = ["ok": true, "enabled": enabled]
        return .json(body)
    }

    /// 把一个或多个项目打包成 zip 下载。paths 为 JSON 数组，例如 ["/blog","/a.html"]
    private func zipDownload(_ request: HTTPRequest) -> HTTPResponse {
        guard let raw = request.query["paths"],
              let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String],
              !list.isEmpty else {
            return failure("请选择要下载的项目")
        }
        var urls: [URL] = []
        for path in list {
            guard let url = target(path), !isRoot(url), fileManager.fileExists(atPath: url.path) else {
                return failure("「\(path)」不存在", status: 404)
            }
            urls.append(url)
        }
        let staging = fileManager.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        let zipURL: URL
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            zipURL = try FileStore.compress(urls, into: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            return failure("打包失败：\(error.localizedDescription)", status: 500)
        }
        let size = ((try? fileManager.attributesOfItem(atPath: zipURL.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        let encoded = zipURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "download.zip"
        var response = HTTPResponse(status: 200, headers: [
            ("Content-Type", "application/zip"),
            ("Content-Disposition", "attachment; filename*=UTF-8''\(encoded)"),
            ("Cache-Control", "no-store"),
        ], body: .file(zipURL, offset: 0, length: size))
        // 发送完成后删除临时文件
        response.cleanupURL = staging
        return response
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
