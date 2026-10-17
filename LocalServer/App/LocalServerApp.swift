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
    var body: some View {
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
