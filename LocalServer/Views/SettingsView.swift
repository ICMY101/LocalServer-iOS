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
                Section {
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("8080", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($portFocused)
                            .frame(maxWidth: 120)
                    }
                    Toggle("允许局域网访问", isOn: $server.settings.allowLAN)
                    Toggle("打开 App 时自动启动", isOn: $server.settings.autoStart)
                } header: {
                    Text("服务")
                } footer: {
                    if let portError {
                        Text(portError).foregroundColor(.red)
                    } else {
                        Text("端口范围 1024–65535。关闭局域网访问后，只有本机（App 内浏览器）可以访问。")
                    }
                }

                Section {
                    Toggle("目录列表", isOn: $server.settings.directoryListing)
                    Toggle("单页应用回退（SPA）", isOn: $server.settings.spaFallback)
                    Toggle("允许跨域（CORS）", isOn: $server.settings.cors)
                } header: {
                    Text("网站")
                } footer: {
                    Text("目录列表：文件夹中没有 index.html 时显示文件列表。\nSPA 回退：找不到的页面返回根目录的 index.html，适用于 Vue / React 等使用 history 路由的项目。")
                }

                Section {
                    Toggle("网页上传与管理", isOn: $server.settings.webAdmin)
                } header: {
                    Text("上传")
                } footer: {
                    Text("开启后，同一局域网中的任何人都能通过 /__admin/ 页面上传或删除文件。在公共 Wi-Fi 下建议关闭。")
                }

                Section {
                    Toggle("保持屏幕常亮", isOn: $server.settings.keepScreenOn)
                    Toggle("后台保活", isOn: $server.settings.backgroundAudio)
                } header: {
                    Text("运行")
                } footer: {
                    Text("iOS 会在 App 进入后台约 30 秒后挂起服务器。开启“后台保活”后会循环播放一段静音音频，让服务器在后台持续运行，但会增加耗电。")
                }

                Section {
                    LabeledContent("位置", value: "文件 › 我的 iPhone › 本地服务器 › www")
                    Button("恢复示例首页") { confirmRestore = true }
                } header: {
                    Text("网站根目录")
                } footer: {
                    Text("也可以在系统「文件」App 中直接管理网站文件。")
                }

                Section {
                    LabeledContent("版本", value: appVersion)
                }
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
            .confirmationDialog("用示例页面覆盖根目录的 index.html？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("覆盖", role: .destructive) {
                    try? FileStore.restoreWelcomePage()
                }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func applyPort() {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port >= 1024 else {
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
