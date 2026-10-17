import SwiftUI

/// 选择移动或拷贝的目标文件夹
struct FolderPickerSheet: View {
    let request: TransferRequest
    let onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String] = []
    @State private var selected: String?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var errorMessage: String?

    /// 被移动或拷贝的项目相对 www 的路径
    private var sourcePaths: [String] {
        request.urls.compactMap { FileStore.relativePath(of: $0) }
    }

    /// 不能放到自身或其子文件夹中；移动到当前所在的文件夹也没有意义
    private func isBlocked(_ path: String) -> Bool {
        for source in sourcePaths where !source.isEmpty {
            if path == source || path.hasPrefix(source + "/") {
                return true
            }
        }
        if !request.copy {
            let parents = Set(sourcePaths.map { ($0 as NSString).deletingLastPathComponent })
            if parents == [path] {
                return true
            }
        }
        return false
    }

    private func url(of path: String) -> URL {
        path.isEmpty ? FileStore.rootURL : FileStore.rootURL.appendingPathComponent(path, isDirectory: true)
    }

    private var title: String {
        let action = request.copy ? "拷贝" : "移动"
        return request.urls.count == 1 ? "\(action)「\(request.urls[0].lastPathComponent)」" : "\(action) \(request.urls.count) 项"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(folders, id: \.self) { path in
                        folderRow(path)
                    }
                } footer: {
                    Text(request.copy ? "目标文件夹中已有同名项目时，会保留两者并自动改名。" : "目标文件夹中已有同名项目时，会保留两者并自动改名。站点的开启状态会随文件夹一起移动。")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.copy ? "拷贝" : "移动") {
                        if let selected {
                            onPick(url(of: selected))
                        }
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                }
            }
            .alert("新建文件夹", isPresented: $showNewFolder) {
                TextField("名称", text: $newFolderName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("创建") { createFolder() }
            } message: {
                Text("创建在「\(displayName(selected ?? ""))」中")
            }
            .alert("无法创建", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { reload() }
        }
    }

    private func folderRow(_ path: String) -> some View {
        let blocked = isBlocked(path)
        let depth = path.isEmpty ? 0 : path.split(separator: "/").count
        return Button {
            selected = path
        } label: {
            HStack(spacing: 10) {
                Image(systemName: path.isEmpty ? "externaldrive" : "folder")
                    .foregroundColor(blocked ? .secondary : .accentColor)
                Text(displayName(path))
                    .foregroundColor(blocked ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                if selected == path {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.leading, CGFloat(depth) * 18)
        }
        .disabled(blocked)
    }

    private func displayName(_ path: String) -> String {
        path.isEmpty ? "www" : (path as NSString).lastPathComponent
    }

    private func reload() {
        folders = FileStore.allFolders(maxDepth: 8)
    }

    private func createFolder() {
        let parent = selected ?? ""
        do {
            try FileStore.createFolder(named: newFolderName, in: url(of: parent))
            reload()
            let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            selected = parent.isEmpty ? name : parent + "/" + name
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 文件或文件夹的简介：类型、大小、位置、访问地址，站点还可以直接开关
struct FileInfoSheet: View {
    let item: FileItem

    @EnvironmentObject private var server: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var measured: (bytes: Int64, files: Int, folders: Int)?

    private var kind: FileKind { FileKind.of(item) }

    private var location: String {
        let parent = FileStore.relativePath(of: item.url.deletingLastPathComponent()) ?? ""
        return parent.isEmpty ? "www" : "www/" + parent
    }

    private var isSite: Bool {
        FileStore.isSiteFolder(item.url)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        IconBadge(systemName: isSite ? "globe" : kind.symbol, color: item.isDirectory ? .accentColor : .secondary, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.headline)
                                .lineLimit(2)
                            Text(isSite ? "站点" : kind.label)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    LabeledContent("大小", value: measured.map { Format.bytes($0.bytes) } ?? "正在计算…")
                    if item.isDirectory {
                        LabeledContent("包含", value: measured.map { "\($0.files) 个文件，\($0.folders) 个文件夹" } ?? "正在计算…")
                    }
                    if let modified = item.modified {
                        LabeledContent("修改时间", value: modified.formatted(date: .long, time: .shortened))
                    }
                    LabeledContent("位置", value: location)
                }

                if let url = server.webURL(for: item.url) {
                    Section("访问地址") {
                        Text(url.absoluteString + (item.isDirectory ? "/" : ""))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = url.absoluteString + (item.isDirectory ? "/" : "")
                            server.showToast("已复制链接", systemName: "link")
                        } label: {
                            Label("复制链接", systemImage: "link")
                        }
                        Button {
                            dismiss()
                            let target = item.isDirectory ? URL(string: url.absoluteString + "/") ?? url : url
                            server.openInBrowser(target)
                        } label: {
                            Label("在浏览器中打开", systemImage: "safari")
                        }
                    }
                }

                if isSite {
                    Section {
                        Toggle("开启站点", isOn: Binding(
                            get: { server.isSiteEnabled(item.name) },
                            set: { server.setSite(item.name, enabled: $0) }
                        ))
                    } footer: {
                        Text("关闭后，这个站点无法访问，也不会出现在站点列表中。重命名或移动文件夹不会改变开启状态。")
                    }
                }
            }
            .navigationTitle("简介")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            let url = item.url
            let result = await Task.detached { FileStore.measure(url) }.value
            measured = result
        }
    }
}
