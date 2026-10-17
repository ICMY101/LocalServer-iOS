import Network
import SwiftUI
import UIKit

/// 界面与 HTTPServer 之间的桥梁：保存设置、维护运行状态、请求日志和局域网地址
@MainActor
final class ServerManager: ObservableObject {
    @Published private(set) var state: HTTPServer.State = .stopped
    @Published private(set) var logs: [RequestLog] = []
    @Published private(set) var lanAddresses: [InterfaceAddress] = []
    /// 通过网页上传等方式修改了文件时递增，文件列表据此刷新
    @Published private(set) var filesVersion = 0
    @Published var settings: ServerSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    private let server: HTTPServer
    private let pathMonitor = NWPathMonitor()
    private let keepAlive = BackgroundKeepAlive()
    private var wantsRunning = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let maxLogs = 200

    init() {
        let settings = ServerSettings.load()
        self.settings = settings
        server = HTTPServer(rootURL: FileStore.rootURL, config: settings.routerConfig)

        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.state = state }
        }
        server.onRequest = { [weak self] log in
            Task { @MainActor in self?.append(log) }
        }
        server.onFilesChanged = { [weak self] in
            Task { @MainActor in self?.filesVersion += 1 }
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshAddresses() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "LocalServer.path-monitor"))

        refreshAddresses()
        if settings.autoStart {
            start()
        }
        applyDeviceSettings()
    }

    // MARK: - 状态

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isBusy: Bool {
        state == .starting
    }

    var port: UInt16 {
        if case .running(let port) = state { return port }
        return settings.port
    }

    var localURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    func lanURL(for address: InterfaceAddress) -> URL {
        URL(string: "http://\(address.ip):\(port)/")!
    }

    func adminURL(for address: InterfaceAddress) -> URL {
        URL(string: "http://\(address.ip):\(port)\(AdminAPI.prefix)/")!
    }

    /// 在 App 内预览某个文件时使用的地址
    func previewURL(for fileURL: URL) -> URL {
        let path = FileStore.webPath(for: fileURL)
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "http://127.0.0.1:\(port)\(encoded)") ?? localURL
    }

    // MARK: - 控制

    func start() {
        wantsRunning = true
        server.start(port: settings.port, localOnly: !settings.allowLAN)
        applyDeviceSettings()
    }

    func stop() {
        wantsRunning = false
        server.stop()
        applyDeviceSettings()
    }

    func toggle() {
        if isRunning || isBusy {
            stop()
        } else {
            start()
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func refreshAddresses() {
        let addresses = NetworkInfo.lanAddresses()
        if addresses != lanAddresses {
            lanAddresses = addresses
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundTask()
            refreshAddresses()
            // 在后台被系统挂起后，监听端口可能已失效，回到前台时自动恢复
            if wantsRunning && !isRunning && !isBusy {
                server.start(port: settings.port, localOnly: !settings.allowLAN)
            }
        case .background:
            if wantsRunning && !keepAlive.isActive {
                beginBackgroundTask()
            }
        default:
            break
        }
    }

    // MARK: - 私有

    private func append(_ log: RequestLog) {
        logs.insert(log, at: 0)
        if logs.count > Self.maxLogs {
            logs.removeLast(logs.count - Self.maxLogs)
        }
    }

    private func settingsChanged(from old: ServerSettings) {
        guard settings != old else { return }
        settings.save()
        server.updateConfig(settings.routerConfig)
        if wantsRunning && (old.port != settings.port || old.allowLAN != settings.allowLAN) {
            server.start(port: settings.port, localOnly: !settings.allowLAN)
        }
        applyDeviceSettings()
    }

    private func applyDeviceSettings() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        if settings.backgroundAudio && wantsRunning {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
    }

    /// 进入后台后向系统申请一小段额外运行时间（通常约 30 秒）
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "HTTPServer") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
