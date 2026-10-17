import SwiftUI

/// 配对码：每一位数字放在独立的圆角方框里
struct PinDigits: View {
    let pin: String
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: size * 0.16) {
            ForEach(Array(pin.enumerated()), id: \.offset) { index, digit in
                if index == 3 {
                    Spacer().frame(width: size * 0.14)
                }
                Text(String(digit))
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: size, height: size * 1.25)
                    .background(
                        Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("配对码 \(pin.map(String.init).joined(separator: " "))")
    }
}

/// 圆形图标按钮，用于复制、二维码、打开等操作
struct CircleIconButton: View {
    let systemName: String
    var prominent = false
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(prominent ? .white : .accentColor)
                .frame(width: 34, height: 34)
                .background(prominent ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 统计数字
struct StatTile: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .card(padding: 16)
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
                .font(.footnote.monospacedDigit())
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

/// 一条请求日志
struct LogRow: View {
    let log: RequestLog

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(log.status)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(statusColor)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(log.path)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        var parts = [Self.timeFormatter.string(from: log.date), log.method, log.client]
        if let site = log.site {
            parts.append(site)
        }
        if log.bytes > 0 {
            parts.append(Format.bytes(Int64(log.bytes)))
        }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch log.status {
        case ..<300: return .green
        case ..<400: return .secondary
        case ..<500: return .orange
        default: return .red
        }
    }
}

/// 屏幕底部的轻提示
struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.text, systemImage: toast.systemName)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 24)
    }
}
