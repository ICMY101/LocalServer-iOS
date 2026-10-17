import Foundation

/// 文件变化后自动刷新浏览器。
///
/// HTML 响应中会插入一段脚本，用“长轮询”等待网站目录的变化：
/// 浏览器带着当前版本号请求 `/__livereload/version?v=…`，版本没变时服务器把请求挂起最多 25 秒，
/// 一旦检测到变化立即返回新版本，浏览器随即刷新页面。
///
/// 相比每秒轮询，打开的页面几乎不产生请求；没有页面在等待时也完全不扫描目录，更省电。
final class LiveReload {
    static let scriptPath = "/__livereload.js"
    static let versionPath = "/__livereload/version"
    static let maxInjectSize: UInt64 = 2 * 1024 * 1024
    static let scriptTag = "<script src=\"/__livereload.js\"></script>"

    /// 单个长轮询请求最多挂起多久
    static let holdDuration: TimeInterval = 25
    /// 有页面在等待时，多久扫描一次目录（用于发现「文件」App 等外部修改）
    static let scanInterval: TimeInterval = 2
    private static let maxScannedFiles = 20_000

    private struct Waiter {
        let known: String
        let deadline: Date
        let completion: (String) -> Void
    }

    private let queue = DispatchQueue(label: "LocalServer.livereload", qos: .utility)
    private var root: URL?
    private var current = ""
    private var waiters: [Waiter] = []
    private var timer: DispatchSourceTimer?

    static func handles(_ path: String) -> Bool {
        path == scriptPath || path == versionPath
    }

    func handle(_ request: HTTPRequest, root: URL, completion: @escaping (HTTPResponse) -> Void) {
        guard request.method == "GET" || request.method == "HEAD" else {
            completion(.error(405))
            return
        }
        if request.path == Self.scriptPath {
            var response = HTTPResponse.text(Self.script, contentType: "text/javascript; charset=utf-8")
            response.setHeader("Cache-Control", "no-cache")
            completion(response)
            return
        }

        let known = request.query["v"] ?? ""
        let respond: (String) -> Void = { version in
            var response = HTTPResponse.text(version)
            response.setHeader("Cache-Control", "no-store")
            completion(response)
        }
        queue.async {
            let version = self.refresh(root: root)
            if known.isEmpty || known != version {
                respond(version)
                return
            }
            self.waiters.append(Waiter(known: known, deadline: Date().addingTimeInterval(Self.holdDuration), completion: respond))
            self.startTimerIfNeeded()
        }
    }

    /// App 内或网页管理修改了文件时调用，立即通知等待中的页面，不必等下一次扫描
    func notifyChanged() {
        queue.async {
            guard let root = self.root, !self.waiters.isEmpty else { return }
            _ = self.refresh(root: root)
            self.flushWaiters(force: false)
        }
    }

    /// 计算目录指纹（同步，供测试和内部使用）
    func version(of root: URL) -> String {
        Self.fingerprint(of: root)
    }

    // MARK: - 私有（都在 queue 上执行）

    private func refresh(root: URL) -> String {
        self.root = root
        current = Self.fingerprint(of: root)
        return current
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 允许系统合并唤醒，进一步降低能耗
        timer.schedule(deadline: .now() + Self.scanInterval, repeating: Self.scanInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, let root = self.root else { return }
            _ = self.refresh(root: root)
            self.flushWaiters(force: false)
        }
        self.timer = timer
        timer.resume()
    }

    /// 版本已变化或已超时的请求立即返回；没有等待者时停止计时器
    private func flushWaiters(force: Bool) {
        let now = Date()
        var remaining: [Waiter] = []
        for waiter in waiters {
            if force || waiter.known != current || waiter.deadline <= now {
                waiter.completion(current)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        if waiters.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    /// 根据所有文件的路径、大小和修改时间计算出的指纹
    private static func fingerprint(of root: URL) -> String {
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
                if count > maxScannedFiles { break }
                let values = try? url.resourceValues(forKeys: Set(keys))
                hasher.combine(url.path)
                hasher.combine(values?.fileSize ?? -1)
                hasher.combine(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
            }
        }
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
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
    fetch('/__livereload/version?v=' + encodeURIComponent(current || ''), { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.text() : null; })
      .then(function (v) {
        if (v === null) { schedule(10000); return; }
        if (current === null) { current = v; }
        else if (v !== current) { location.reload(); return; }
        schedule(document.hidden ? 1000 : 0);
      })
      .catch(function () { schedule(3000); });
  }
  if (document.readyState === 'complete') poll();
  else window.addEventListener('load', poll);
})();
"""#
}
