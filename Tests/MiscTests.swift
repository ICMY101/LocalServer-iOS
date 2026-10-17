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
        XCTAssertEqual(settings.adminPassword, "")
        XCTAssertEqual(settings.siteRoot, "")
    }

    func testRoundTrip() throws {
        var settings = ServerSettings()
        settings.port = 12345
        settings.adminPassword = "abc"
        settings.siteRoot = "blog"
        settings.liveReload = false
        let decoded = try JSONDecoder().decode(ServerSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testRandomPassword() {
        let password = ServerSettings.randomPassword()
        XCTAssertEqual(password.count, 6)
        XCTAssertTrue(password.allSatisfy(\.isNumber))
    }

    func testRouterConfigMapping() {
        var settings = ServerSettings()
        settings.adminPassword = "pw"
        settings.siteRoot = "a/b"
        settings.spaFallback = true
        let config = settings.routerConfig
        XCTAssertEqual(config.adminPassword, "pw")
        XCTAssertEqual(config.siteRoot, "a/b")
        XCTAssertTrue(config.spaFallback)
    }
}

final class AdminAuthTests: XCTestCase {
    func testConstantTimeEquals() {
        XCTAssertTrue(AdminAPI.constantTimeEquals("123456", "123456"))
        XCTAssertFalse(AdminAPI.constantTimeEquals("123456", "123457"))
        XCTAssertFalse(AdminAPI.constantTimeEquals("12345", "123456"))
        XCTAssertTrue(AdminAPI.constantTimeEquals("", ""))
        XCTAssertTrue(AdminAPI.constantTimeEquals("密码", "密码"))
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
