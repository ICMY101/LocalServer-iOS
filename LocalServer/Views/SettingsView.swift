import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var server: ServerManager
    @State private var portText = ""
    @State private var portError: String?
    @State private var confirmRestore = false
    @FocusState private var portFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                header
                serviceSection
                computerSection
                siteSection
                powerSection
                aboutSection
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { portFocused = false }
                }
            }
            .onAppear { portText = String(server.settings.port) }
            .onChange(of: portFocused) { focused in
                if !focused { applyPort() }
            }
            .confirmationDialog("重新创建“示例站点”？会覆盖其中的 index.html。", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("覆盖", role: .destructive) {
                    try? FileStore.restoreWelcomePage()
                    server.notifyFilesChanged()
                }
            }
        }
    }

    // MARK: - 分组

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(.accentColor)
                    .frame(width: 58, height: 58)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地服务器")
                        .font(.title3.weight(.bold))
                    Text("版本 \(appVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var serviceSection: some View {
        Section {
            HStack {
                SettingsLabel("端口", systemName: "number")
                Spacer()
                TextField("8080", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($portFocused)
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: 110)
            }
            Toggle(isOn: $server.settings.allowLAN) {
                SettingsLabel("允许局域网访问", systemName: "wifi")
            }
            Toggle(isOn: $server.settings.bonjour) {
                SettingsLabel("固定地址（Bonjour）", systemName: "dot.radiowaves.left.and.right")
            }
            .disabled(!server.settings.allowLAN)
            Toggle(isOn: $server.settings.autoStart) {
                SettingsLabel("打开 App 时自动启动", systemName: "power")
            }
        } header: {
            Text("服务")
        } footer: {
            if let portError {
                Text(portError).foregroundColor(.red)
            } else {
                Text("端口范围 1024–65535。关闭局域网访问后，只有本机浏览器可以访问。Bonjour 会尽量解析出一个 IP 变化后仍可使用的 .local 地址，部分网络下可能解析不到。")
            }
        }
    }

    private var computerSection: some View {
        Section {
            Toggle(isOn: $server.settings.webAdmin) {
                SettingsLabel("电脑网页管理", systemName: "desktopcomputer")
            }
            Toggle(isOn: $server.settings.requirePairing) {
                SettingsLabel("需要配对码", systemName: "lock.shield.fill")
            }
            .disabled(!server.settings.webAdmin)
            NavigationLink {
                PairedDevicesView()
            } label: {
                HStack {
                    SettingsLabel("已配对设备", systemName: "laptopcomputer")
                    Spacer()
                    Text("\(server.pairedDevices.count)")
                        .foregroundColor(.secondary)
                }
            }
            .disabled(!server.settings.webAdmin || !server.settings.requirePairing)
            Toggle(isOn: $server.settings.autoExtractZip) {
                SettingsLabel("zip 自动解压", systemName: "doc.zipper")
            }
        } header: {
            Text("电脑管理")
        } footer: {
            Text(server.settings.requirePairing
                 ? "电脑浏览器打开 /__admin/ 时，手机上会弹出 6 位配对码，输入后即完成配对。每个浏览器只需配对一次。"
                 : "⚠️ 未开启配对：同一局域网中的任何人都能上传或删除你的文件，建议开启。")
        }
    }

    private var siteSection: some View {
        Section {
            Toggle(isOn: $server.settings.liveReload) {
                SettingsLabel("文件变化后自动刷新", systemName: "arrow.clockwise")
            }
            Toggle(isOn: $server.settings.directoryListing) {
                SettingsLabel("目录列表", systemName: "list.bullet.rectangle")
            }
            Toggle(isOn: $server.settings.spaFallback) {
                SettingsLabel("单页应用回退（SPA）", systemName: "arrow.triangle.branch")
            }
            Toggle(isOn: $server.settings.cors) {
                SettingsLabel("允许跨域（CORS）", systemName: "globe")
            }
            NavigationLink {
                SitesView()
            } label: {
                HStack {
                    SettingsLabel("站点", systemName: "square.stack.3d.up")
                    Spacer()
                    Text("\(server.sites.filter { server.isSiteEnabled($0.name) }.count) / \(server.sites.count) 已开启")
                        .foregroundColor(.secondary)
                }
            }
            NavigationLink {
                DevicesView()
            } label: {
                HStack {
                    SettingsLabel("访问设备", systemName: "person.2")
                    Spacer()
                    if !server.settings.blockedClients.isEmpty {
                        Text("已拉黑 \(server.settings.blockedClients.count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("站点")
        } footer: {
            Text("www 中的每个文件夹都是一个站点，通过 /文件夹名/ 访问，并以自己为根目录。\n自动刷新：上传或修改文件后，浏览器中打开的页面会自动重新加载。\n目录列表：文件夹中没有 index.html 时显示文件列表。\nSPA 回退：找不到的页面返回该站点的 index.html，适用于 Vue / React 的 history 路由。")
        }
    }

    private var powerSection: some View {
        Section {
            Toggle(isOn: $server.settings.backgroundAudio) {
                SettingsLabel("后台保活", systemName: "bolt.fill")
            }
            if server.settings.backgroundAudio {
                Picker(selection: $server.settings.keepAliveIdleMinutes) {
                    Text("5 分钟后").tag(5)
                    Text("15 分钟后").tag(15)
                    Text("30 分钟后").tag(30)
                    Text("1 小时后").tag(60)
                    Text("2 小时后").tag(120)
                    Text("从不").tag(0)
                } label: {
                    SettingsLabel("无访问时停止", systemName: "timer")
                }
            }
            Toggle(isOn: $server.settings.keepScreenOn) {
                SettingsLabel("保持屏幕常亮", systemName: "sun.max.fill")
            }
        } header: {
            Text("运行与电量")
        } footer: {
            Text("网页在系统浏览器中打开时，本 App 会进入后台。开启“后台保活”后，仅在服务运行且 App 位于后台时循环播放静音音频（不影响其他声音），让服务器持续运行；回到前台或停止服务时立即停止。设定时间内一直没有设备访问，也会自动停止以节省电量。")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                SettingsLabel("文件位置", systemName: "externaldrive.fill")
                Spacer()
                Text("我的 iPhone › 本地服务器 › www")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Button {
                confirmRestore = true
            } label: {
                SettingsLabel("恢复示例站点", systemName: "arrow.counterclockwise")
            }
            .foregroundColor(.primary)
        } header: {
            Text("其他")
        } footer: {
            Text("也可以在系统「文件」App 中直接管理网站文件。")
        }
    }

    // MARK: - 工具

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func applyPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(trimmed), port >= 1024 else {
            portError = "请输入 1024–65535 之间的端口号"
            portText = String(server.settings.port)
            return
        }
        portError = nil
        if port != server.settings.port {
            server.settings.port = port
        }
    }
}
