import SwiftUI

/// 其他 App 传来文件时，选择保存位置和是否解压
struct IncomingFilesSheet: View {
    @EnvironmentObject private var server: ServerManager
    @State private var folders: [String] = [""]
    @State private var destination = ""
    @State private var extractZips = true
    @State private var isImporting = false

    private var hasZip: Bool {
        server.incomingURLs.contains { $0.pathExtension.lowercased() == "zip" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("收到的文件") {
                    ForEach(server.incomingURLs, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: url.pathExtension.lowercased() == "zip" ? "doc.zipper" : "doc")
                            .lineLimit(2)
                    }
                }

                Section {
                    Picker("保存到", selection: $destination) {
                        ForEach(folders, id: \.self) { folder in
                            Text(folder.isEmpty ? "www（根目录）" : "www/" + folder).tag(folder)
                        }
                    }
                    if hasZip {
                        Toggle("解压 zip", isOn: $extractZips)
                    }
                } footer: {
                    Text(hasZip && extractZips
                         ? "zip 会解压到所选文件夹中，同名文件会被覆盖。"
                         : "同名文件会被覆盖。")
                }
            }
            .navigationTitle("导入文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { server.discardIncoming() }
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isImporting {
                        ProgressView()
                    } else {
                        Button("导入") { performImport() }
                            .disabled(server.incomingURLs.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(isImporting)
        }
        .onAppear {
            folders = FileStore.allFolders()
            extractZips = server.settings.autoExtractZip
            if folders.contains(server.settings.siteRoot) {
                destination = server.settings.siteRoot
            }
        }
    }

    private func performImport() {
        guard let directory = destination.isEmpty
            ? FileStore.rootURL
            : PathResolver.resolve(destination, in: FileStore.rootURL) else { return }
        isImporting = true
        Task {
            // 导入完成后 incomingURLs 被清空，面板自动关闭，结果由 ContentView 显示
            await server.importIncoming(into: directory, extractZips: extractZips)
            isImporting = false
        }
    }
}
