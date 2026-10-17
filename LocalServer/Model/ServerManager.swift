import Network
import SwiftUI
import UIKit
import UserNotifications

/// 当前配对码及其过期时间
struct PairingCode: Equatable {
    let pin: String
    let expires: Date
}

/// 界面与 HTTPServer 之间的桥梁：保存设置、维护运行状态、局域网地址和后台保活
@MainActor
final class ServerManager: ObservableObject {
    static let bonjourName = "本地服务器"

    @Published private(set) var state: HTTPServer.State = .stopped
    @Published private(set) var lanAddresses: [InterfaceAddress] = []
    /// 通过 Bonjour 解析到的 `.local` 主机名，例如 `iPhone.local`
    @Published private(set) var bonjourHost: String?
    /// 文件被修改时递增，文件列表据此刷新
    @Published private(set) var filesVersion = 0
    /// 其他 App 通过“用其他应用打开”传进来、等待导入的文件
    @Published var incomingURLs: [URL] = []
    /// 服务器开始运行的时间，用于显示运行时长
    @Published private(set) var runningSince: Date?
    /// 当前配对码
    @Published private(set) var pairingCode = PairingCode(pin: "", expires: .distantPast)
    /// 已配对的电脑和浏览器
    @Published private(set) var pairedDevices: [PairedDevice] = []
    /// 有浏览器正在请求配对时不为空，界面据此弹出配对码
    @Published var pairingRequest: PairingRequest?
    /// 配对请求完成配对的时刻，配对弹窗据此显示成功动画
    @Published private(set) var lastPairedAt: Date?
    /// 后台保活关闭时打开浏览器前的提示，不为空时显示
    @Published var pendingBrowserURL: URL?
    @Published var settings: ServerSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    /// 请求日志单独存放，不放在 @Published 属性里，避免每个请求都触发整页重绘
    let logStore = RequestLogStore()

    private let server: HTTPServer
    private let logBuffer = LogBuffer()
    private let pathMonitor = NWPathMonitor()
    private let keepAlive = BackgroundKeepAlive()
    private let hostResolver = BonjourHostResolver()
    private var wantsRunning = false
    private var isInBackground = false
    /// 少数情况下系统不允许在后台开始播放，此时退化为在前台就开始播放
    private var keepAliveStartsInForeground = false
    private var idleTimer: Timer?
    /// 最近一次注册成功的 Bonjour 服务名，用于回到前台后重新解析主机名
    private var serviceName: String?
    private var pendingImportMessage: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        var settings = ServerSettings.load()
        if !Self.folderExists(settings.siteRoot) {
            settings.siteRoot = ""
        }
        self.settings = settings
        server = HTTPServer(
            rootURL: FileStore.rootURL,
            config: settings.routerConfig,
            pairing: PairingStore(fileURL: PairingStore.defaultFileURL)
        )

        let logBuffer = self.logBuffer
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        server.onRequest = { [weak self] log in
            // 每 0.3 秒最多刷新一次界面，而不是每个请求刷新一次
            guard logBuffer.add(log) else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.flushLogs()
            }
        }
        server.onFilesChanged = { [weak self] in
            Task { @MainActor in self?.filesChangedByServer() }
        }
        server.pairing.onChange = { [weak self] in
            Task { @MainActor in self?.refreshPairing() }
        }
        server.pairing.onPairingRequest = { [weak self] request in
            Task { @MainActor in self?.receivePairingRequest(request) }
        }
        server.onServiceRegistered = { [weak self] name in
            Task { @MainActor in self?.serviceRegistered(name) }
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshAddresses() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "LocalServer.path-monitor"))

        refreshAddresses()
        refreshPairing()
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

    /// 文件在本机浏览器中的访问地址；文件不在当前网站内时返回 nil
    func webURL(for fileURL: URL) -> URL? {
        guard let path = FileStore.webPath(for: fileURL, siteRoot: siteRootURL) else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "http://127.0.0.1:\(port)\(encoded)")
    }

    /// App 内修改了文件：刷新文件列表，并让正在等待的 Live Reload 页面立即刷新
    func notifyFilesChanged() {
        server.notifyFilesChanged()
        filesChangedByServer()
    }

    private func filesChangedByServer() {
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
        logStore.clear()
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
            isInBackground = false
            logStore.isVisible = true
            stopIdleTimer()
            endBackgroundTask()
            // 前台不需要保活，立即停止静音播放以节省电量
            if !(keepAliveStartsInForeground && settings.backgroundAudio && wantsRunning) {
                keepAlive.stop()
            }
            refreshAddresses()
            if bonjourHost == nil, isRunning, let serviceName {
                resolveHost(serviceName)
            }
            // 在后台被系统挂起后，监听端口可能已失效，回到前台时自动恢复
            if wantsRunning && !isRunning && !isBusy {
                startServer()
            }
        case .background:
            isInBackground = true
            logStore.isVisible = false
            guard wantsRunning else { break }
            server.markActivity()
            // 先申请一小段后台时间，确保有机会启动保活；没开保活时也能多服务约 30 秒
            beginBackgroundTask()
            if settings.backgroundAudio {
                if keepAlive.start() {
                    startIdleTimer()
                    endBackgroundTask()
                } else {
                    keepAliveStartsInForeground = true
                }
            }
        default:
            break
        }
    }

    // MARK: - 在浏览器中打开

    private static let keepAliveHintKey = "KeepAliveHintShown"

    /// 用系统浏览器打开网址。服务器未运行时先启动；后台保活关闭时先提示一次
    func openInBrowser(_ url: URL) {
        if !settings.backgroundAudio && !UserDefaults.standard.bool(forKey: Self.keepAliveHintKey) {
            pendingBrowserURL = url
            return
        }
        launchBrowser(url)
    }

    /// 处理“后台保活已关闭”提示的选择
    func confirmBrowserOpen(enableKeepAlive: Bool) {
        UserDefaults.standard.set(true, forKey: Self.keepAliveHintKey)
        if enableKeepAlive {
            settings.backgroundAudio = true
        }
        if let url = pendingBrowserURL {
            pendingBrowserURL = nil
            launchBrowser(url)
        }
    }

    private func launchBrowser(_ url: URL) {
        Task {
            if !isRunning {
                start()
                // 最多等 3 秒，让服务器开始监听
                for _ in 0..<30 where !isRunning {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            _ = await UIApplication.shared.open(url)
        }
    }

    // MARK: - 配对

    /// 更换配对码（也用于配对码过期后刷新显示）
    func regeneratePIN() {
        server.pairing.regeneratePIN()
    }

    /// 配对码过期时调用，取回自动生成的新配对码
    func refreshPairing() {
        let current = server.pairing.currentPIN()
        let code = PairingCode(pin: current.pin, expires: current.expires)
        if code != pairingCode {
            pairingCode = code
        }
        let devices = server.pairing.pairedDevices
        if devices.count > pairedDevices.count, pairingRequest != nil {
            // 正在显示配对码时有新设备完成配对
            lastPairedAt = Date()
        }
        if devices != pairedDevices {
            pairedDevices = devices
        }
    }

    func revoke(_ device: PairedDevice) {
        server.pairing.revoke(id: device.id)
    }

    func revokeAllDevices() {
        server.pairing.revokeAll()
    }

    private func receivePairingRequest(_ request: PairingRequest) {
        refreshPairing()
        if isInBackground {
            notifyPairingRequest(request)
        } else {
            pairingRequest = request
            requestNotificationPermissionIfNeeded()
        }
    }

    /// App 在后台时用通知提醒用户回到 App 查看配对码（通知中不显示配对码本身）
    private func notifyPairingRequest(_ request: PairingRequest) {
        let content = UNMutableNotificationContent()
        content.title = "\(request.deviceName) 请求配对"
        content.body = "打开「本地服务器」查看配对码（来自 \(request.address)）"
        content.sound = .default
        let notification = UNNotificationRequest(identifier: "pairing", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(notification)
        // 回到前台时显示配对码
        pairingRequest = request
    }

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - 接收其他 App 传来的文件

    func receive(_ url: URL) {
        guard url.isFileURL, !incomingURLs.contains(url) else { return }
        incomingURLs.append(url)
    }

    func importIncoming(into directory: URL, extractZips: Bool, newFolderName: String?) async {
        let urls = incomingURLs
        let summary = await Task.detached {
            FileStore.importItems(urls, into: directory, extractZips: extractZips, newFolderName: newFolderName)
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
        if case .running = state {
            if runningSince == nil { runningSince = Date() }
            return
        }
        runningSince = nil
        hostResolver.cancel()
        bonjourHost = nil
    }

    private func serviceRegistered(_ name: String?) {
        serviceName = name
        guard let name else {
            hostResolver.cancel()
            bonjourHost = nil
            return
        }
        // 后台时不做解析，回到前台再解析
        guard !isInBackground else { return }
        resolveHost(name)
    }

    private func resolveHost(_ name: String) {
        hostResolver.resolve(serviceName: name) { [weak self] host in
            self?.bonjourHost = host
        }
    }

    private func flushLogs() {
        logStore.append(logBuffer.drain())
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
        if old.keepAliveIdleMinutes != settings.keepAliveIdleMinutes && idleTimer != nil {
            startIdleTimer()
        }
        applyDeviceSettings()
    }

    private func applyDeviceSettings() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        if !settings.backgroundAudio || !wantsRunning {
            keepAlive.stop()
            stopIdleTimer()
            keepAliveStartsInForeground = false
        } else if keepAliveStartsInForeground && !isInBackground {
            keepAlive.start()
        }
    }

    // MARK: - 空闲检测

    /// 后台保活期间每分钟检查一次，长时间没有请求就停止保活，让系统挂起 App 以节省电量
    private func startIdleTimer() {
        stopIdleTimer()
        guard settings.keepAliveIdleMinutes > 0 else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
        // 允许系统推迟最多 30 秒，与其他唤醒合并
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func checkIdle() {
        guard isInBackground, settings.keepAliveIdleMinutes > 0 else { return }
        let idle = Date().timeIntervalSince(server.lastActivity)
        if idle >= TimeInterval(settings.keepAliveIdleMinutes * 60) {
            // 停止后系统很快会挂起 App；回到前台时服务器会自动恢复
            stopIdleTimer()
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
