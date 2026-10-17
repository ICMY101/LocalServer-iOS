import SwiftUI

/// 电脑浏览器请求配对时弹出，显示 6 位配对码；配对成功后显示对勾并自动关闭
struct PairingSheet: View {
    let request: PairingRequest

    @EnvironmentObject private var server: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var succeeded = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(succeeded ? Color.green : Color(.tertiarySystemFill))
                    .frame(width: 72, height: 72)
                Image(systemName: succeeded ? "checkmark" : "laptopcomputer.and.iphone")
                    .font(.system(size: succeeded ? 32 : 28, weight: succeeded ? .bold : .regular))
                    .foregroundColor(succeeded ? .white : .accentColor)
            }
            .padding(.top, 28)

            VStack(spacing: 6) {
                Text(succeeded ? "配对成功" : "配对请求")
                    .font(.title2.weight(.bold))
                Text(succeeded
                     ? "\(request.deviceName) 现在可以管理你的文件了"
                     : "\(request.deviceName)（\(request.address)）想要管理你的文件，请在电脑上输入下面的配对码")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if !succeeded {
                PinDigits(pin: server.pairingCode.pin, size: 46)
                    .transition(.scale.combined(with: .opacity))

                HStack(spacing: 14) {
                    PinCountdown(expires: server.pairingCode.expires) {
                        server.refreshPairing()
                    }
                    Button {
                        Haptics.tap()
                        server.regeneratePIN()
                    } label: {
                        Label("更换", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Text(succeeded ? "完成" : "关闭")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onChange(of: server.lastPairedAt) { pairedAt in
            guard let pairedAt, pairedAt >= request.date else { return }
            Haptics.success()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                succeeded = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                dismiss()
            }
        }
    }
}

/// 已配对设备列表：查看最近访问时间，随时取消配对
struct PairedDevicesView: View {
    @EnvironmentObject private var server: ServerManager
    @State private var confirmRevokeAll = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    HStack {
                        Text("当前配对码")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        PinCountdown(expires: server.pairingCode.expires) {
                            server.refreshPairing()
                        }
                    }
                    PinDigits(pin: server.pairingCode.pin, size: 40)
                    Button {
                        Haptics.tap()
                        server.regeneratePIN()
                    } label: {
                        Label("更换配对码", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } footer: {
                Text("配对码 5 分钟后自动更换，每次配对成功后也会更换。")
            }

            Section {
                if server.pairedDevices.isEmpty {
                    Text("还没有配对的设备")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(server.pairedDevices) { device in
                        DeviceRow(device: device)
                            .swipeActions {
                                Button(role: .destructive) {
                                    server.revoke(device)
                                } label: {
                                    Label("取消配对", systemImage: "link.badge.minus")
                                }
                            }
                    }
                }
            } header: {
                Text("已配对设备")
            } footer: {
                if !server.pairedDevices.isEmpty {
                    Text("向左滑动可取消某台设备的配对。取消后，该浏览器需要重新输入配对码。")
                }
            }

            if !server.pairedDevices.isEmpty {
                Section {
                    Button("取消所有设备的配对", role: .destructive) {
                        confirmRevokeAll = true
                    }
                }
            }
        }
        .navigationTitle("已配对设备")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("取消所有设备的配对？", isPresented: $confirmRevokeAll, titleVisibility: .visible) {
            Button("全部取消", role: .destructive) {
                server.revokeAllDevices()
            }
        } message: {
            Text("所有电脑和浏览器都需要重新输入配对码。")
        }
    }
}

private struct DeviceRow: View {
    let device: PairedDevice

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: DeviceSymbol.of(device.name), color: .accentColor, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.body.weight(.medium))
                Text("\(device.address) · 最近访问 \(Format.relative(device.lastSeen))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 全部请求日志，支持搜索和按结果筛选
struct LogListView: View {
    @ObservedObject var store: RequestLogStore
    @State private var query = ""
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case success = "成功"
        case failure = "错误"

        var id: String { rawValue }
    }

    private var filtered: [RequestLog] {
        store.logs.filter { log in
            switch filter {
            case .all: break
            case .success: guard log.status < 400 else { return false }
            case .failure: guard log.status >= 400 else { return false }
            }
            return query.isEmpty
                || log.path.localizedCaseInsensitiveContains(query)
                || log.client.contains(query)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("筛选", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                if filtered.isEmpty {
                    Text("没有匹配的记录")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(filtered) { log in
                        LogRow(log: log)
                    }
                }
            } footer: {
                Text("显示最近 \(RequestLogStore.maxLogs) 条请求。")
            }
        }
        .searchable(text: $query, prompt: "搜索路径或 IP")
        .navigationTitle("请求日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清空", role: .destructive) { store.clear() }
                    .disabled(store.logs.isEmpty)
            }
        }
    }
}
