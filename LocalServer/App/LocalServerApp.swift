import SwiftUI

@main
struct LocalServerApp: App {
    @StateObject private var server = ServerManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(server)
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
            .alert("导入完成", isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
    }

    private var tabs: some View {
        TabView {
            ServerView()
                .tabItem { Label("服务器", systemImage: "server.rack") }

            NavigationStack {
                FileBrowserView(directory: FileStore.rootURL)
                    .navigationDestination(for: URL.self) { url in
                        FileBrowserView(directory: url)
                    }
            }
            .tabItem { Label("文件", systemImage: "folder") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
