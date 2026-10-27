import SwiftUI
import UniformTypeIdentifiers

/// 游戏库：导入压缩包、列出可运行的游戏、进入播放器
struct VNLibraryView: View {
    @State private var games: [VNGame] = []
    @State private var siteGames: [URL] = []
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var playing: VNGame?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if games.isEmpty {
                    emptyState
                } else {
                    gameList
                }
            }
            .navigationTitle("视觉小说")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isImporting = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isWorking)
                }
            }
            .fileImporter(isPresented: $isImporting,
                          allowedContentTypes: allowedTypes,
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .fullScreenCover(item: $playing) { game in
                VNPlayerView(game: game)
            }
            .overlay {
                if isWorking {
                    ProgressView("正在解压…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .onAppear { reload() }
        }
    }

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.zip, .folder]
        for name in ["rpa", "rpy"] {
            if let type = UTType(filenameExtension: name) { types.append(type) }
        }
        return types
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            IconBadge(systemName: "text.book.closed.fill", color: Theme.accent, size: 56)
            Text("还没有游戏")
                .font(.title3.weight(.semibold))
            Text("点右上角“+”，选择 Ren'Py 游戏的 .zip 或文件夹。\n也可以在电脑浏览器打开本机网页上传游戏压缩包（勾选“解压”），上传完回到这里。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("导入游戏") { isImporting = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gameList: some View {
        List {
            Section {
                ForEach(games) { game in
                    Button {
                        playing = game
                    } label: {
                        row(game)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            delete(game)
                        }
                    }
                }
            } header: {
                Text("\(games.count) 部游戏")
            } footer: {
                Text("游戏文件放在“文件 › \(VNGameLibrary.rootFolderName)”。只有 .rpa 归档、没有脚本的游戏暂时无法运行。")
            }

            if !siteGames.isEmpty {
                Section {
                    ForEach(siteGames, id: \.absoluteString) { url in
                        HStack(spacing: 12) {
                            IconBadge(systemName: "tray.and.arrow.down.fill", color: Theme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(url.lastPathComponent)
                                    .font(.body.weight(.medium))
                                Text("网页上传的游戏，导入后才能进播放器")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("导入") { importFromSite(url) }
                                .buttonStyle(.borderedProminent)
                                .disabled(isWorking)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("站点里发现的游戏")
                } footer: {
                    Text("在电脑浏览器打开本机网页，把游戏 zip 上传并勾选“解压”，上传完回到这里点“导入”。")
                }
            }

            Section {
                Button {
                    isImporting = true
                } label: {
                    Label("导入游戏（.zip / 文件夹）", systemImage: "square.and.arrow.down")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ game: VNGame) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "book.closed.fill", color: game.isPlayable ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title)
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)
                Text(subtitle(for: game))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: game.isPlayable ? "play.circle.fill" : "exclamationmark.circle")
                .font(.title3)
                .foregroundColor(game.isPlayable ? Theme.accent : .secondary)
        }
        .contentShape(Rectangle())
    }

    private func subtitle(for game: VNGame) -> String {
        if !game.isPlayable {
            return "只有归档，没有可读的 .rpy/.rpyc 脚本"
        }
        var parts = ["\(game.scriptCount) 个脚本"]
        if game.archiveCount > 0 { parts.append("\(game.archiveCount) 个归档") }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        games = VNGameLibrary.games()
        siteGames = VNGameLibrary.siteGames()
    }

    /// 站点里解压好的游戏移进库；同一块盘上就是改名，秒完成
    private func importFromSite(_ url: URL) {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let game = try VNGameLibrary.importFromSite(url)
                DispatchQueue.main.async {
                    isWorking = false
                    reload()
                    message = "已导入《\(game.title)》"
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    message = error.localizedDescription
                }
            }
        }
    }

    private func delete(_ game: VNGame) {
        VNGameLibrary.delete(game)
        reload()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            message = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isWorking = true
            let accessing = url.startAccessingSecurityScopedResource()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let game = try VNGameLibrary.importGame(from: url)
                    DispatchQueue.main.async {
                        isWorking = false
                        reload()
                        message = "已导入《\(game.title)》"
                    }
                } catch {
                    DispatchQueue.main.async {
                        isWorking = false
                        message = error.localizedDescription
                    }
                }
            }
        }
    }
}
