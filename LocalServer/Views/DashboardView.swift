import SwiftUI

/// “服务”主页：运行状态、访问统计、站点、访问地址、电脑管理和最近活动
struct DashboardView: View {
    @EnvironmentObject private var server: ServerManager
    @State private var qrTarget: QRTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    StatusSection()
                    StatsRow(store: server.logStore)
                    SitesSection(store: server.logStore, qrTarget: $qrTarget)
                    if server.isRunning {
                        AddressesSection(qrTarget: $qrTarget)
                        ComputerSection(qrTarget: $qrTarget)
                    }
                    ActivitySection(store: server.logStore)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 36)
                .animation(.easeInOut(duration: 0.25), value: server.isRunning)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("本地服务器")
            .refreshable {
                await server.refreshAddresses()
                await server.refreshSites()
            }
        }
        .sheet(item: $qrTarget) { target in
            QRCodeSheet(target: target)
        }
    }
}

// MARK: - 运行状态

private struct StatusSection: View {
    @EnvironmentObject private var server: ServerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                StatusDot(color: dotColor)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            Text(headline)
                .font(.system(size: 34, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            detail
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if server.isRunning {
                    Button {
                        server.openInBrowser(server.localURL)
                    } label: {
                        Text("打开站点列表")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("停止") {
                        Haptics.tap()
                        server.stop()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Haptics.tap()
                        server.start()
                    } label: {
                        Text(server.isBusy ? "正在启动…" : "启动服务")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(server.isBusy)
                }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    private var label: String {
        switch server.state {
        case .running: return "运行中"
        case .starting: return "正在启动"
        case .failed: return "出现问题"
        case .stopped: return "已停止"
        }
    }

    private var dotColor: Color {
        switch server.state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return Color(.tertiaryLabel)
        }
    }

    private var headline: String {
        switch server.state {
        case .running: return "服务已就绪。"
        case .starting: return "正在启动服务。"
        case .failed: return "服务启动失败。"
        case .stopped: return "服务已停止。"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch server.state {
        case .running:
            if let since = server.runningSince {
                TimelineView(.periodic(from: since, by: 30)) { context in
                    Text(runningDetail(uptime: context.date.timeIntervalSince(since)))
                }
            } else {
                Text(runningDetail(uptime: nil))
            }
        case .failed(let message):
            Text(message)
        case .starting:
            Text("正在监听端口 \(String(server.port))。")
        case .stopped:
            Text("启动后，本机和同一 Wi-Fi 下的设备都可以访问你的站点。")
        }
    }

    private func runningDetail(uptime: TimeInterval?) -> String {
        var parts = ["端口 \(String(server.port))"]
        if let uptime {
            parts.append("已运行 \(Format.duration(uptime))")
        }
        let enabled = server.sites.filter { server.isSiteEnabled($0.name) }.count
        parts.append("\(enabled) 个站点")
        if server.settings.backgroundAudio {
            parts.append("后台保活")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 统计

private struct StatsRow: View {
    @ObservedObject var store: RequestLogStore

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                LogListView(store: store)
            } label: {
                StatTile(value: "\(store.totalRequests)", title: "请求")
            }
            StatTile(value: Format.bytes(Int64(store.totalBytes)), title: "传输")
            NavigationLink {
                DevicesView()
            } label: {
                StatTile(value: "\(store.activeClients)", title: "访问设备 ›")
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 站点

private struct SitesSection: View {
    @EnvironmentObject private var server: ServerManager
    @ObservedObject var store: RequestLogStore
    @Binding var qrTarget: QRTarget?

    /// 活跃的排在前面，其次是已开启的
    private var ordered: [FileStore.SiteInfo] {
        server.sites.sorted { a, b in
            let aActive = store.isActive(site: a.name)
            let bActive = store.isActive(site: b.name)
            if aActive != bActive { return aActive }
            let aOn = server.isSiteEnabled(a.name)
            let bOn = server.isSiteEnabled(b.name)
            if aOn != bOn { return aOn }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("站点") {
                NavigationLink("管理") { SitesView() }
            }
            if server.sites.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有站点")
                        .font(.headline)
                    Text("在“文件”页导入文件夹或 zip，www 中的每个文件夹都会成为一个独立站点。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(ordered.prefix(6).enumerated()), id: \.element.id) { index, site in
                        if index > 0 {
                            Divider().padding(.leading, 18)
                        }
                        SiteRow(site: site, store: store, qrTarget: $qrTarget)
                    }
                }
                .card(padding: 0)
                if server.sites.count > 6 {
                    NavigationLink("查看全部 \(server.sites.count) 个站点") { SitesView() }
                        .font(.subheadline)
                        .padding(.horizontal, 2)
                }
            }
        }
    }
}

private struct SiteRow: View {
    let site: FileStore.SiteInfo
    @ObservedObject var store: RequestLogStore
    @Binding var qrTarget: QRTarget?
    @EnvironmentObject private var server: ServerManager

    private var enabled: Bool { server.isSiteEnabled(site.name) }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(site.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(site.path)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                    status
                }
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if !enabled {
                PillTag(text: "已关闭")
            }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel("更多操作")
            if enabled {
                CircleIconButton(systemName: "arrow.up.right", prominent: true, label: "在浏览器中打开") {
                    server.openInBrowser(server.siteURL(site))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            if enabled {
                server.openInBrowser(server.siteURL(site))
            } else {
                server.showToast("「\(site.name)」已关闭，点 ⋯ 可以开启", systemName: "nosign")
            }
        }
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            server.setSite(site.name, enabled: !enabled)
        } label: {
            Label(enabled ? "关闭站点" : "开启站点", systemImage: enabled ? "nosign" : "checkmark.circle")
        }
        if enabled {
            Section {
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

    @ViewBuilder
    private var status: some View {
        if !enabled {
            EmptyView()
        } else if store.isActive(site: site.name), let activity = store.stats.sites[site.name] {
            HStack(spacing: 4) {
                StatusDot(color: .green, size: 6)
                Text("活跃 · \(Format.relative(activity.lastAccess))")
                    .font(.footnote)
            }
        } else if !site.hasIndex {
            Text("· 无首页").font(.footnote)
        }
    }
}

// MARK: - 访问地址

private struct AddressesSection: View {
    @EnvironmentObject private var server: ServerManager
    @Binding var qrTarget: QRTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("访问地址")
            VStack(spacing: 0) {
                AddressRow(icon: "iphone", title: "本机", url: server.localURL, onQR: nil)
                if server.settings.allowLAN {
                    ForEach(server.lanAddresses) { address in
                        Divider().padding(.leading, 66)
                        AddressRow(
                            icon: address.interface.hasPrefix("bridge") ? "personalhotspot" : "wifi",
                            title: address.label,
                            url: server.lanURL(for: address),
                            onQR: { qrTarget = QRTarget(url: $0, title: "扫码访问") }
                        )
                    }
                    if let url = server.bonjourURL {
                        Divider().padding(.leading, 66)
                        AddressRow(
                            icon: "dot.radiowaves.left.and.right",
                            title: "固定地址",
                            url: url,
                            onQR: { qrTarget = QRTarget(url: $0, title: "扫码访问") }
                        )
                    }
                }
            }
            .card(padding: 0)

            if server.settings.allowLAN && server.lanAddresses.isEmpty {
                Text("未连接 Wi-Fi。连接 Wi-Fi 或打开个人热点后，其他设备即可访问。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private struct AddressRow: View {
    let icon: String
    let title: String
    let url: URL
    let onQR: ((URL) -> Void)?
    @EnvironmentObject private var server: ServerManager

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: icon, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text(url.absoluteString)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            CircleIconButton(systemName: "doc.on.doc", label: "复制") {
                UIPasteboard.general.string = url.absoluteString
                server.showToast("已复制地址", systemName: "doc.on.doc")
            }
            if let onQR {
                CircleIconButton(systemName: "qrcode", label: "二维码") { onQR(url) }
            }
            CircleIconButton(systemName: "safari", prominent: true, label: "在浏览器中打开") {
                server.openInBrowser(url)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 电脑管理

private struct ComputerSection: View {
    @EnvironmentObject private var server: ServerManager
    @Binding var qrTarget: QRTarget?

    private var adminURL: URL? {
        server.lanAddresses.first.map { server.adminURL(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("电脑管理")
            VStack(alignment: .leading, spacing: 16) {
                if !server.settings.webAdmin {
                    notice("网页管理已关闭", detail: "开启后可以在电脑浏览器中上传、下载和整理文件。") {
                        server.settings.webAdmin = true
                    }
                } else if !server.settings.allowLAN {
                    notice("局域网访问已关闭", detail: "开启后同一 Wi-Fi 下的电脑才能访问管理页。") {
                        server.settings.allowLAN = true
                    }
                } else if let url = adminURL {
                    adminLink(url)
                    if server.settings.requirePairing {
                        Divider()
                        pairing
                    } else {
                        Label("未开启配对：同一局域网中的任何人都能管理你的文件。", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                } else {
                    Text("连接 Wi-Fi 后，即可在电脑上管理文件。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .card()
        }
    }

    private func adminLink(_ url: URL) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("在电脑浏览器中打开")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text(url.absoluteString)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            CircleIconButton(systemName: "doc.on.doc", label: "复制") {
                UIPasteboard.general.string = url.absoluteString
                server.showToast("已复制管理页地址", systemName: "doc.on.doc")
            }
            CircleIconButton(systemName: "qrcode", label: "二维码") {
                qrTarget = QRTarget(url: url, title: "电脑管理页")
            }
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("配对码")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                PinCountdown(expires: server.pairingCode.expires) {
                    server.refreshPairing()
                }
                Button {
                    Haptics.tap()
                    server.regeneratePIN()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityLabel("更换配对码")
            }
            PinDigits(pin: server.pairingCode.pin, size: 38)
                .frame(maxWidth: .infinity)
            NavigationLink {
                PairedDevicesView()
            } label: {
                HStack {
                    Text("已配对设备")
                    Spacer()
                    Text("\(server.pairedDevices.count) 台")
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)
        }
    }

    private func notice(_ title: String, detail: String, enable: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundColor(.secondary)
            }
            Spacer()
            Button("开启", action: enable)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}

// MARK: - 最近活动

private struct ActivitySection: View {
    @ObservedObject var store: RequestLogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("最近活动") {
                if !store.logs.isEmpty {
                    NavigationLink("全部") { LogListView(store: store) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if store.logs.isEmpty {
                    Text("还没有访问记录。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(store.logs.prefix(5)) { log in
                        LogRow(log: log)
                    }
                }
            }
            .card()
        }
    }
}
