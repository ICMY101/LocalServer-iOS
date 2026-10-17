import Network
import SwiftUI
import UIKit

/// 界面与 HTTPServer 之间的桥梁：保存设置、维护运行状态、请求日志和局域网地址
@MainActor
final class ServerManager: ObservableObject {
    static let bonjourName = "本地服务器"

    @Published private(set) var state: HTTPServer.State = .stopped
    @Published private(set) var logs: [RequestLog] = []
    @Published private(set) var lanAddresses: [InterfaceAddress] = []
    /// 通过 Bonjour 解析到的 `.local` 主机名，例如 `iPhone.local`
    @Published private(set) var bonjourHost: String?
    /// 文件被修改时递增，文件列表据此刷新
    @Published private(set) var filesVersion = 0
    /// 其他 App 通过“用其他应用打开”传进来、等待导入的文件
    @Published var incomingURLs: [URL] = []
    @Published var settings: ServerSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    private let server: HTTPServer
    private let pathMonitor = NWPathMonitor()
    private let keepAlive = BackgroundKeepAlive()
    private let hostResolver = BonjourHostResolver()
    private var wantsRunning = false
    private var pendingImportMessage: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let maxLogs = 200

    init() {
        var settings = ServerSettings.load()
        if !Self.folderExists(settings.siteRoot) {
            settings.siteRoot = ""
        }
        self.settings = settings
        server = HTTPServer(rootURL: FileStore.rootURL, config: settings.routerConfig)

        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        server.onRequest = { [weak self] log in
            Task { @MainActor in self?.append(log) }
        }
        server.onFilesChanged = { [weak self] in
            Task { @MainActor in self?.notifyFilesChanged() }
        }
        server.onServiceRegistered = { [weak self] name in
            Task { @MainActor in self?.serviceRegistered(name) }
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

    var bonjourURL: URL? {
        bonjourHost.flatMap { URL(string: "http://\($0):\(port)/") }
    }

    // MARK: - 网站根目录

    var siteRootURL: URL {
        settings.siteRoot.isEmpty
            ? FileStore.rootURL
            : FileStore.rootURL.appendingPathComponent(settings.siteRoot, isDirectory: true)
    }

    var siteRootDisplay: String {
        settings.siteRoot.isEmpty ? "www" : "www/" + settings.siteRoot
    }

    func isSiteRoot(_ url: URL) -> Bool {
        FileStore.relativePath(of: url) == settings.siteRoot
    }

    /// 传入 nil 表示恢复为 www 本身
    func setSiteRoot(_ url: URL?) {
        settings.siteRoot = url.flatMap { FileStore.relativePath(of: $0) } ?? ""
    }

    /// 在 App 内预览某个文件时使用的地址；文件不在当前网站内时返回 nil
    func previewURL(for fileURL: URL) -> URL? {
        guard let path = FileStore.webPath(for: fileURL, siteRoot: siteRootURL) else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "http://127.0.0.1:\(port)\(encoded)")
    }

    func notifyFilesChanged() {
        filesVersion += 1
        if !Self.folderExists(settings.siteRoot) {
            settings.siteRoot = ""
        }
    }

    // MARK: - 控制

    func start() {
        wantsRunning = true
        startServer()
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
                startServer()
            }
        case .background:
            if wantsRunning && !keepAlive.isActive {
                beginBackgroundTask()
            }
        default:
            break
        }
    }

    // MARK: - 接收其他 App 传来的文件

    func receive(_ url: URL) {
        guard url.isFileURL, !incomingURLs.contains(url) else { return }
        incomingURLs.append(url)
    }

    func importIncoming(into directory: URL, extractZips: Bool) async {
        let urls = incomingURLs
        let summary = await Task.detached {
            FileStore.importItems(urls, into: directory, extractZips: extractZips)
        }.value
        FileStore.cleanUpInbox(urls)
        pendingImportMessage = summary.message
        incomingURLs.removeAll { urls.contains($0) }
        notifyFilesChanged()
    }

    /// 取出最近一次导入的结果，导入面板关闭后显示
    func takeImportMessage() -> String? {
        defer { pendingImportMessage = nil }
        return pendingImportMessage
    }

    func discardIncoming() {
        FileStore.cleanUpInbox(incomingURLs)
        incomingURLs = []
    }

    // MARK: - 私有

    private func startServer() {
        server.start(
            port: settings.port,
            localOnly: !settings.allowLAN,
            bonjourName: settings.bonjour ? Self.bonjourName : nil
        )
    }

    private func stateChanged(_ state: HTTPServer.State) {
        self.state = state
        if case .running = state { return }
        hostResolver.cancel()
        bonjourHost = nil
    }

    private func serviceRegistered(_ name: String?) {
        guard let name else {
            hostResolver.cancel()
            bonjourHost = nil
            return
        }
        hostResolver.resolve(serviceName: name) { [weak self] host in
            self?.bonjourHost = host
        }
    }

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
        let needsRestart = old.port != settings.port
            || old.allowLAN != settings.allowLAN
            || old.bonjour != settings.bonjour
        if wantsRunning && needsRestart {
            startServer()
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

    private static func folderExists(_ relativePath: String) -> Bool {
        if relativePath.isEmpty { return true }
        guard let url = PathResolver.resolve(relativePath, in: FileStore.rootURL) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
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
