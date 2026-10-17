import SwiftUI
import UniformTypeIdentifiers

/// “文件”页：浏览、搜索、排序网站文件，支持列表和网格两种视图
struct FileBrowserView: View {
    let directory: URL

    @EnvironmentObject private var server: ServerManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("FileSortOrder") private var sortOrder = SortOrder.name
    @AppStorage("FileGridMode") private var gridMode = false

    @State private var items: [FileItem] = []
    @State private var query = ""
    @State private var showImporter = false
    @State private var importTypes: [UTType] = [.item]
    @State private var nameAction: NameAction?
    @State private var nameText = ""
    @State private var deleteTarget: FileItem?
    @State private var editingItem: FileItem?
    @State private var message: String?
    @State private var isWorking = false
    /// 一次选中多个文件时，等待用户决定是否放进新文件夹
    @State private var pendingImport: [URL]?
    @State private var folderNameText = ""
    /// 尝试打开已关闭站点中的文件时，提示是否开启
    @State private var disabledSite: String?

    enum SortOrder: String, CaseIterable, Identifiable {
        case name
        case date
        case size

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return "名称"
            case .date: return "修改时间"
            case .size: return "大小"
            }
        }
    }

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

    /// 搜索、排序后的列表；文件夹始终排在前面
    private var displayed: [FileItem] {
        let matched = query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return matched.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sortOrder {
            case .name:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date:
                return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            case .size:
                return a.size > b.size
            }
        }
    }

    var body: some View {
        content
            .overlay {
                if displayed.isEmpty {
                    emptyState
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("正在处理…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .disabled(isWorking)
            .searchable(text: $query, prompt: "搜索当前文件夹")
            .navigationTitle(isRoot ? "网站文件" : directory.lastPathComponent)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    optionsMenu
                    addMenu
                }
            }
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
            .alert("放进新文件夹？", isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            )) {
                TextField("文件夹名称", text: $folderNameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("放进新文件夹") {
                    let name = folderNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    startImport(pendingImport ?? [], newFolderName: name.isEmpty ? nil : name)
                }
                Button("直接放在这里") {
                    startImport(pendingImport ?? [], newFolderName: nil)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("选中了 \(pendingImport?.count ?? 0) 个文件，放进同一个文件夹可以避免散落在当前目录。")
            }
            .alert("站点「\(disabledSite ?? "")」已关闭", isPresented: Binding(
                get: { disabledSite != nil },
                set: { if !$0 { disabledSite = nil } }
            )) {
                Button("开启站点") {
                    if let site = disabledSite {
                        server.setSite(site, enabled: true)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("关闭的站点无法访问。开启后再试一次。")
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .sheet(item: $editingItem, onDismiss: reload) { item in
                TextFileEditor(url: item.url)
            }
    }

    // MARK: - 列表与网格

    @ViewBuilder
    private var content: some View {
        if gridMode {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isRoot && query.isEmpty {
                        SitesIntro()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(displayed) { item in
                            tile(for: item)
                        }
                    }
                    summary
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await reload() }
        } else {
            List {
                if isRoot && query.isEmpty {
                    Section {
                        SitesIntro()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(displayed) { item in
                        row(for: item)
                    }
                } footer: {
                    if !displayed.isEmpty {
                        summary
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await reload() }
        }
    }

    private func row(for item: FileItem) -> some View {
        let label = FileRowLabel(item: item, siteState: siteState(of: item))
        return Group {
            if item.isDirectory {
                NavigationLink(value: item.url) { label }
            } else {
                Button { activate(item) } label: { label }
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
        .contextMenu { menu(for: item) }
    }

    private func tile(for item: FileItem) -> some View {
        let label = FileTile(item: item, siteState: siteState(of: item))
        return Group {
            if item.isDirectory {
                NavigationLink(value: item.url) { label }
            } else {
                Button { activate(item) } label: { label }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { menu(for: item) }
    }

    @ViewBuilder
    private func menu(for item: FileItem) -> some View {
        Button {
            openInBrowser(item)
        } label: {
            Label("在浏览器中打开", systemImage: "safari")
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
                Label("解压到同名文件夹", systemImage: "archivebox")
            }
        }
        if let state = siteState(of: item) {
            Button {
                Haptics.tap()
                server.setSite(item.name, enabled: state == .disabled)
            } label: {
                Label(state == .enabled ? "关闭站点" : "开启站点", systemImage: state == .enabled ? "nosign" : "checkmark.circle")
            }
        }
        if let link = server.webURL(for: item.url) {
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
        Divider()
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

    private var summary: some View {
        let files = displayed.filter { !$0.isDirectory }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        return Text("\(displayed.count) 项 · 文件共 \(Format.bytes(total))")
            .font(.footnote)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("没有找到“\(query)”")
                    .font(.headline)
            }
        } else if !isRoot || items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.secondary)
                Text("这里还没有文件")
                    .font(.headline)
                Text("轻点右上角 + 导入网页文件、文件夹或 zip，\n也可以在电脑浏览器中拖拽上传。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    importTypes = [.item]
                    showImporter = true
                } label: {
                    Label("导入文件", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(32)
        }
    }

    // MARK: - 菜单

    private var optionsMenu: some View {
        Menu {
            Picker("视图", selection: $gridMode) {
                Label("列表", systemImage: "list.bullet").tag(false)
                Label("网格", systemImage: "square.grid.2x2").tag(true)
            }
            Picker("排序", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
        } label: {
            Image(systemName: gridMode ? "square.grid.2x2" : "list.bullet")
        }
        .accessibilityLabel("视图与排序")
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
            Image(systemName: "plus.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
        }
        .accessibilityLabel("添加")
    }

    // MARK: - 操作

    private func reload() {
        items = FileStore.contents(of: directory)
    }

    /// 轻点文件：网页、图片、视频等在浏览器中打开；纯文本文件进入编辑器
    private func activate(_ item: FileItem) {
        let ext = item.url.pathExtension.lowercased()
        if item.isTextFile && !item.isHTML && ext != "svg" {
            editingItem = item
        } else {
            openInBrowser(item)
        }
    }

    /// 根目录下的文件夹是站点，返回它的开启状态；其他项目返回 nil
    private func siteState(of item: FileItem) -> SiteState? {
        guard isRoot, item.isDirectory, Router.isValidSiteName(item.name) else { return nil }
        return server.isSiteEnabled(item.name) ? .enabled : .disabled
    }

    private func openInBrowser(_ item: FileItem) {
        if let site = FileStore.siteName(of: item.url), !server.isSiteEnabled(site) {
            disabledSite = site
            return
        }
        guard var url = server.webURL(for: item.url) else {
            message = "该项目不在 www 中，无法通过网址访问。"
            return
        }
        if item.isDirectory && !url.absoluteString.hasSuffix("/") {
            url = URL(string: url.absoluteString + "/") ?? url
        }
        server.openInBrowser(url)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            // zip 会自动解压到独立文件夹；剩下的普通文件超过一个时，询问是否放进新文件夹
            let extractZips = server.settings.autoExtractZip
            let looseFiles = urls.filter { !(extractZips && $0.pathExtension.lowercased() == "zip") }
            if importTypes != [.folder] && looseFiles.count > 1 {
                folderNameText = FileStore.defaultFolderName(for: urls)
                pendingImport = urls
            } else {
                startImport(urls, newFolderName: nil)
            }
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func startImport(_ urls: [URL], newFolderName: String?) {
        guard !urls.isEmpty else { return }
        let directory = directory
        let extractZips = server.settings.autoExtractZip
        runInBackground {
            let summary = FileStore.importItems(urls, into: directory, extractZips: extractZips, newFolderName: newFolderName)
            // 普通导入成功时不打扰，解压、新建文件夹或失败时才提示
            let quiet = summary.failures.isEmpty && summary.extractedFiles == 0 && summary.folders.isEmpty
            return quiet ? nil : summary.message
        }
    }

    private func extract(_ item: FileItem) {
        runInBackground {
            do {
                let (result, folder) = try FileStore.extractZip(item)
                var text = "已解压 \(result.files) 个文件到文件夹「\(folder.lastPathComponent)」"
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

// MARK: - 子视图

enum SiteState {
    case enabled
    case disabled
}

/// 根目录顶部的说明
private struct SitesIntro: View {
    @EnvironmentObject private var server: ServerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("每个文件夹都是一个站点")
                .font(.headline)
            Text("通过 /文件夹名/ 访问，并以自己为根目录。长按文件夹可以开启或关闭站点。")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button {
                server.openInBrowser(server.localURL)
            } label: {
                Text("在浏览器中查看所有站点 ›")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .card()
    }
}

private struct FileRowLabel: View {
    let item: FileItem
    let siteState: SiteState?

    var body: some View {
        let kind = FileKind.of(item)
        HStack(spacing: 12) {
            IconBadge(systemName: siteState == nil ? kind.symbol : "globe", color: item.isDirectory ? .accentColor : .secondary, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if siteState == .disabled {
                        PillTag(text: "已关闭")
                    }
                }
                Text(subtitle(kind))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(siteState == .disabled ? 0.6 : 1)
    }

    private func subtitle(_ kind: FileKind) -> String {
        let date = item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        if let siteState {
            let path = "/" + item.name + "/"
            return siteState == .enabled ? "站点 · \(path)" : "站点已关闭 · \(path)"
        }
        if item.isDirectory { return date }
        return "\(kind.label) · \(Format.bytes(item.size)) · \(date)"
    }
}

private struct FileTile: View {
    let item: FileItem
    let siteState: SiteState?

    var body: some View {
        let kind = FileKind.of(item)
        VStack(spacing: 8) {
            Image(systemName: siteState == nil ? kind.symbol : "globe")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(item.isDirectory ? .accentColor : .secondary)
                .frame(width: 64, height: 64)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(item.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)
            Text(caption(kind))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .opacity(siteState == .disabled ? 0.6 : 1)
    }

    private func caption(_ kind: FileKind) -> String {
        switch siteState {
        case .enabled: return "站点"
        case .disabled: return "已关闭"
        case nil: return item.isDirectory ? kind.label : Format.bytes(item.size)
        }
    }
}
