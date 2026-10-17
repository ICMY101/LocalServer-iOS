import SwiftUI

/// 所有站点：开启或关闭，查看访问情况，快捷打开
struct SitesView: View {
    @EnvironmentObject private var server: ServerManager
    @State private var qrTarget: QRTarget?

    var body: some View {
        SitesList(store: server.logStore, qrTarget: $qrTarget)
            .navigationTitle("站点")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { server.refreshSites() }
            .sheet(item: $qrTarget) { target in
                QRCodeSheet(target: target)
            }
    }
}

private struct SitesList: View {
    @EnvironmentObject private var server: ServerManager
    @ObservedObject var store: RequestLogStore
    @Binding var qrTarget: QRTarget?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("每个文件夹都是一个站点")
                        .font(.headline)
                    Text("www 中的每个文件夹都可以通过 /文件夹名/ 访问，并以自己为根目录。站点里以 / 开头的路径会自动在本站点中查找。关闭的站点无法访问，也不会出现在站点列表中。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                if server.sites.isEmpty {
                    Text("还没有站点。在“文件”页导入文件夹或 zip 即可创建。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(server.sites) { site in
                        row(site)
                    }
                }
            } header: {
                Text("\(server.sites.count) 个站点")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ site: FileStore.SiteInfo) -> some View {
        let enabled = server.isSiteEnabled(site.name)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(site.name)
                    .font(.body.weight(.semibold))
                Text(subtitle(site, enabled: enabled))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("开启", isOn: Binding(
                get: { server.isSiteEnabled(site.name) },
                set: { server.setSite(site.name, enabled: $0) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading) {
            if enabled {
                Button {
                    server.openInBrowser(server.siteURL(site))
                } label: {
                    Label("打开", systemImage: "safari")
                }
                .tint(.accentColor)
            }
        }
        .contextMenu {
            if enabled {
                Button {
                    server.openInBrowser(server.siteURL(site))
                } label: {
                    Label("在浏览器中打开", systemImage: "safari")
                }
                Button {
                    UIPasteboard.general.string = server.shareableSiteURL(site).absoluteString
                    server.showToast("已复制站点地址", systemName: "doc.on.doc")
                } label: {
                    Label("复制地址", systemImage: "doc.on.doc")
                }
                Button {
                    qrTarget = QRTarget(url: server.shareableSiteURL(site), title: site.name)
                } label: {
                    Label("二维码", systemImage: "qrcode")
                }
            }
        }
    }

    private func subtitle(_ site: FileStore.SiteInfo, enabled: Bool) -> String {
        var parts = [site.path]
        if !enabled {
            parts.append("已关闭")
        } else if let activity = store.stats.sites[site.name] {
            parts.append("\(activity.requests) 次访问")
            parts.append("最近 \(Format.relative(activity.lastAccess))")
        } else {
            parts.append("本次运行暂无访问")
        }
        if !site.hasIndex {
            parts.append("没有 index.html")
        }
        return parts.joined(separator: " · ")
    }
}

/// 访问过的设备：查看请求情况，拉黑或解除拉黑
struct DevicesView: View {
    @EnvironmentObject private var server: ServerManager

    var body: some View {
        DevicesList(store: server.logStore)
            .navigationTitle("访问设备")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DevicesList: View {
    @EnvironmentObject private var server: ServerManager
    @ObservedObject var store: RequestLogStore
    @State private var blockTarget: ClientStats?

    private var visitors: [ClientStats] {
        store.clientList.filter { !server.isBlocked($0.address) }
    }

    var body: some View {
        List {
            Section {
                if visitors.isEmpty {
                    Text("本次运行还没有设备访问。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(visitors) { client in
                        ClientRow(client: client, paired: isPaired(client.address))
                            .swipeActions {
                                if !client.isLocal {
                                    Button(role: .destructive) {
                                        blockTarget = client
                                    } label: {
                                        Label("拉黑", systemImage: "hand.raised")
                                    }
                                }
                            }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = client.address
                                    server.showToast("已复制 IP", systemName: "doc.on.doc")
                                } label: {
                                    Label("复制 IP", systemImage: "doc.on.doc")
                                }
                                if !client.isLocal {
                                    Button(role: .destructive) {
                                        blockTarget = client
                                    } label: {
                                        Label("拉黑", systemImage: "hand.raised")
                                    }
                                }
                            }
                    }
                }
            } header: {
                Text("访问过的设备")
            } footer: {
                Text("统计从本次启动 App 开始。向左滑动可以拉黑设备，拉黑后它的所有连接都会被直接拒绝。")
            }

            Section {
                if server.settings.blockedClients.isEmpty {
                    Text("没有拉黑的设备")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(server.settings.blockedClients, id: \.self) { address in
                        HStack(spacing: 12) {
                            IconBadge(systemName: "hand.raised", color: .red, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.stats.clients[address]?.deviceName ?? address)
                                    .font(.body.weight(.medium))
                                Text(blockedSubtitle(address))
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("解除") {
                                Haptics.tap()
                                server.unblock(address)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("已拉黑")
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            "拉黑 \(blockTarget?.deviceName ?? "")（\(blockTarget?.address ?? "")）？",
            isPresented: Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("拉黑", role: .destructive) {
                if let target = blockTarget {
                    Haptics.warning()
                    server.block(target.address)
                }
            }
        } message: {
            Text("该设备会立即断开，之后无法再访问任何站点和管理页，直到解除拉黑。")
        }
    }

    private func isPaired(_ address: String) -> Bool {
        server.pairedDevices.contains { $0.address == address }
    }

    private func blockedSubtitle(_ address: String) -> String {
        var parts = [address]
        if let attempts = store.stats.blockedAttempts[address], attempts > 0 {
            parts.append("已拦截 \(attempts) 次")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ClientRow: View {
    let client: ClientStats
    let paired: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: client.isLocal ? "iphone" : DeviceSymbol.of(client.deviceName), size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(client.isLocal ? "本机" : client.deviceName)
                        .font(.body.weight(.semibold))
                    if paired {
                        PillTag(text: "已配对", color: .accentColor)
                    }
                }
                Text("\(client.address) · \(client.requests) 次请求 · \(Format.bytes(Int64(client.bytes)))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text("最近 \(Format.relative(client.lastSeen)) · \(client.lastPath)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
    }
}
