import Foundation

/// `/__admin` 网页管理：在电脑浏览器里上传、删除、整理网站文件
final class AdminAPI {
    static let prefix = "/__admin"
    /// 修改类接口必须带这个请求头。跨站请求带自定义头会触发 CORS 预检，
    /// 而管理接口从不放行预检，因此其它网站无法借浏览器篡改文件。
    static let guardHeader = "x-localserver"

    private let root: URL
    private let fileManager = FileManager.default
    private let onChange: () -> Void

    init(root: URL, onChange: @escaping () -> Void) {
        self.root = root
        self.onChange = onChange
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let route = String(request.path.dropFirst(Self.prefix.count))

        switch (request.method, route) {
        case ("GET", ""), ("HEAD", ""):
            return .redirect(to: Self.prefix + "/")
        case ("GET", "/"), ("HEAD", "/"):
            var response = HTTPResponse.html(AdminPage.html)
            response.setHeader("Cache-Control", "no-store")
            return response
        case ("GET", "/api/list"):
            return list(request)
        default:
            break
        }

        guard request.header(Self.guardHeader) == "1" else {
            return .json(["error": "缺少请求头 X-LocalServer"], status: 428)
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
        default:
            return .json(["error": "未知接口"], status: 404)
        }
        if response.status < 300 {
            onChange()
        }
        return response
    }

    // MARK: - 接口

    private func list(_ request: HTTPRequest) -> HTTPResponse {
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
        let result: [String: Any] = ["path": request.query["path"] ?? "/", "items": items]
        return .json(result)
    }

    private func upload(_ request: HTTPRequest) -> HTTPResponse {
        guard let destination = target(request.query["path"]), !isRoot(destination) else {
            return failure("路径无效")
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return failure("已存在同名文件夹", status: 409)
            }
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
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
