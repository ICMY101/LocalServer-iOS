import SwiftUI

@main
struct LocalServerApp: App {
    @StateObject private var server = ServerManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(server)
                .tint(.accentColor)
        }
        .onChange(of: scenePhase) { phase in
            server.handleScenePhase(phase)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var server: ServerManager
    @State private var importMessage: String?

    var body: some View {
        tabs
            .overlay(alignment: .bottom) {
                if let toast = server.toast {
                    ToastView(toast: toast)
                        .padding(.bottom, 70)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            // 在微信等 App 中选择“用其他应用打开 › 本地服务器”时触发
            .onOpenURL { url in
                server.receive(url)
            }
            .sheet(isPresented: Binding(
                get: { !server.incomingURLs.isEmpty },
                set: { if !$0 { server.discardIncoming() } }
            ), onDismiss: {
                importMessage = server.takeImportMessage()
            }) {
                IncomingFilesSheet()
            }
            // 电脑浏览器请求配对时弹出配对码
            .sheet(item: $server.pairingRequest) { request in
                PairingSheet(request: request)
            }
            .alert("导入完成", isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
            .alert("后台保活已关闭", isPresented: Binding(
                get: { server.pendingBrowserURL != nil },
                set: { if !$0 { server.pendingBrowserURL = nil } }
            )) {
                Button("开启保活并打开") { server.confirmBrowserOpen(enableKeepAlive: true) }
                Button("仍然打开") { server.confirmBrowserOpen(enableKeepAlive: false) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("切换到浏览器后，本 App 会进入后台，约 30 秒后服务器会被系统暂停，页面将无法继续加载。开启后台保活可以避免这个问题。")
            }
    }

    private var tabs: some View {
        TabView {
            DashboardView()
                .tabItem { Label("服务", systemImage: "antenna.radiowaves.left.and.right") }

            NavigationStack {
                FileBrowserView(directory: FileStore.rootURL)
                    .navigationDestination(for: URL.self) { url in
                        FileBrowserView(directory: url)
                    }
            }
            .tabItem { Label("文件", systemImage: "folder.fill") }

            VNLibraryView()
                .tabItem { Label("游戏", systemImage: "text.book.closed.fill") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}
