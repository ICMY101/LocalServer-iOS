import Foundation

/// 文件变化后自动刷新浏览器。
/// HTML 响应中会插入一段脚本，每秒轮询一次网站目录的“指纹”，指纹变化就刷新页面。
/// 用轮询而不是长连接，App 被挂起再恢复后也能自动续上。
final class LiveReload {
    static let scriptPath = "/__livereload.js"
    static let versionPath = "/__livereload/version"
    static let maxInjectSize: UInt64 = 8 * 1024 * 1024
    static let scriptTag = "<script src=\"/__livereload.js\"></script>"

    /// 指纹缓存时长，避免多个页面同时轮询时重复遍历目录
    private static let cacheInterval: TimeInterval = 0.8
    private static let maxScannedFiles = 20_000

    private var cachedRoot: URL?
    private var cachedVersion = ""
    private var cachedAt = Date.distantPast

    static func handles(_ path: String) -> Bool {
        path == scriptPath || path == versionPath
    }

    func handle(_ request: HTTPRequest, root: URL) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return .error(405)
        }
        if request.path == Self.scriptPath {
            var response = HTTPResponse.text(Self.script, contentType: "text/javascript; charset=utf-8")
            response.setHeader("Cache-Control", "no-cache")
            return response
        }
        var response = HTTPResponse.text(version(of: root))
        response.setHeader("Cache-Control", "no-store")
        return response
    }

    /// 根据所有文件的路径、大小和修改时间计算出的指纹
    func version(of root: URL) -> String {
        if cachedRoot == root, Date().timeIntervalSince(cachedAt) < Self.cacheInterval {
            return cachedVersion
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var hasher = Hasher()
        hasher.combine(root.path)
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) {
            var count = 0
            for case let url as URL in enumerator {
                count += 1
                if count > Self.maxScannedFiles { break }
                let values = try? url.resourceValues(forKeys: Set(keys))
                hasher.combine(url.path)
                hasher.combine(values?.fileSize ?? -1)
                hasher.combine(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
            }
        }
        cachedRoot = root
        cachedVersion = String(UInt(bitPattern: hasher.finalize()), radix: 36)
        cachedAt = Date()
        return cachedVersion
    }

    /// 在最后一个 `</body>` 之前插入脚本，没有 `</body>` 时追加到末尾
    static func inject(into data: Data) -> Data {
        guard let html = String(data: data, encoding: .utf8) else {
            return data + Data(scriptTag.utf8)
        }
        guard let range = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) else {
            return Data((html + scriptTag).utf8)
        }
        var result = html
        result.insert(contentsOf: scriptTag, at: range.lowerBound)
        return Data(result.utf8)
    }

    private static let script = #"""
(function () {
  if (window.__localServerLiveReload) return;
  window.__localServerLiveReload = true;
  var current = null;
  function schedule(ms) { setTimeout(poll, ms); }
  function poll() {
    if (document.hidden) { schedule(2000); return; }
    fetch('/__livereload/version', { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.text() : null; })
      .then(function (v) {
        if (v === null) { schedule(5000); return; }
        if (current === null) { current = v; }
        else if (v !== current) { location.reload(); return; }
        schedule(1000);
      })
      .catch(function () { schedule(3000); });
  }
  if (document.readyState === 'complete') poll();
  else window.addEventListener('load', poll);
})();
"""#
}
