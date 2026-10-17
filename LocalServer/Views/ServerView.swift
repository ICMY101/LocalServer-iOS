import SwiftUI

struct ServerView: View {
    @EnvironmentObject private var server: ServerManager
    @State private var browserTarget: BrowserTarget?
    @State private var qrTarget: QRTarget?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusHeader
                }

                if server.isRunning {
                    addressSection
                    if server.settings.webAdmin && server.settings.allowLAN && !server.lanAddresses.isEmpty {
                        uploadSection
                    }
                }

                logSection
            }
            .navigationTitle("本地服务器")
            .refreshable { await server.refreshAddresses() }
        }
        .fullScreenCover(item: $browserTarget) { target in
            BrowserView(target: target)
        }
        .sheet(item: $qrTarget) { target in
            QRCodeSheet(target: target)
        }
    }

    // MARK: - 状态

    private var statusHeader: some View {
        VStack(spacing: 14) {
            Image(systemName: statusIcon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(statusColor)
                .frame(height: 52)

            VStack(spacing: 4) {
                Text(statusTitle)
                    .font(.title3.weight(.semibold))
                if let detail = statusDetail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(isFailed ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Button {
                server.toggle()
            } label: {
                Text(server.isRunning || server.isBusy ? "停止服务" : "启动服务")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(server.isRunning ? Color.red : Color.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var isFailed: Bool {
        if case .failed = server.state { return true }
        return false
    }

    private var statusIcon: String {
        switch server.state {
        case .running: return "antenna.radiowaves.left.and.right"
        case .starting: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "pause.circle"
        }
    }

    private var statusColor: Color {
        switch server.state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var statusTitle: String {
        switch server.state {
        case .running(let port): return "运行中 · 端口 \(port)"
        case .starting: return "正在启动…"
        case .failed: return "启动失败"
        case .stopped: return "已停止"
        }
    }

    private var statusDetail: String? {
        switch server.state {
        case .failed(let message): return message
        case .running: return server.settings.allowLAN ? "本机和同一局域网的设备都可以访问" : "仅本机可访问（可在设置中开启局域网访问）"
        case .stopped: return "网站根目录：文件 › www"
        case .starting: return nil
        }
    }

    // MARK: - 地址

    private var addressSection: some View {
        Section {
            AddressRow(label: "本机", url: server.localURL, showQR: false, open: openInBrowser, qr: { _ in })
            if server.settings.allowLAN {
                ForEach(server.lanAddresses) { address in
                    AddressRow(
                        label: address.label,
                        url: server.lanURL(for: address),
                        showQR: true,
                        open: openInBrowser,
                        qr: { qrTarget = QRTarget(url: $0, title: "扫码访问网站") }
                    )
                }
            }
        } header: {
            Text("访问地址")
        } footer: {
            if server.settings.allowLAN && server.lanAddresses.isEmpty {
                Text("未检测到局域网连接。连接 Wi-Fi 或打开个人热点后，其他设备即可访问。")
            } else if server.settings.allowLAN {
                Text("在其他设备访问时，本 App 需保持在前台（或在设置中开启“后台保活”）。")
            }
        }
    }

    private var uploadSection: some View {
        Section {
            ForEach(server.lanAddresses) { address in
                AddressRow(
                    label: address.label,
                    url: server.adminURL(for: address),
                    showQR: true,
                    open: openInBrowser,
                    qr: { qrTarget = QRTarget(url: $0, title: "扫码打开上传页面") }
                )
            }
        } header: {
            Text("从电脑上传文件")
        } footer: {
            Text("在同一 Wi-Fi 下的电脑浏览器中打开此地址，可以拖拽上传文件或整个文件夹。")
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            if server.logs.isEmpty {
                Text("暂无请求")
                    .foregroundColor(.secondary)
            } else {
                ForEach(server.logs.prefix(100)) { log in
                    LogRow(log: log)
                }
            }
        } header: {
            HStack {
                Text("请求日志")
                Spacer()
                if !server.logs.isEmpty {
                    Button("清空") { server.clearLogs() }
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        }
    }

    private func openInBrowser(_ url: URL) {
        browserTarget = BrowserTarget(url: url)
    }
}

// MARK: - 行视图

private struct AddressRow: View {
    let label: String
    let url: URL
    let showQR: Bool
    let open: (URL) -> Void
    let qr: (URL) -> Void

    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(url.absoluteString)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)

            Button {
                UIPasteboard.general.string = url.absoluteString
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel("复制")

            if showQR {
                Button { qr(url) } label: { Image(systemName: "qrcode") }
                    .accessibilityLabel("二维码")
            }

            Button { open(url) } label: { Image(systemName: "safari") }
                .accessibilityLabel("在 App 内打开")
        }
        .buttonStyle(.borderless)
    }
}

private struct LogRow: View {
    let log: RequestLog

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(log.status)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(statusColor, in: RoundedRectangle(cornerRadius: 4))
                Text(log.method)
                    .font(.caption.weight(.semibold))
                Text(log.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(Self.timeFormatter.string(from: log.date)) · \(log.client)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        switch log.status {
        case ..<300: return .green
        case ..<400: return .blue
        case ..<500: return .orange
        default: return .red
        }
    }
}
