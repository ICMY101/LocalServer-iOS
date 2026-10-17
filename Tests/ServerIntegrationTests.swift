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
        try site.write("site2/css/app.css", "s2")
        try site.write("site1/index.html", "<html><head><link rel=stylesheet href=/css/app.css></head><body>site1</body></html>")
        try site.write("site1/css/app.css", "s1")
        try site.write("site1/page.html", "<p>page</p>")
        try site.write(".secret", "hidden")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)

        try await startServer(Router.Config(liveReload: false, requirePairing: false))
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

    func testRootShowsAllSites() async throws {
        let (body, response) = try await send("/")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
        let page = text(body)
        XCTAssertTrue(page.contains("href=\"/site1/\""))
        XCTAssertTrue(page.contains("href=\"/site2/\""))
        XCTAssertTrue(page.contains("href=\"/docs/\""))
        XCTAssertFalse(page.contains("Home"), "/ 显示站点列表，而不是根目录的 index.html")

        // 根目录下的散落文件仍然可以直接访问
        let (file, _) = try await send("/index.html")
        XCTAssertEqual(text(file), "<html><body>Home</body></html>")
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

    func testSPAFallbackWithinSite() async throws {
        try await startServer(Router.Config(spaFallback: true, liveReload: false))
        let (body, response) = try await send("/site2/some/client/route", headers: ["Accept": "text/html"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(text(body), "<p>site2</p>")

        // history 路由刷新后地址里没有站点名，按最近访问的站点回退
        let (routed, _) = try await send("/about", headers: ["Accept": "text/html", "Cookie": "ls_site=site2"])
        XCTAssertEqual(text(routed), "<p>site2</p>")
    }

    // MARK: - 多站点

    private func origin() -> String {
        "http://127.0.0.1:\(port)"
    }

    func testEachSiteIsItsOwnRoot() async throws {
        let (index, response) = try await send("/site1/")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(text(index).contains("site1"))
        XCTAssertTrue(response.value(forHTTPHeaderField: "Set-Cookie")?.hasPrefix("ls_site=site1;") == true)

        let (css1, _) = try await send("/site1/css/app.css")
        XCTAssertEqual(text(css1), "s1")
        let (css2, _) = try await send("/site2/css/app.css")
        XCTAssertEqual(text(css2), "s2")
    }

    func testSiteWithoutTrailingSlashRedirects() async throws {
        let (body, response) = try await send("/site2")
        XCTAssertTrue(response.url?.absoluteString.hasSuffix("/site2/") == true)
        XCTAssertEqual(text(body), "<p>site2</p>")
    }

    func testAbsolutePathsResolveByReferer() async throws {
        // 站点页面中的 /css/app.css 按来源页归属到对应站点
        let (fromSite1, r1) = try await send("/css/app.css", headers: ["Referer": origin() + "/site1/"])
        XCTAssertEqual(r1.statusCode, 200)
        XCTAssertEqual(text(fromSite1), "s1")
        let (fromSite2, _) = try await send("/css/app.css", headers: ["Referer": origin() + "/site2/index.html"])
        XCTAssertEqual(text(fromSite2), "s2")

        // 站点中跳转到以 / 开头的页面
        let (page, _) = try await send("/page.html", headers: ["Referer": origin() + "/site1/"])
        XCTAssertEqual(text(page), "<p>page</p>")

        // 从站点 1 链接到站点 2 的地址仍然指向站点 2
        let (crossSite, _) = try await send("/site2/css/app.css", headers: ["Referer": origin() + "/site1/"])
        XCTAssertEqual(text(crossSite), "s2")
    }

    func testAbsolutePathsResolveByCookieWithoutReferer() async throws {
        let (body, response) = try await send("/css/app.css", headers: ["Cookie": "ls_site=site2"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(text(body), "s2")

        // 没有任何来源信息时找不到
        let (_, missing) = try await send("/css/app.css")
        XCTAssertEqual(missing.statusCode, 404)
    }

    func testDisabledSiteIsInaccessible() async throws {
        try await startServer(Router.Config(liveReload: false, disabledSites: ["site2"]))
        let (body, response) = try await send("/site2/")
        XCTAssertEqual(response.statusCode, 403)
        XCTAssertTrue(text(body).contains("站点未开启"))
        let (_, asset) = try await send("/site2/css/app.css")
        XCTAssertEqual(asset.statusCode, 403)

        // 不出现在站点列表中，也不能通过来源页或 Cookie 间接访问
        let (portal, _) = try await send("/")
        XCTAssertFalse(text(portal).contains("href=\"/site2/\""))
        XCTAssertTrue(text(portal).contains("href=\"/site1/\""))
        let (_, viaReferer) = try await send("/css/app.css", headers: ["Referer": origin() + "/site2/"])
        XCTAssertEqual(viaReferer.statusCode, 404)
        let (_, viaCookie) = try await send("/css/app.css", headers: ["Cookie": "ls_site=site2"])
        XCTAssertEqual(viaCookie.statusCode, 404)
    }

    func testSiteNameRecordedForStatistics() async throws {
        let logs = LockedValue<[RequestLog]>([])
        server?.onRequest = { log in
            logs.value = logs.value + [log]
        }
        try await send("/site1/css/app.css")
        try await send("/css/app.css", headers: ["Referer": origin() + "/site2/"])
        try await send("/data.txt")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(logs.value.map(\.site), ["site1", "site2", nil])
    }

    // MARK: - 拉黑

    func testBlockedClientIsRejected() async throws {
        let blocked = LockedValue(0)
        server?.onBlocked = { _ in
            blocked.value = blocked.value + 1
        }
        server?.updateBlocklist(["127.0.0.1"])
        do {
            _ = try await send("/data.txt")
            XCTFail("被拉黑的设备不应该收到响应")
        } catch {
            // 连接被直接断开
        }
        XCTAssertGreaterThan(blocked.value, 0)

        server?.updateBlocklist([])
        let (body, response) = try await send("/data.txt")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(text(body), "0123456789")
    }

    func testLiveReload() async throws {
        try await startServer(Router.Config(liveReload: true))
        let (page, _) = try await send("/site2/")
        XCTAssertTrue(text(page).contains(LiveReload.scriptTag))

        let (script, scriptResponse) = try await send(LiveReload.scriptPath)
        XCTAssertEqual(scriptResponse.statusCode, 200)
        XCTAssertTrue(text(script).contains(LiveReload.versionPath))

        // 纯文本文件不注入脚本
        let (data, _) = try await send("/data.txt")
        XCTAssertEqual(text(data), "0123456789")
    }

    func testLiveReloadLongPollingDetectsExternalChange() async throws {
        try await startServer(Router.Config(liveReload: true))
        let (initial, _) = try await send(LiveReload.versionPath)
        let known = text(initial)
        XCTAssertFalse(known.isEmpty)

        // 版本没变时请求会被挂起；外部修改由定时扫描发现后立即返回新版本
        let started = Date()
        async let waited = send(LiveReload.versionPath + "?v=" + known)
        try await Task.sleep(nanoseconds: 500_000_000)
        try site.write("index.html", "<html><body>Changed content</body></html>")
        let (changed, _) = try await waited
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotEqual(text(changed), known)
        XCTAssertGreaterThan(elapsed, 0.4, "请求应该被挂起直到文件变化")
        XCTAssertLessThan(elapsed, 10)
    }

    func testLiveReloadWakesUpAfterAdminUpload() async throws {
        try await startServer(Router.Config(liveReload: true, requirePairing: false))
        let (initial, _) = try await send(LiveReload.versionPath)
        let known = text(initial)

        async let waited = send(LiveReload.versionPath + "?v=" + known)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await send("/__admin/api/file?path=/new.html", method: "PUT", headers: guardHeader, body: Data("<p>new</p>".utf8))
        let (changed, _) = try await waited
        XCTAssertNotEqual(text(changed), known)
    }

    func testConcurrentRequestsAreServed() async throws {
        // 并发队列处理请求：同时发出的请求都应正确完成
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask { [self] in
                    let (body, _) = try await self.send("/data.txt")
                    return self.text(body)
                }
            }
            for try await body in group {
                XCTAssertEqual(body, "0123456789")
            }
        }
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

    func testAdminFlatZipUploadGoesIntoFolder() async throws {
        let zip = TestZip.make([.file("index.html", "flat"), .file("app.js", "1")])
        let (body, response) = try await send("/__admin/api/file?path=/demo.zip&extract=1", method: "PUT", headers: guardHeader, body: zip)
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertTrue(text(body).contains("\"folder\":\"demo\""))
        XCTAssertEqual(site.read("demo/index.html"), "flat")
        XCTAssertEqual(site.read("index.html"), "<html><body>Home</body></html>", "不应覆盖根目录的文件")
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

    private let windowsChrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

    /// 与当前配对码不同的 6 位数字
    private func wrongPIN(_ pin: String) -> String {
        pin == "000000" ? "111111" : "000000"
    }

    func testAdminPairingFlow() async throws {
        // 默认需要配对
        try await startServer(Router.Config(liveReload: false))
        let pairing = try XCTUnwrap(server?.pairing)
        let requests = LockedValue<[PairingRequest]>([])
        pairing.onPairingRequest = { request in
            requests.value = requests.value + [request]
        }

        let (page, _) = try await send("/__admin/")
        XCTAssertTrue(text(page).contains("与 iPhone 配对"), "未配对时应显示配对页")

        let (_, unauthorized) = try await send("/__admin/api/list?path=/")
        XCTAssertEqual(unauthorized.statusCode, 401)
        let (_, uploadDenied) = try await send("/__admin/api/file?path=/x.txt", method: "PUT", headers: guardHeader, body: Data("x".utf8))
        XCTAssertEqual(uploadDenied.statusCode, 401)
        XCTAssertFalse(site.exists("x.txt"))
        let (_, downloadDenied) = try await send("/__admin/api/download?path=/data.txt")
        XCTAssertEqual(downloadDenied.statusCode, 401)

        // 打开配对页时通知 App 弹出配对码
        let (_, requested) = try await send("/__admin/api/pair-request", method: "POST", headers: guardHeader.merging(["User-Agent": windowsChrome]) { $1 })
        XCTAssertEqual(requested.statusCode, 200)
        XCTAssertEqual(requests.value.count, 1)
        XCTAssertEqual(requests.value.first?.deviceName, "Windows · Chrome")

        let pin = pairing.currentPIN().pin
        XCTAssertEqual(pin.count, 6)
        let (wrongBody, wrong) = try await send("/__admin/api/pair", method: "POST", headers: guardHeader, body: Data(wrongPIN(pin).utf8))
        XCTAssertEqual(wrong.statusCode, 403)
        XCTAssertTrue(text(wrongBody).contains("还可以再试 4 次"))

        let (_, paired) = try await send("/__admin/api/pair", method: "POST", headers: guardHeader.merging(["User-Agent": windowsChrome]) { $1 }, body: Data(pin.utf8))
        XCTAssertEqual(paired.statusCode, 200)
        let setCookie = try XCTUnwrap(paired.value(forHTTPHeaderField: "Set-Cookie"))
        let cookie = try XCTUnwrap(setCookie.split(separator: ";").first.map(String.init))
        XCTAssertTrue(setCookie.contains("HttpOnly"))
        XCTAssertNotEqual(pairing.currentPIN().pin, pin, "配对码只能使用一次")
        XCTAssertEqual(pairing.pairedDevices.map(\.name), ["Windows · Chrome"])

        let (_, listed) = try await send("/__admin/api/list?path=/", headers: ["Cookie": cookie])
        XCTAssertEqual(listed.statusCode, 200)
        let (adminPage, _) = try await send("/__admin/", headers: ["Cookie": cookie])
        XCTAssertFalse(text(adminPage).contains("与 iPhone 配对"))
        let (file, download) = try await send("/__admin/api/download?path=/data.txt", headers: ["Cookie": cookie])
        XCTAssertEqual(download.statusCode, 200)
        XCTAssertEqual(text(file), "0123456789")
        XCTAssertTrue(download.value(forHTTPHeaderField: "Content-Disposition")?.contains("attachment") == true)

        // 浏览器主动取消配对
        let (_, unpaired) = try await send("/__admin/api/unpair", method: "POST", headers: guardHeader.merging(["Cookie": cookie]) { $1 })
        XCTAssertEqual(unpaired.statusCode, 200)
        let (_, afterUnpair) = try await send("/__admin/api/list?path=/", headers: ["Cookie": cookie])
        XCTAssertEqual(afterUnpair.statusCode, 401)
        XCTAssertTrue(pairing.pairedDevices.isEmpty)
    }

    func testRevokingDeviceFromAppBlocksBrowser() async throws {
        try await startServer(Router.Config(liveReload: false))
        let pairing = try XCTUnwrap(server?.pairing)
        let (_, paired) = try await send("/__admin/api/pair", method: "POST", headers: guardHeader, body: Data(pairing.currentPIN().pin.utf8))
        let cookie = try XCTUnwrap(paired.value(forHTTPHeaderField: "Set-Cookie")?.split(separator: ";").first.map(String.init))
        let (_, allowed) = try await send("/__admin/api/list?path=/", headers: ["Cookie": cookie])
        XCTAssertEqual(allowed.statusCode, 200)

        // 在 App 中取消配对后，这个浏览器立即失去权限
        pairing.revokeAll()
        let (_, denied) = try await send("/__admin/api/list?path=/", headers: ["Cookie": cookie])
        XCTAssertEqual(denied.statusCode, 401)
    }

    func testPairingLockout() async throws {
        try await startServer(Router.Config(liveReload: false))
        let pairing = try XCTUnwrap(server?.pairing)
        let pin = pairing.currentPIN().pin
        for attempt in 1...5 {
            let (_, response) = try await send("/__admin/api/pair", method: "POST", headers: guardHeader, body: Data(wrongPIN(pin).utf8))
            XCTAssertEqual(response.statusCode, attempt < 5 ? 403 : 429)
        }
        // 锁定期间即使配对码正确也会被拒绝
        let (_, locked) = try await send("/__admin/api/pair", method: "POST", headers: guardHeader, body: Data(pairing.currentPIN().pin.utf8))
        XCTAssertEqual(locked.statusCode, 429)
    }
}
