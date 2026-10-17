import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    let directory: URL

    @EnvironmentObject private var server: ServerManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var items: [FileItem] = []
    @State private var showImporter = false
    @State private var importTypes: [UTType] = [.item]
    @State private var nameAction: NameAction?
    @State private var nameText = ""
    @State private var deleteTarget: FileItem?
    @State private var browserTarget: BrowserTarget?
    @State private var editingItem: FileItem?
    @State private var message: String?
    @State private var isWorking = false

    private enum NameAction {
        case newFolder
        case newFile
        case rename(FileItem)

        var title: String {
            switch self {
            case .newFolder: return "新建文件夹"
            case .newFile: return "新建文件"
            case .rename: return "重命名"
            }
        }
    }

    private var isRoot: Bool {
        directory.standardizedFileURL.path == FileStore.rootURL.standardizedFileURL.path
    }

    var body: some View {
        List {
            ForEach(items) { item in
                row(for: item)
            }
        }
        .overlay {
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("空文件夹")
                        .font(.headline)
                    Text("点击右上角 + 导入 HTML、CSS、JS、图片等文件")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .overlay {
            if isWorking {
                ProgressView("正在处理…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .disabled(isWorking)
        .navigationTitle(isRoot ? "网站文件" : directory.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addMenu
            }
            if isRoot {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        preview(url: server.siteRootURL, isDirectory: true)
                    } label: {
                        Label("预览网站", systemImage: "play.circle")
                    }
                }
            }
        }
        .refreshable { await reload() }
        .onAppear { reload() }
        .onChange(of: server.filesVersion) { _ in reload() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { reload() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .alert(nameAction?.title ?? "", isPresented: Binding(
            get: { nameAction != nil },
            set: { if !$0 { nameAction = nil } }
        )) {
            TextField("名称", text: $nameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) {}
            Button("确定") { commitName() }
        } message: {
            if case .newFile? = nameAction {
                Text("未写扩展名时默认为 .html")
            }
        }
        .confirmationDialog(
            "删除「\(deleteTarget?.name ?? "")」？",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = deleteTarget { perform { try FileStore.delete(item) } }
            }
        } message: {
            if deleteTarget?.isDirectory == true {
                Text("文件夹中的所有内容都会被删除，且无法恢复。")
            } else {
                Text("此操作无法撤销。")
            }
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .fullScreenCover(item: $browserTarget) { target in
            BrowserView(target: target)
        }
        .sheet(item: $editingItem, onDismiss: reload) { item in
            TextFileEditor(url: item.url)
        }
    }

    // MARK: - 视图

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        Group {
            if item.isDirectory {
                NavigationLink(value: item.url) {
                    FileRow(item: item, isSiteRoot: server.isSiteRoot(item.url))
                }
            } else {
                Button {
                    open(item)
                } label: {
                    FileRow(item: item, isSiteRoot: false)
                }
                .foregroundColor(.primary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteTarget = item
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                nameText = item.name
                nameAction = .rename(item)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                preview(url: item.url, isDirectory: item.isDirectory)
            } label: {
                Label("在浏览器中预览", systemImage: "safari")
            }
            if item.isTextFile {
                Button {
                    editingItem = item
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
            }
            if item.isZip {
                Button {
                    extract(item)
                } label: {
                    Label("解压到此处", systemImage: "archivebox")
                }
            }
            if item.isDirectory {
                if server.isSiteRoot(item.url) {
                    Button {
                        server.setSiteRoot(nil)
                    } label: {
                        Label("恢复以 www 为网站根目录", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        server.setSiteRoot(item.url)
                    } label: {
                        Label("设为网站根目录", systemImage: "globe")
                    }
                }
            }
            if let link = server.previewURL(for: item.url) {
                Button {
                    UIPasteboard.general.string = link.absoluteString
                } label: {
                    Label("复制链接", systemImage: "link")
                }
            }
            if !item.isDirectory {
                ShareLink(item: item.url) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                nameText = item.name
                nameAction = .rename(item)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = item
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                importTypes = [.item]
                showImporter = true
            } label: {
                Label("导入文件", systemImage: "doc.badge.plus")
            }
            Button {
                importTypes = [.folder]
                showImporter = true
            } label: {
                Label("导入文件夹", systemImage: "folder.badge.plus")
            }
            Divider()
            Button {
                nameText = ""
                nameAction = .newFolder
            } label: {
                Label("新建文件夹", systemImage: "folder")
            }
            Button {
                nameText = "index.html"
                nameAction = .newFile
            } label: {
                Label("新建 HTML 文件", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    // MARK: - 操作

    private func reload() {
        items = FileStore.contents(of: directory)
    }

    private func open(_ item: FileItem) {
        if item.isTextFile && !item.isHTML && item.url.pathExtension.lowercased() != "svg" {
            editingItem = item
        } else {
            preview(url: item.url, isDirectory: false)
        }
    }

    private func preview(url: URL, isDirectory: Bool) {
        if server.isRunning, var target = server.previewURL(for: url) {
            if isDirectory && !target.absoluteString.hasSuffix("/") {
                target = URL(string: target.absoluteString + "/") ?? target
            }
            browserTarget = BrowserTarget(url: target)
            return
        }
        // 服务器未运行，或文件不在当前网站目录内：直接以本地文件方式打开
        var fileURL = url
        if isDirectory {
            fileURL = url.appendingPathComponent("index.html")
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                message = server.isRunning
                    ? "该文件夹不在当前网站（\(server.siteRootDisplay)）中，且没有 index.html。"
                    : "服务器未运行，且该文件夹中没有 index.html。请先在“服务器”页启动服务。"
                return
            }
        }
        browserTarget = BrowserTarget(url: fileURL, readAccessURL: FileStore.rootURL)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let directory = directory
            let extractZips = server.settings.autoExtractZip
            runInBackground {
                let summary = FileStore.importItems(urls, into: directory, extractZips: extractZips)
                // 普通导入成功时不打扰，解压或失败时才提示
                return summary.failures.isEmpty && summary.extractedFiles == 0 ? nil : summary.message
            }
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func extract(_ item: FileItem) {
        runInBackground {
            do {
                let result = try FileStore.extractZip(item)
                var text = "已解压 \(result.files) 个文件"
                if result.skipped > 0 {
                    text += "，跳过 \(result.skipped) 项（隐藏文件、符号链接或不安全的路径）"
                }
                return text
            } catch {
                return error.localizedDescription
            }
        }
    }

    /// 在后台线程执行耗时的文件操作（导入、解压），完成后刷新列表并显示结果
    private func runInBackground(_ work: @escaping @Sendable () -> String?) {
        isWorking = true
        Task {
            let result = await Task.detached(operation: work).value
            isWorking = false
            if let result {
                message = result
            }
            reload()
            server.notifyFilesChanged()
        }
    }

    private func commitName() {
        guard let action = nameAction else { return }
        let name = nameText
        nameAction = nil
        switch action {
        case .newFolder:
            perform { try FileStore.createFolder(named: name, in: directory) }
        case .newFile:
            perform {
                let url = try FileStore.createFile(named: name, in: directory)
                if let item = FileStore.contents(of: directory).first(where: { $0.url == url }), item.isTextFile {
                    editingItem = item
                }
            }
        case .rename(let item):
            perform { try FileStore.rename(item, to: name) }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            message = error.localizedDescription
        }
        reload()
        server.notifyFilesChanged()
    }
}

private struct FileRow: View {
    let item: FileItem
    let isSiteRoot: Bool

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(2)
                    if isSiteRoot {
                        Text("网站根目录")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let date = item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        if item.isDirectory {
            return date
        }
        return Self.sizeFormatter.string(fromByteCount: item.size) + " · " + date
    }

    private var icon: String {
        if item.isDirectory { return isSiteRoot ? "globe" : "folder.fill" }
        switch item.url.pathExtension.lowercased() {
        case "html", "htm": return "globe"
        case "css": return "paintbrush"
        case "js", "mjs", "ts", "jsx", "tsx", "vue": return "curlybraces"
        case "json", "xml", "webmanifest", "map": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "avif", "heic", "bmp": return "photo"
        case "mp4", "mov", "m4v", "webm": return "film"
        case "mp3", "m4a", "wav", "aac", "ogg", "flac": return "music.note"
        case "woff", "woff2", "ttf", "otf": return "textformat"
        case "pdf": return "doc.richtext"
        case "zip": return "doc.zipper"
        default: return "doc"
        }
    }
}
