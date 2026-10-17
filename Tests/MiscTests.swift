import XCTest
@testable import LocalServer

final class ServerSettingsTests: XCTestCase {
    func testDecodingOldSettingsKeepsValuesAndFillsDefaults() throws {
        // 1.0 版本保存的设置中没有新增的字段
        let json = #"{"port":9000,"allowLAN":false,"autoStart":true,"directoryListing":false,"spaFallback":true,"cors":false,"webAdmin":true,"keepScreenOn":true,"backgroundAudio":false}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.port, 9000)
        XCTAssertFalse(settings.allowLAN)
        XCTAssertFalse(settings.directoryListing)
        XCTAssertTrue(settings.spaFallback)
        XCTAssertTrue(settings.keepScreenOn)
        // 新字段使用默认值
        XCTAssertTrue(settings.liveReload)
        XCTAssertTrue(settings.autoExtractZip)
        XCTAssertTrue(settings.bonjour)
        XCTAssertTrue(settings.requirePairing)
        XCTAssertEqual(settings.siteRoot, "")
        XCTAssertEqual(settings.keepAliveIdleMinutes, 15)
        // 用户原来关闭的后台保活保持关闭
        XCTAssertFalse(settings.backgroundAudio)
    }

    func testRoundTrip() throws {
        var settings = ServerSettings()
        settings.port = 12345
        settings.requirePairing = false
        settings.siteRoot = "blog"
        settings.liveReload = false
        let decoded = try JSONDecoder().decode(ServerSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testNewInstallDefaults() {
        let settings = ServerSettings()
        XCTAssertTrue(settings.requirePairing)
        XCTAssertTrue(settings.backgroundAudio, "网页在系统浏览器中打开，默认需要后台保活")
    }

    func testRouterConfigMapping() {
        var settings = ServerSettings()
        settings.requirePairing = false
        settings.siteRoot = "a/b"
        settings.spaFallback = true
        let config = settings.routerConfig
        XCTAssertFalse(config.requirePairing)
        XCTAssertEqual(config.siteRoot, "a/b")
        XCTAssertTrue(config.spaFallback)
    }
}

final class RequestLogTests: XCTestCase {
    private func log(_ path: String) -> RequestLog {
        RequestLog(date: Date(), method: "GET", path: path, status: 200, client: "127.0.0.1")
    }

    @MainActor
    func testStoreKeepsNewestFirstAndCapsSize() async {
        let store = RequestLogStore()
        store.append([log("/1"), log("/2")])
        store.append([log("/3")])
        XCTAssertEqual(store.logs.map(\.path), ["/3", "/2", "/1"])

        store.append((0..<500).map { log("/bulk\($0)") })
        XCTAssertEqual(store.logs.count, RequestLogStore.maxLogs)
        XCTAssertEqual(store.logs.first?.path, "/bulk499")
    }

    @MainActor
    func testHiddenStoreDefersUpdatesUntilVisible() async {
        let store = RequestLogStore()
        store.isVisible = false
        store.append([log("/a"), log("/b")])
        XCTAssertTrue(store.logs.isEmpty, "后台时不应更新界面数据")
        store.isVisible = true
        XCTAssertEqual(store.logs.map(\.path), ["/b", "/a"])
    }

    func testBufferSchedulesOneFlushPerBatch() {
        let buffer = LogBuffer()
        XCTAssertTrue(buffer.add(log("/1")))
        XCTAssertFalse(buffer.add(log("/2")))
        XCTAssertFalse(buffer.add(log("/3")))
        XCTAssertEqual(buffer.drain().map(\.path), ["/1", "/2", "/3"])
        XCTAssertTrue(buffer.add(log("/4")), "取走后应重新安排刷新")
        XCTAssertEqual(buffer.drain().count, 1)
    }
}

final class PairingStoreTests: XCTestCase {
    func testConstantTimeEquals() {
        XCTAssertTrue(PairingStore.constantTimeEquals("123456", "123456"))
        XCTAssertFalse(PairingStore.constantTimeEquals("123456", "123457"))
        XCTAssertFalse(PairingStore.constantTimeEquals("12345", "123456"))
        XCTAssertTrue(PairingStore.constantTimeEquals("", ""))
    }

    func testPINFormatAndRegeneration() {
        let store = PairingStore(fileURL: nil)
        let first = store.currentPIN()
        XCTAssertEqual(first.pin.count, PairingStore.pinLength)
        XCTAssertTrue(first.pin.allSatisfy(\.isNumber))
        XCTAssertGreaterThan(first.expires, Date().addingTimeInterval(PairingStore.pinLifetime - 5))
        XCTAssertEqual(store.currentPIN().pin, first.pin, "未过期时配对码不变")
    }

    func testPairAcceptsFormattedPINAndIsOneTime() throws {
        let store = PairingStore(fileURL: nil)
        let pin = store.currentPIN().pin
        // 允许用户输入带空格的“123 456”
        let formatted = String(pin.prefix(3)) + " " + String(pin.suffix(3))
        let token = try store.pair(pin: formatted, address: "10.0.0.2", userAgent: nil).get()
        XCTAssertTrue(store.isPaired(token: token, address: "10.0.0.2"))
        XCTAssertFalse(store.isPaired(token: "bogus", address: "10.0.0.2"))
        XCTAssertFalse(store.isPaired(token: nil, address: "10.0.0.2"))

        // 同一个配对码不能再次使用
        guard case .failure(.wrongPIN) = store.pair(pin: pin, address: "10.0.0.3", userAgent: nil) else {
            return XCTFail("配对码应该已经失效")
        }
    }

    func testLockoutIsPerAddress() {
        let store = PairingStore(fileURL: nil)
        let wrong = store.currentPIN().pin == "000000" ? "111111" : "000000"
        for _ in 0..<4 {
            _ = store.pair(pin: wrong, address: "10.0.0.9", userAgent: nil)
        }
        guard case .failure(.locked) = store.pair(pin: wrong, address: "10.0.0.9", userAgent: nil) else {
            return XCTFail("第 5 次输错应锁定")
        }
        // 其他设备不受影响
        XCTAssertNoThrow(try store.pair(pin: store.currentPIN().pin, address: "10.0.0.10", userAgent: nil).get())
    }

    func testRevokeAndPersistence() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent("paired.json")
        let store = PairingStore(fileURL: file)
        let tokenA = try store.pair(pin: store.currentPIN().pin, address: "10.0.0.2", userAgent: nil).get()
        let tokenB = try store.pair(pin: store.currentPIN().pin, address: "10.0.0.3", userAgent: nil).get()
        XCTAssertEqual(store.pairedDevices.count, 2)

        // 重新启动后仍然有效
        let reloaded = PairingStore(fileURL: file)
        XCTAssertTrue(reloaded.isPaired(token: tokenA, address: "10.0.0.2"))
        XCTAssertTrue(reloaded.isPaired(token: tokenB, address: "10.0.0.3"))

        reloaded.revoke(token: tokenA)
        XCTAssertFalse(reloaded.isPaired(token: tokenA, address: "10.0.0.2"))
        XCTAssertTrue(PairingStore(fileURL: file).isPaired(token: tokenB, address: "10.0.0.3"))
        XCTAssertFalse(PairingStore(fileURL: file).isPaired(token: tokenA, address: "10.0.0.2"))

        // 文件中只保存令牌的哈希，不保存令牌本身
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains(tokenB))
    }

    func testDeviceNames() {
        XCTAssertEqual(DeviceName.from(userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"), "Windows · Chrome")
        XCTAssertEqual(DeviceName.from(userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 Edg/130.0"), "Windows · Edge")
        XCTAssertEqual(DeviceName.from(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"), "Mac · Safari")
        XCTAssertEqual(DeviceName.from(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:131.0) Gecko/20100101 Firefox/131.0"), "Mac · Firefox")
        XCTAssertEqual(DeviceName.from(userAgent: "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36"), "Android · Chrome")
        XCTAssertEqual(DeviceName.from(userAgent: nil), "未知设备")
    }
}

final class LiveReloadTests: XCTestCase {
    func testInjectsBeforeLastBodyTag() {
        let html = "<html><body><p>&lt;/body&gt;</p></BODY></html>"
        let result = String(decoding: LiveReload.inject(into: Data(html.utf8)), as: UTF8.self)
        XCTAssertEqual(result, "<html><body><p>&lt;/body&gt;</p>\(LiveReload.scriptTag)</BODY></html>")
    }

    func testAppendsWhenNoBodyTag() {
        let result = String(decoding: LiveReload.inject(into: Data("<p>hi</p>".utf8)), as: UTF8.self)
        XCTAssertEqual(result, "<p>hi</p>" + LiveReload.scriptTag)
    }

    func testVersionChangesWhenFilesChange() throws {
        let directory = try TemporaryDirectory()
        try directory.write("index.html", "a")
        let first = LiveReload().version(of: directory.url)
        XCTAssertEqual(first, LiveReload().version(of: directory.url))

        try directory.write("index.html", "changed")
        XCTAssertNotEqual(first, LiveReload().version(of: directory.url))

        try directory.write("new/page.html", "x")
        let third = LiveReload().version(of: directory.url)
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("new"))
        XCTAssertNotEqual(third, LiveReload().version(of: directory.url))
    }
}
