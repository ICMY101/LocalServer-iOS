import SwiftUI

/// 其他 App 传来文件时，选择保存位置、是否解压、是否放进新文件夹
struct IncomingFilesSheet: View {
    @EnvironmentObject private var server: ServerManager
    @State private var folders: [String] = [""]
    @State private var destination = ""
    @State private var extractZips = true
    @State private var useNewFolder = false
    @State private var newFolderName = ""
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
                    Toggle("放进新文件夹", isOn: $useNewFolder)
                    if useNewFolder {
                        TextField("文件夹名称", text: $newFolderName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if hasZip {
                        Toggle("解压 zip", isOn: $extractZips)
                    }
                } footer: {
                    Text(footer)
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
            // www 根目录下的文件夹才是站点，普通文件默认放进新文件夹（即新建一个站点）
            let looseFiles = server.incomingURLs.filter { $0.pathExtension.lowercased() != "zip" }
            useNewFolder = !looseFiles.isEmpty
            newFolderName = FileStore.defaultFolderName(for: server.incomingURLs)
        }
    }

    private var footer: String {
        var lines: [String] = []
        if hasZip && extractZips {
            lines.append("zip 会解压到以其文件名命名的文件夹中；如果 zip 里本身只有一个文件夹，就直接使用它。")
        }
        if destination.isEmpty {
            lines.append("www 根目录下的每个文件夹都是一个站点，可以通过 /文件夹名/ 访问。")
        }
        lines.append("同名文件会被覆盖。")
        return lines.joined(separator: "\n")
    }

    private func performImport() {
        guard let directory = destination.isEmpty
            ? FileStore.rootURL
            : PathResolver.resolve(destination, in: FileStore.rootURL) else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        isImporting = true
        Task {
            // 导入完成后 incomingURLs 被清空，面板自动关闭，结果由 ContentView 显示
            await server.importIncoming(
                into: directory,
                extractZips: extractZips,
                newFolderName: useNewFolder && !name.isEmpty ? name : nil
            )
            isImporting = false
        }
    }
}
