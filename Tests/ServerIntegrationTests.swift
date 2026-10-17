import XCTest
@testable import LocalServer

/// 在随机端口上启动真实的 HTTPServer，用 URLSession 发请求，覆盖 HTTPConnection 的完整收发流程
final class ServerIntegrationTests: XCTestCase {
    private var site: TemporaryDirectory!
    private var server: HTTPServer?
    private var port: UInt16 = 0
    private var session: URLSession!

    override func setUp() async throws {
        site = try TemporaryDirectory()
        try site.write("index.html", "<html><body>Home</body></html>")
        try site.write("data.txt", "0123456789")
        try site.write("docs/readme.txt", "docs")
        try site.write("site2/index.html", "<p>site2</p>")
        try site.write(".secret", "hidden")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)

        try await startServer(Router.Config(liveReload: false))
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        session.invalidateAndCancel()
        site = nil
    }

    // MARK: - 工具

    private func startServer(_ config: Router.Config) async throws {
        server?.stop()
        let server = HTTPServer(rootURL: site.url, config: config)
        self.server = server

        for _ in 0..<5 {
            let candidate = UInt16.random(in: 20_000...60_000)
            let started = expectation(description: "server state")
            started.assertForOverFulfill = false
            let running = LockedValue<Bool?>(nil)
            server.onStateChange = { state in
                switch state {
                case .running:
                    running.value = true
                    started.fulfill()
                case .failed:
                    running.value = false
                    started.fulfill()
                default:
                    break
                }
            }
            server.start(port: candidate, localOnly: true)
            await fulfillment(of: [started], timeout: 5)
            if running.value == true {
                port = candidate
                return
            }
        }
        XCTFail("无法启动测试服务器")
    }

    @discardableResult
    private func send(
        _ path: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (body: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    // MARK: - 静态文件

    func testServesIndexForRoot() async throws {
        let (body, response) = try await send("/")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(text(body), "<html><body>Home</body></html>")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
    }

    func testKeepAliveServesManyRequests() async throws {
        for _ in 0..<20 {
            let (body, response) = try await send("/data.txt")
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(text(body), "0123456789")
        }
    }

    func testRedirectsDirectoryToTrailingSlash() async throws {
        let (body, response) = try await send("/docs")
        // URL.path 会去掉末尾的斜杠，所以检查完整地址
        XCTAssertTrue(response.url?.absoluteString.hasSuffix("/docs/") == true)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(text(body).contains("readme.txt"), "应显示目录列表")
    }

    func testNotFoundAndCustom404Page() async throws {
        let (_, plain) = try await send("/missing.html")
        XCTAssertEqual(plain.statusCode, 404)

        try site.write("404.html", "custom not found")
        let (body, custom) = try await send("/missing.html")
        XCTAssertEqual(custom.statusCode, 404)
        XCTAssertEqual(text(body), "custom not found")
    }

    func testRangeRequests() async throws {
        let (body, response) = try await send("/data.txt", headers: ["Range": "bytes=2-4"])
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(text(body), "234")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 2-4/10")

        let (_, unsatisfiable) = try await send("/data.txt", headers: ["Range": "bytes=50-"])
        XCTAssertEqual(unsatisfiable.statusCode, 416)
    }

    func testHeadRequest() async throws {
        let (body, response) = try await send("/data.txt", method: "HEAD")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "10")
        XCTAssertTrue(body.isEmpty)
    }

    func testETagRevalidation() async throws {
        let (_, first) = try await send("/data.txt")
        let etag = try XCTUnwrap(first.value(forHTTPHeaderField: "ETag"))
        let (_, second) = try await send("/data.txt", headers: ["If-None-Match": etag])
        XCTAssertEqual(second.statusCode, 304)
    }

    func testRejectsHiddenFilesAndTraversal() async throws {
        let (_, hidden) = try await send("/.secret")
        XCTAssertEqual(hidden.statusCode, 403)
        let (_, traversal) = try await send("/docs/%2e%2e/%2e%2e/etc/passwd")
        XCTAssertNotEqual(traversal.statusCode, 200)
    }

    func testRejectsUnsupportedMethods() async throws {
        let (_, response) = try await send("/index.html", method: "POST", body: Data("x".utf8))
        XCTAssertEqual(response.statusCode, 405)
    }

    func testLargeFileStreaming() async throws {
        let large = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try large.write(to: site.url.appendingPathComponent("large.bin"))
        let (body, response) = try await send("/large.bin")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(body, large)
    }

    // MARK: - 网站选项

    func testSPAFallback() async throws {
        try await startServer(Router.Config(spaFallback: true, liveReload: false))
        let (body, response) = try await send("/some/client/route", headers: ["Accept": "text/html"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(text(body).contains("Home"))
    }

    func testSiteRootSwitching() async throws {
        try await startServer(Router.Config(liveReload: false, siteRoot: "site2"))
        let (body, _) = try await send("/")
        XCTAssertEqual(text(body), "<p>site2</p>")

        // 设置的文件夹不存在时回退到存储根目录
        try await startServer(Router.Config(liveReload: false, siteRoot: "missing"))
        let (fallback, _) = try await send("/")
        XCTAssertTrue(text(fallback).contains("Home"))
    }

    func testLiveReload() async throws {
        try await startServer(Router.Config(liveReload: true))
        let (page, _) = try await send("/")
        XCTAssertTrue(text(page).contains(LiveReload.scriptTag))

        let (script, scriptResponse) = try await send(LiveReload.scriptPath)
        XCTAssertEqual(scriptResponse.statusCode, 200)
        XCTAssertTrue(text(script).contains(LiveReload.versionPath))

        let (before, _) = try await send(LiveReload.versionPath)
        try site.write("index.html", "<html><body>Changed content</body></html>")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let (after, _) = try await send(LiveReload.versionPath)
        XCTAssertNotEqual(text(before), text(after))

        // 纯文本文件不注入脚本
        let (data, _) = try await send("/data.txt")
        XCTAssertEqual(text(data), "0123456789")
    }

    // MARK: - 网页管理

    private let guardHeader = ["X-LocalServer": "1"]

    func testAdminUploadWithoutPassword() async throws {
        let (_, page) = try await send("/__admin/")
        XCTAssertEqual(page.statusCode, 200)

        let (_, created) = try await send("/__admin/api/file?path=/up/new.txt", method: "PUT", headers: guardHeader, body: Data("abc".utf8))
        XCTAssertEqual(created.statusCode, 201)
        XCTAssertEqual(site.read("up/new.txt"), "abc")

        let (_, missingHeader) = try await send("/__admin/api/file?path=/x.txt", method: "PUT", body: Data("x".utf8))
        XCTAssertEqual(missingHeader.statusCode, 428)
        XCTAssertFalse(site.exists("x.txt"))
    }

    func testAdminLargeUploadUsesTemporaryFile() async throws {
        let large = Data((0..<3_000_000).map { UInt8($0 % 253) })
        let (_, response) = try await send("/__admin/api/file?path=/big.bin", method: "PUT", headers: guardHeader, body: large)
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(try Data(contentsOf: site.url.appendingPathComponent("big.bin")), large)
    }

    func testAdminZipUploadExtracts() async throws {
        let zip = TestZip.make([.file("pkg/index.html", "from zip"), .file("pkg/app.js", "1")])
        let (_, response) = try await send("/__admin/api/file?path=/sub/pkg.zip&extract=1", method: "PUT", headers: guardHeader, body: zip)
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(site.read("sub/pkg/index.html"), "from zip")
        XCTAssertFalse(site.exists("sub/pkg.zip"))
    }

    func testAdminManagementAPIs() async throws {
        let (_, mkdir) = try await send("/__admin/api/mkdir?path=/newdir", method: "POST", headers: guardHeader)
        XCTAssertEqual(mkdir.statusCode, 200)
        XCTAssertTrue(site.exists("newdir"))

        let (_, move) = try await send("/__admin/api/move?from=/data.txt&to=/newdir/data.txt", method: "POST", headers: guardHeader)
        XCTAssertEqual(move.statusCode, 200)
        XCTAssertEqual(site.read("newdir/data.txt"), "0123456789")

        let (listBody, list) = try await send("/__admin/api/list?path=/newdir")
        XCTAssertEqual(list.statusCode, 200)
        XCTAssertTrue(text(listBody).contains("data.txt"))

        let (_, delete) = try await send("/__admin/api/delete?path=/newdir", method: "POST", headers: guardHeader)
        XCTAssertEqual(delete.statusCode, 200)
        XCTAssertFalse(site.exists("newdir"))

        let (_, deleteRoot) = try await send("/__admin/api/delete?path=/", method: "POST", headers: guardHeader)
        XCTAssertEqual(deleteRoot.statusCode, 400)
        XCTAssertTrue(site.exists("index.html"))
    }

    func testAdminDisabled() async throws {
        try await startServer(Router.Config(webAdmin: false, liveReload: false))
        let (_, response) = try await send("/__admin/")
        XCTAssertEqual(response.statusCode, 404)
    }

    func testAdminPasswordFlow() async throws {
        try await startServer(Router.Config(liveReload: false, adminPassword: "123456"))

        let (page, _) = try await send("/__admin/")
        XCTAssertTrue(text(page).contains("输入访问密码"), "未登录时应显示登录页")

        let (_, unauthorized) = try await send("/__admin/api/list?path=/")
        XCTAssertEqual(unauthorized.statusCode, 401)
        let (_, uploadDenied) = try await send("/__admin/api/file?path=/x.txt", method: "PUT", headers: guardHeader, body: Data("x".utf8))
        XCTAssertEqual(uploadDenied.statusCode, 401)
        XCTAssertFalse(site.exists("x.txt"))

        let (_, wrong) = try await send("/__admin/api/login", method: "POST", headers: guardHeader, body: Data("000000".utf8))
        XCTAssertEqual(wrong.statusCode, 403)

        let (_, login) = try await send("/__admin/api/login", method: "POST", headers: guardHeader, body: Data("123456".utf8))
        XCTAssertEqual(login.statusCode, 200)
        let setCookie = try XCTUnwrap(login.value(forHTTPHeaderField: "Set-Cookie"))
        let cookie = try XCTUnwrap(setCookie.split(separator: ";").first.map(String.init))
        XCTAssertTrue(setCookie.contains("HttpOnly"))

        let (_, listed) = try await send("/__admin/api/list?path=/", headers: ["Cookie": cookie])
        XCTAssertEqual(listed.statusCode, 200)
        let (adminPage, _) = try await send("/__admin/", headers: ["Cookie": cookie])
        XCTAssertFalse(text(adminPage).contains("输入访问密码"))

        let (_, logout) = try await send("/__admin/api/logout", method: "POST", headers: guardHeader.merging(["Cookie": cookie]) { $1 })
        XCTAssertEqual(logout.statusCode, 200)
        let (_, afterLogout) = try await send("/__admin/api/list?path=/", headers: ["Cookie": cookie])
        XCTAssertEqual(afterLogout.statusCode, 401)
    }

    func testAdminLoginLockout() async throws {
        try await startServer(Router.Config(liveReload: false, adminPassword: "secret"))
        for _ in 0..<5 {
            let (_, response) = try await send("/__admin/api/login", method: "POST", headers: guardHeader, body: Data("bad".utf8))
            XCTAssertEqual(response.statusCode, 403)
        }
        // 锁定期间即使密码正确也会被拒绝
        let (_, locked) = try await send("/__admin/api/login", method: "POST", headers: guardHeader, body: Data("secret".utf8))
        XCTAssertEqual(locked.statusCode, 429)
    }
}
