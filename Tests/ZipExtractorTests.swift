import XCTest
@testable import LocalServer

final class ZipExtractorTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var output: URL!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
        output = directory.url.appendingPathComponent("out", isDirectory: true)
    }

    override func tearDown() {
        directory = nil
    }

    private func extract(_ entries: [TestZip.Entry]) throws -> ZipExtractor.Result {
        let zip = directory.url.appendingPathComponent("test.zip")
        try TestZip.write(entries, to: zip)
        return try ZipExtractor.extract(zip, into: output)
    }

    private func content(_ path: String) -> String? {
        try? String(contentsOf: output.appendingPathComponent(path), encoding: .utf8)
    }

    func testExtractsFilesAndDirectories() throws {
        let result = try extract([
            .directory("site/"),
            .directory("site/css/"),
            .file("site/index.html", "<h1>hi</h1>"),
            .file("site/css/app.css", "body{}"),
            .file("site/中文.txt", "你好"),
        ])
        XCTAssertEqual(result, ZipExtractor.Result(files: 3, skipped: 0))
        XCTAssertEqual(content("site/index.html"), "<h1>hi</h1>")
        XCTAssertEqual(content("site/css/app.css"), "body{}")
        XCTAssertEqual(content("site/中文.txt"), "你好")
    }

    func testDecodesGBKFileNames() throws {
        // Windows 自带压缩工具常用 GBK 编码文件名，且不设置 UTF-8 标志
        let name = try XCTUnwrap("网站/首页.html".data(using: ZipExtractor.gb18030))
        let entry = TestZip.Entry(name: Array(name), data: Data("ok".utf8), utf8Flag: false, kind: .file)
        let result = try extract([entry])
        XCTAssertEqual(result.files, 1)
        XCTAssertEqual(content("网站/首页.html"), "ok")
    }

    func testRejectsPathTraversal() throws {
        let result = try extract([
            .file("../evil.txt", "x"),
            .file("a/../../evil2.txt", "x"),
            .file("/absolute.txt", "x"),
            .file("..\\windows.txt", "x"),
            .file("ok.txt", "ok"),
        ])
        XCTAssertEqual(result, ZipExtractor.Result(files: 1, skipped: 4))
        XCTAssertEqual(content("ok.txt"), "ok")
        XCTAssertFalse(directory.exists("evil.txt"))
        XCTAssertFalse(directory.exists("evil2.txt"))
        XCTAssertFalse(directory.exists("windows.txt"))
    }

    func testSkipsMacMetadataAndHiddenFiles() throws {
        let result = try extract([
            .file("__MACOSX/._index.html", "x"),
            .file(".DS_Store", "x"),
            .file("a/.hidden", "x"),
            .file("a/b.txt", "b"),
        ])
        XCTAssertEqual(result, ZipExtractor.Result(files: 1, skipped: 3))
        XCTAssertEqual(content("a/b.txt"), "b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("__MACOSX").path))
    }

    func testSkipsSymlinks() throws {
        let result = try extract([
            .symlink("link", target: "/etc/passwd"),
            .file("real.txt", "r"),
        ])
        XCTAssertEqual(result, ZipExtractor.Result(files: 1, skipped: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("link").path))
    }

    func testOverwritesExistingFiles() throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: output.appendingPathComponent("a.txt"))
        // 已存在一个与目录同名的普通文件
        try Data("file".utf8).write(to: output.appendingPathComponent("dir"))

        let result = try extract([
            .file("a.txt", "new"),
            .file("dir/x.txt", "x"),
        ])
        XCTAssertEqual(result.files, 2)
        XCTAssertEqual(content("a.txt"), "new")
        XCTAssertEqual(content("dir/x.txt"), "x")
    }

    func testInvalidZipThrows() throws {
        let zip = directory.url.appendingPathComponent("bad.zip")
        try Data("this is not a zip".utf8).write(to: zip)
        XCTAssertThrowsError(try ZipExtractor.extract(zip, into: output))
    }

    func testSanitizedComponents() {
        XCTAssertEqual(ZipExtractor.sanitizedComponents("a/b/c.txt"), ["a", "b", "c.txt"])
        XCTAssertEqual(ZipExtractor.sanitizedComponents("a\\b.txt"), ["a", "b.txt"])
        XCTAssertEqual(ZipExtractor.sanitizedComponents("./a//b/"), ["a", "b"])
        XCTAssertNil(ZipExtractor.sanitizedComponents("../a"))
        XCTAssertNil(ZipExtractor.sanitizedComponents("/a"))
        XCTAssertNil(ZipExtractor.sanitizedComponents("C:/a"))
        XCTAssertNil(ZipExtractor.sanitizedComponents("__MACOSX/a"))
        XCTAssertNil(ZipExtractor.sanitizedComponents(""))
    }
}
