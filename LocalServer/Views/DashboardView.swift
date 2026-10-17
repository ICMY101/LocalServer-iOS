import SwiftUI

/// “服务”主页：运行状态、访问统计、访问地址、电脑管理和最近活动
struct DashboardView: View {
    @EnvironmentObject private var server: ServerManager
    @State private var qrTarget: QRTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HeroCard()
                    StatsRow(store: server.logStore)
                    if server.isRunning {
                        addresses
                        ComputerCard(qrTarget: $qrTarget)
                    }
                    ActivityCard(store: server.logStore)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: server.isRunning)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("本地服务器")
            .refreshable { await server.refreshAddresses() }
        }
        .sheet(item: $qrTarget) { target in
            QRCodeSheet(target: target)
        }
    }

    // MARK: - 访问地址

    private var addresses: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("访问地址")
            VStack(spacing: 0) {
                AddressRow(icon: "iphone", color: .gray, title: "本机", url: server.localURL, onOpen: launch, onQR: nil)
                if server.settings.allowLAN {
                    ForEach(server.lanAddresses) { address in
                        Divider().padding(.leading, 60)
                        AddressRow(
                            icon: address.interface.hasPrefix("bridge") ? "personalhotspot" : "wifi",
                            color: address.interface.hasPrefix("bridge") ? .green : Theme.brandBlue,
                            title: address.label,
                            url: server.lanURL(for: address),
                            onOpen: launch,
                            onQR: { qrTarget = QRTarget(url: $0, title: "扫码访问网站") }
                        )
                    }
                    if let url = server.bonjourURL {
                        Divider().padding(.leading, 60)
                        AddressRow(
                            icon: "dot.radiowaves.left.and.right",
                            color: .purple,
                            title: "固定地址 · IP 变化后仍可用",
                            url: url,
                            onOpen: launch,
                            onQR: { qrTarget = QRTarget(url: $0, title: "扫码访问网站") }
                        )
                    }
                }
            }
            .card(padding: 4)

            if server.settings.allowLAN && server.lanAddresses.isEmpty {
                Label("未连接 Wi-Fi。连接 Wi-Fi 或打开个人热点后，其他设备即可访问。", systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func launch(_ url: URL) {
        server.openInBrowser(url)
    }
}

// MARK: - 状态卡片

private struct HeroCard: View {
    @EnvironmentObject private var server: ServerManager

    private var isFailed: Bool {
        if case .failed = server.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.bold))
                    detail
                        .font(.subheadline)
                        .opacity(0.88)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                PowerButton(isOn: server.isRunning || server.isBusy, isBusy: server.isBusy) {
                    Haptics.tap()
                    server.toggle()
                }
            }

            HStack(spacing: 8) {
                InfoPill(systemName: "folder.fill", text: server.siteRootDisplay)
                InfoPill(systemName: "number", text: "端口 \(String(server.port))")
                if server.settings.backgroundAudio {
                    InfoPill(systemName: "bolt.fill", text: "后台保活")
                }
            }

            if server.isRunning {
                Button {
                    server.openInBrowser(server.localURL)
                } label: {
                    Label("在浏览器中打开网站", systemImage: "safari.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundColor(Theme.brandBlue)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundColor(.white)
        .padding(20)
        .background(gradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: shadowColor.opacity(0.3), radius: 16, y: 8)
        .padding(.top, 4)
    }

    private var title: String {
        switch server.state {
        case .running: return "正在运行"
        case .starting: return "正在启动…"
        case .failed: return "启动失败"
        case .stopped: return "已停止"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch server.state {
        case .running:
            if let since = server.runningSince {
                TimelineView(.periodic(from: since, by: 30)) { context in
                    Text("已运行 \(Format.duration(context.date.timeIntervalSince(since)))")
                }
            } else {
                Text("服务已就绪")
            }
        case .failed(let message):
            Text(message)
        case .starting:
            Text("正在监听端口…")
        case .stopped:
            Text("轻点右侧按钮启动服务")
        }
    }

    private var gradient: LinearGradient {
        switch server.state {
        case .running, .starting: return Theme.runningGradient
        case .failed: return Theme.failedGradient
        case .stopped: return Theme.stoppedGradient
        }
    }

    private var shadowColor: Color {
        switch server.state {
        case .running, .starting: return .teal
        case .failed: return .red
        case .stopped: return .black
        }
    }
}

/// 带呼吸光环的电源按钮
private struct PowerButton: View {
    let isOn: Bool
    let isBusy: Bool
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isOn {
                    Circle()
                        .stroke(Color.white.opacity(0.5), lineWidth: 2)
                        .scaleEffect(pulse ? 1.5 : 1)
                        .opacity(pulse ? 0 : 0.9)
                }
                Circle().fill(Color.white.opacity(isOn ? 0.24 : 0.14))
                Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                if isBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 28, weight: .bold))
                }
            }
            .frame(width: 74, height: 74)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "停止服务" : "启动服务")
        .onAppear { updatePulse() }
        .onChange(of: isOn) { _ in updatePulse() }
    }

    private func updatePulse() {
        pulse = false
        guard isOn else { return }
        withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}

// MARK: - 统计

private struct StatsRow: View {
    @ObservedObject var store: RequestLogStore

    var body: some View {
        HStack(spacing: 10) {
            StatTile(value: "\(store.totalRequests)", title: "请求", systemName: "arrow.left.arrow.right", color: Theme.brandBlue)
            StatTile(value: Format.bytes(Int64(store.totalBytes)), title: "传输", systemName: "arrow.down.circle", color: .green)
            StatTile(value: "\(store.activeClients)", title: "访问设备", systemName: "person.2.fill", color: .orange)
        }
    }
}

// MARK: - 地址行

private struct AddressRow: View {
    let icon: String
    let color: Color
    let title: String
    let url: URL
    let onOpen: (URL) -> Void
    let onQR: ((URL) -> Void)?

    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: icon, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(url.absoluteString)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            CircleIconButton(systemName: copied ? "checkmark" : "doc.on.doc", label: "复制") {
                UIPasteboard.general.string = url.absoluteString
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation { copied = false }
                }
            }
            if let onQR {
                CircleIconButton(systemName: "qrcode", label: "二维码") { onQR(url) }
            }
            CircleIconButton(systemName: "safari", prominent: true, label: "在浏览器中打开") { onOpen(url) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - 电脑管理

private struct ComputerCard: View {
    @EnvironmentObject private var server: ServerManager
    @Binding var qrTarget: QRTarget?
    @State private var copied = false

    private var adminURL: URL? {
        if let address = server.lanAddresses.first {
            return server.adminURL(for: address)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("电脑管理")
            VStack(alignment: .leading, spacing: 14) {
                if !server.settings.webAdmin {
                    disabledNotice("网页管理已关闭", detail: "开启后可以在电脑浏览器中上传、下载和整理文件。") {
                        server.settings.webAdmin = true
                    }
                } else if !server.settings.allowLAN {
                    disabledNotice("局域网访问已关闭", detail: "开启后同一 Wi-Fi 下的电脑才能访问管理页。") {
                        server.settings.allowLAN = true
                    }
                } else if let url = adminURL {
                    adminLink(url)
                    if server.settings.requirePairing {
                        Divider()
                        pairingBlock
                    } else {
                        Label("未开启配对：同一局域网中的任何人都能管理你的文件", systemImage: "exclamationmark.shield.fill")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                } else {
                    Label("连接 Wi-Fi 后即可在电脑上管理文件", systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .card()
        }
    }

    private func adminLink(_ url: URL) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "desktopcomputer", color: .indigo, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("在电脑浏览器中打开")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(url.absoluteString)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            CircleIconButton(systemName: copied ? "checkmark" : "doc.on.doc", label: "复制") {
                UIPasteboard.general.string = url.absoluteString
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation { copied = false }
                }
            }
            CircleIconButton(systemName: "qrcode", label: "二维码") {
                qrTarget = QRTarget(url: url, title: "扫码打开电脑管理页")
            }
        }
    }

    private var pairingBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .font(.footnote.weight(.bold))
                }
                .accessibilityLabel("更换配对码")
            }
            PinDigits(pin: server.pairingCode.pin, size: 38)
                .frame(maxWidth: .infinity)
            Text("电脑打开上面的地址后，输入这 6 位配对码即可。每个浏览器只需配对一次。")
                .font(.caption)
                .foregroundColor(.secondary)
            NavigationLink {
                PairedDevicesView()
            } label: {
                HStack {
                    Label("已配对设备", systemImage: "laptopcomputer")
                    Spacer()
                    Text("\(server.pairedDevices.count) 台")
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)
        }
    }

    private func disabledNotice(_ title: String, detail: String, enable: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "desktopcomputer", color: .gray, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("开启", action: enable)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// 配对码剩余有效时间；到期时回调以取回新的配对码
struct PinCountdown: View {
    let expires: Date
    let onExpire: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(expires.timeIntervalSince(context.date)))
            Text(remaining > 0 ? String(format: "%d:%02d 后更换", remaining / 60, remaining % 60) : "正在更换…")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .onChange(of: remaining == 0) { expired in
                    if expired { onExpire() }
                }
                .onAppear {
                    if remaining == 0 { onExpire() }
                }
        }
    }
}

// MARK: - 最近活动

private struct ActivityCard: View {
    @ObservedObject var store: RequestLogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("最近活动") {
                if !store.logs.isEmpty {
                    NavigationLink {
                        LogListView(store: store)
                    } label: {
                        Text("全部")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if store.logs.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.secondary)
                        Text("还没有访问记录")
                            .foregroundColor(.secondary)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                } else {
                    ForEach(store.logs.prefix(6)) { log in
                        LogRow(log: log)
                    }
                }
            }
            .card()
        }
    }
}
