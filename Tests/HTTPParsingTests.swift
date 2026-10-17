import XCTest
@testable import LocalServer

final class HTTPParsingTests: XCTestCase {
    private func head(_ text: String) -> HTTPRequestHead? {
        HTTPRequestHead(data: Data(text.utf8))
    }

    private func request(_ text: String) throws -> HTTPRequest {
        HTTPRequest(head: try XCTUnwrap(head(text)), body: .none, remoteAddress: "127.0.0.1")
    }

    func testParsesRequestLineAndHeaders() throws {
        let parsed = try XCTUnwrap(head("GET /index.html HTTP/1.1\r\nHost: example\r\nX-Test:  value \r\nAccept: a\r\nAccept: b"))
        XCTAssertEqual(parsed.method, "GET")
        XCTAssertEqual(parsed.target, "/index.html")
        XCTAssertEqual(parsed.version, "HTTP/1.1")
        XCTAssertEqual(parsed.header("host"), "example")
        XCTAssertEqual(parsed.header("X-TEST"), "value")
        XCTAssertEqual(parsed.header("accept"), "a, b")
    }

    func testRejectsMalformedRequests() {
        XCTAssertNil(head("GARBAGE"))
        XCTAssertNil(head("GET /"))
        XCTAssertNil(head("GET / HTTP/2.0"))
        XCTAssertNil(head(""))
    }

    func testIgnoresLeadingEmptyLines() {
        XCTAssertNotNil(head("\r\n\r\nGET / HTTP/1.1"))
    }

    func testKeepAliveSemantics() throws {
        XCTAssertTrue(try XCTUnwrap(head("GET / HTTP/1.1")).wantsKeepAlive)
        XCTAssertFalse(try XCTUnwrap(head("GET / HTTP/1.1\r\nConnection: close")).wantsKeepAlive)
        XCTAssertFalse(try XCTUnwrap(head("GET / HTTP/1.0")).wantsKeepAlive)
        XCTAssertTrue(try XCTUnwrap(head("GET / HTTP/1.0\r\nConnection: Keep-Alive")).wantsKeepAlive)
    }

    func testDecodesPathAndQuery() throws {
        let parsed = try request("GET /my%20site/%E4%B8%AD%E6%96%87.html?a=1&b=%E4%BD%A0&flag HTTP/1.1")
        XCTAssertEqual(parsed.rawPath, "/my%20site/%E4%B8%AD%E6%96%87.html")
        XCTAssertEqual(parsed.path, "/my site/中文.html")
        XCTAssertEqual(parsed.query["a"], "1")
        XCTAssertEqual(parsed.query["b"], "你")
        XCTAssertEqual(parsed.query["flag"], "")
    }

    func testAbsoluteFormTarget() throws {
        let parsed = try request("GET http://host:8080/a/b?x=1 HTTP/1.1")
        XCTAssertEqual(parsed.path, "/a/b")
        XCTAssertEqual(parsed.query["x"], "1")
    }

    func testResponseSerialization() throws {
        var response = HTTPResponse.text("hi")
        response.setHeader("content-type", "text/x")
        XCTAssertEqual(response.headers.filter { $0.0.lowercased() == "content-type" }.count, 1)
        XCTAssertEqual(response.header("Content-Type"), "text/x")

        let text = try XCTUnwrap(String(data: response.serializedHead(), encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertEqual(response.contentLength, 2)
    }

    func testResponsesWithoutBody() {
        XCTAssertFalse(HTTPResponse(status: 304).allowsBody)
        XCTAssertFalse(HTTPResponse(status: 204).allowsBody)
        XCTAssertTrue(HTTPResponse(status: 404).allowsBody)
    }

    func testHTMLEscaping() {
        XCTAssertEqual("<a href=\"x\">&'".htmlEscaped, "&lt;a href=&quot;x&quot;&gt;&amp;&#39;")
    }

    func testHTTPDateRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let text = HTTPDate.string(from: date)
        XCTAssertEqual(text, "Tue, 14 Nov 2023 22:13:20 GMT")
        XCTAssertEqual(try XCTUnwrap(HTTPDate.date(from: text)).timeIntervalSince1970, 1_700_000_000)
    }
}

final class ByteRangeTests: XCTestCase {
    func testSingleRanges() {
        XCTAssertEqual(ByteRange.parse("bytes=0-99", size: 1000), .partial(offset: 0, length: 100))
        XCTAssertEqual(ByteRange.parse("bytes=900-", size: 1000), .partial(offset: 900, length: 100))
        XCTAssertEqual(ByteRange.parse("bytes=990-2000", size: 1000), .partial(offset: 990, length: 10))
        XCTAssertEqual(ByteRange.parse(" bytes=0-0 ", size: 1000), .partial(offset: 0, length: 1))
    }

    func testSuffixRanges() {
        XCTAssertEqual(ByteRange.parse("bytes=-100", size: 1000), .partial(offset: 900, length: 100))
        XCTAssertEqual(ByteRange.parse("bytes=-2000", size: 1000), .partial(offset: 0, length: 1000))
        XCTAssertEqual(ByteRange.parse("bytes=-0", size: 1000), .unsatisfiable)
    }

    func testUnsatisfiableRanges() {
        XCTAssertEqual(ByteRange.parse("bytes=1000-", size: 1000), .unsatisfiable)
        XCTAssertEqual(ByteRange.parse("bytes=0-", size: 0), .unsatisfiable)
    }

    func testIgnoredRanges() {
        XCTAssertEqual(ByteRange.parse("bytes=5-2", size: 1000), .full)
        XCTAssertEqual(ByteRange.parse("bytes=0-1,5-6", size: 1000), .full)
        XCTAssertEqual(ByteRange.parse("items=0-1", size: 1000), .full)
        XCTAssertEqual(ByteRange.parse("bytes=abc-", size: 1000), .full)
    }
}

final class PathResolverTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/site", isDirectory: true)

    func testResolvesNormalPaths() {
        XCTAssertEqual(PathResolver.resolve("/", in: root)?.path, "/tmp/site")
        XCTAssertEqual(PathResolver.resolve("/a/b.html", in: root)?.path, "/tmp/site/a/b.html")
        XCTAssertEqual(PathResolver.resolve("/./a//b", in: root)?.path, "/tmp/site/a/b")
        XCTAssertEqual(PathResolver.resolve("/.well-known/x", in: root)?.path, "/tmp/site/.well-known/x")
    }

    func testRejectsTraversalAndHiddenFiles() {
        XCTAssertNil(PathResolver.resolve("/../etc/passwd", in: root))
        XCTAssertNil(PathResolver.resolve("/a/../../x", in: root))
        XCTAssertNil(PathResolver.resolve("/a/..", in: root))
        XCTAssertNil(PathResolver.resolve("/.git/config", in: root))
        XCTAssertNil(PathResolver.resolve("/a/.env", in: root))
    }
}
