import Foundation

/// 某台访问设备（按 IP 区分）的统计
struct ClientStats: Identifiable, Equatable {
    let address: String
    var deviceName: String
    var requests = 0
    var bytes: UInt64 = 0
    var firstSeen: Date
    var lastSeen: Date
    var lastPath = ""

    var id: String { address }

    /// 本机访问（App 所在的手机自己），不能拉黑
    var isLocal: Bool {
        Self.isLocal(address)
    }

    static func isLocal(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1" || address == "localhost"
    }
}

/// 某个站点的访问情况
struct SiteActivity: Equatable {
    var requests = 0
    var lastAccess: Date
}

/// 访问统计
struct TrafficStats: Equatable {
    var totalRequests = 0
    var totalBytes: UInt64 = 0
    var clients: [String: ClientStats] = [:]
    var sites: [String: SiteActivity] = [:]
    /// 被拉黑设备的连接尝试次数
    var blockedAttempts: [String: Int] = [:]

    mutating func apply(_ log: RequestLog) {
        totalRequests += 1
        totalBytes += log.bytes

        var client = clients[log.client] ?? ClientStats(
            address: log.client,
            deviceName: DeviceName.from(userAgent: log.userAgent),
            firstSeen: log.date,
            lastSeen: log.date
        )
        client.requests += 1
        client.bytes += log.bytes
        client.lastSeen = max(client.lastSeen, log.date)
        client.lastPath = log.path
        if log.userAgent != nil {
            client.deviceName = DeviceName.from(userAgent: log.userAgent)
        }
        clients[log.client] = client

        if let site = log.site {
            var activity = sites[site] ?? SiteActivity(lastAccess: log.date)
            activity.requests += 1
            activity.lastAccess = max(activity.lastAccess, log.date)
            sites[site] = activity
        }
    }
}

/// 请求日志和访问统计单独存放：只有日志、统计区域订阅它，
/// 不会因为每个请求都让依赖 ServerManager 的文件页、设置页整页重绘。
@MainActor
final class RequestLogStore: ObservableObject {
    static let maxLogs = 200
    /// 多久之内有请求算作“活跃”
    static let activeWindow: TimeInterval = 600

    /// 最新的在前
    @Published private(set) var logs: [RequestLog] = []
    @Published private(set) var stats = TrafficStats()

    /// App 在后台时暂存，不触发界面更新
    private var pendingLogs: [RequestLog] = []
    private var hiddenStats: TrafficStats?

    /// App 在后台时只暂存、不触发界面更新，回到前台再一次性显示
    var isVisible = true {
        didSet {
            guard isVisible && !oldValue else { return }
            if let hiddenStats {
                stats = hiddenStats
                self.hiddenStats = nil
            }
            if !pendingLogs.isEmpty {
                logs = Array((Array(pendingLogs.reversed()) + logs).prefix(Self.maxLogs))
                pendingLogs = []
            }
        }
    }

    var totalRequests: Int { stats.totalRequests }
    var totalBytes: UInt64 { stats.totalBytes }

    /// 最近 10 分钟内访问过的设备数
    var activeClients: Int {
        let cutoff = Date().addingTimeInterval(-Self.activeWindow)
        return stats.clients.values.filter { $0.lastSeen > cutoff }.count
    }

    /// 按最近访问时间排列的设备
    var clientList: [ClientStats] {
        stats.clients.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func isActive(site: String) -> Bool {
        guard let activity = stats.sites[site] else { return false }
        return Date().timeIntervalSince(activity.lastAccess) < Self.activeWindow
    }

    /// batch 按时间先后排列
    func append(_ batch: [RequestLog]) {
        guard !batch.isEmpty else { return }
        if isVisible {
            var updated = stats
            batch.forEach { updated.apply($0) }
            stats = updated
            logs = Array((Array(batch.reversed()) + logs).prefix(Self.maxLogs))
        } else {
            var updated = hiddenStats ?? stats
            batch.forEach { updated.apply($0) }
            hiddenStats = updated
            pendingLogs.append(contentsOf: batch)
            if pendingLogs.count > Self.maxLogs {
                pendingLogs.removeFirst(pendingLogs.count - Self.maxLogs)
            }
        }
    }

    /// 记录一次被拦截的连接
    func recordBlocked(_ address: String) {
        if isVisible {
            stats.blockedAttempts[address, default: 0] += 1
        } else {
            var updated = hiddenStats ?? stats
            updated.blockedAttempts[address, default: 0] += 1
            hiddenStats = updated
        }
    }

    func clear() {
        logs.removeAll()
        stats = TrafficStats()
        pendingLogs.removeAll()
        hiddenStats = nil
    }
}

/// 线程安全的日志缓冲：服务器线程逐条写入，主线程定时批量取走，
/// 一个页面同时加载几十个资源时也只会触发一次界面更新。
final class LogBuffer: @unchecked Sendable {
    static let capacity = 2000

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
