import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var server: ServerManager
    @State private var portText = ""
    @State private var portError: String?
    @State private var passwordText = ""
    @State private var confirmRestore = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case port
        case password
    }

    var body: some View {
        NavigationStack {
            Form {
                serviceSection
                siteSection
                uploadSection
                runtimeSection
                rootSection

                Section {
                    LabeledContent("版本", value: appVersion)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .onAppear {
                portText = String(server.settings.port)
                passwordText = server.settings.adminPassword
            }
            .onChange(of: focusedField) { field in
                if field != .port { applyPort() }
                if field != .password { applyPassword() }
            }
            .onChange(of: server.settings.adminPassword) { password in
                if focusedField != .password { passwordText = password }
            }
            .confirmationDialog("用示例页面覆盖 www 中的 index.html？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("覆盖", role: .destructive) {
                    try? FileStore.restoreWelcomePage()
                    server.notifyFilesChanged()
                }
            }
        }
    }

    // MARK: - 分组

    private var serviceSection: some View {
        Section {
            HStack {
                Text("端口")
                Spacer()
                TextField("8080", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .port)
                    .frame(maxWidth: 120)
            }
            Toggle("允许局域网访问", isOn: $server.settings.allowLAN)
            Toggle("Bonjour 固定地址（.local）", isOn: $server.settings.bonjour)
                .disabled(!server.settings.allowLAN)
            Toggle("打开 App 时自动启动", isOn: $server.settings.autoStart)
        } header: {
            Text("服务")
        } footer: {
            if let portError {
                Text(portError).foregroundColor(.red)
            } else {
                Text("端口范围 1024–65535。关闭局域网访问后，只有本机（App 内浏览器）可以访问。Bonjour 会在局域网中广播服务，并尽量解析出一个 IP 变化后仍可使用的 .local 地址；部分网络或系统版本下可能解析不到。")
            }
        }
    }

    private var siteSection: some View {
        Section {
            Toggle("文件变化后自动刷新页面", isOn: $server.settings.liveReload)
            Toggle("目录列表", isOn: $server.settings.directoryListing)
            Toggle("单页应用回退（SPA）", isOn: $server.settings.spaFallback)
            Toggle("允许跨域（CORS）", isOn: $server.settings.cors)
        } header: {
            Text("网站")
        } footer: {
            Text("自动刷新：上传或修改文件后，正在浏览的页面会自动重新加载（会在 HTML 中插入一小段脚本）。\n目录列表：文件夹中没有 index.html 时显示文件列表。\nSPA 回退：找不到的页面返回根目录的 index.html，适用于 Vue / React 等使用 history 路由的项目。")
        }
    }

    private var uploadSection: some View {
        Section {
            Toggle("网页上传与管理", isOn: $server.settings.webAdmin)
            HStack {
                Text("访问密码")
                Spacer()
                TextField("未设置", text: $passwordText)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
                    .submitLabel(.done)
                    .onSubmit { applyPassword() }
                    .font(.system(.body, design: .monospaced))
            }
            .disabled(!server.settings.webAdmin)
            HStack {
                Button("随机生成") {
                    focusedField = nil
                    passwordText = ServerSettings.randomPassword()
                    applyPassword()
                }
                Spacer()
                if !server.settings.adminPassword.isEmpty {
                    Button("取消密码", role: .destructive) {
                        focusedField = nil
                        passwordText = ""
                        applyPassword()
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(!server.settings.webAdmin)
            Toggle("导入 zip 时自动解压", isOn: $server.settings.autoExtractZip)
        } header: {
            Text("上传")
        } footer: {
            Text(server.settings.adminPassword.isEmpty
                 ? "⚠️ 未设置访问密码：同一局域网中的任何人都能通过 /__admin/ 页面上传或删除文件。建议设置密码，公共 Wi-Fi 下建议关闭网页上传。"
                 : "电脑浏览器打开 /__admin/ 时需要输入该密码。修改密码后，已登录的浏览器需要重新输入；连续输错 5 次会锁定 1 分钟。")
        }
    }

    private var runtimeSection: some View {
        Section {
            Toggle("保持屏幕常亮", isOn: $server.settings.keepScreenOn)
            Toggle("后台保活", isOn: $server.settings.backgroundAudio)
        } header: {
            Text("运行")
        } footer: {
            Text("iOS 会在 App 进入后台约 30 秒后挂起服务器。开启“后台保活”后会循环播放一段静音音频，让服务器在后台持续运行，但会增加耗电。")
        }
    }

    private var rootSection: some View {
        Section {
            LabeledContent("当前网站", value: server.siteRootDisplay)
            if !server.settings.siteRoot.isEmpty {
                Button("恢复以 www 为网站根目录") { server.setSiteRoot(nil) }
            }
            Button("恢复示例首页") { confirmRestore = true }
        } header: {
            Text("网站根目录")
        } footer: {
            Text("在“文件”页长按某个文件夹，选择“设为网站根目录”，就能在多个网站之间切换。网站文件也可以在系统「文件」App 的 我的 iPhone › 本地服务器 › www 中管理。")
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

    private func applyPassword() {
        let password = passwordText.trimmingCharacters(in: .whitespacesAndNewlines)
        passwordText = password
        if password != server.settings.adminPassword {
            server.settings.adminPassword = password
        }
    }
}
