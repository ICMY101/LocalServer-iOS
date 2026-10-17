import Foundation

/// 请求日志和访问统计单独存放：只有日志、统计区域订阅它，
/// 不会因为每个请求都让依赖 ServerManager 的文件页、设置页整页重绘。
@MainActor
final class RequestLogStore: ObservableObject {
    static let maxLogs = 200

    /// 最新的在前
    @Published private(set) var logs: [RequestLog] = []
    /// 本次启动以来的请求总数
    @Published private(set) var totalRequests = 0
    /// 本次启动以来发送的数据量
    @Published private(set) var totalBytes: UInt64 = 0
    /// 各访问设备最近一次请求的时间
    @Published private(set) var clients: [String: Date] = [:]

    /// App 在后台时暂存，不触发界面更新
    private var pendingLogs: [RequestLog] = []
    private var pendingRequests = 0
    private var pendingBytes: UInt64 = 0
    private var pendingClients: [String: Date] = [:]

    /// App 在后台时只暂存日志、不触发界面更新，回到前台再一次性显示
    var isVisible = true {
        didSet {
            guard isVisible && !oldValue else { return }
            totalRequests += pendingRequests
            totalBytes += pendingBytes
            clients.merge(pendingClients) { max($0, $1) }
            logs = Array((Array(pendingLogs.reversed()) + logs).prefix(Self.maxLogs))
            pendingLogs = []
            pendingRequests = 0
            pendingBytes = 0
            pendingClients = [:]
        }
    }

    /// 最近 10 分钟内访问过的设备数
    var activeClients: Int {
        let cutoff = Date().addingTimeInterval(-600)
        return clients.values.filter { $0 > cutoff }.count
    }

    /// batch 按时间先后排列
    func append(_ batch: [RequestLog]) {
        guard !batch.isEmpty else { return }
        let bytes = batch.reduce(UInt64(0)) { $0 + $1.bytes }
        if isVisible {
            totalRequests += batch.count
            totalBytes += bytes
            for log in batch {
                clients[log.client] = log.date
            }
            logs = Array((Array(batch.reversed()) + logs).prefix(Self.maxLogs))
        } else {
            pendingRequests += batch.count
            pendingBytes += bytes
            for log in batch {
                pendingClients[log.client] = log.date
            }
            pendingLogs.append(contentsOf: batch)
            if pendingLogs.count > Self.maxLogs {
                pendingLogs.removeFirst(pendingLogs.count - Self.maxLogs)
            }
        }
    }

    func clear() {
        logs.removeAll()
        totalRequests = 0
        totalBytes = 0
        clients.removeAll()
        pendingLogs.removeAll()
        pendingRequests = 0
        pendingBytes = 0
        pendingClients.removeAll()
    }
}

/// 线程安全的日志缓冲：服务器线程逐条写入，主线程定时批量取走，
/// 一个页面同时加载几十个资源时也只会触发一次界面更新。
final class LogBuffer: @unchecked Sendable {
    static let capacity = 200

    private let lock = NSLock()
    private var items: [RequestLog] = []
    private var flushScheduled = false

    /// 返回 true 表示调用方需要安排一次刷新
    func add(_ log: RequestLog) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items.append(log)
        if items.count > Self.capacity {
            items.removeFirst(items.count - Self.capacity)
        }
        guard !flushScheduled else { return false }
        flushScheduled = true
        return true
    }

    func drain() -> [RequestLog] {
        lock.lock()
        defer { lock.unlock() }
        flushScheduled = false
        let drained = items
        items = []
        return drained
    }
}
