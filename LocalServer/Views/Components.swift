import SwiftUI

/// 配对码：每一位数字放在独立的圆角方框里
struct PinDigits: View {
    let pin: String
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: size * 0.18) {
            ForEach(Array(pin.enumerated()), id: \.offset) { index, digit in
                if index == 3 {
                    Spacer().frame(width: size * 0.12)
                }
                Text(String(digit))
                    .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: size, height: size * 1.22)
                    .background(
                        Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(prominent ? .white : Theme.brandBlue)
                .frame(width: 36, height: 36)
                .background {
                    if prominent {
                        Circle().fill(Theme.brandGradient)
                    } else {
                        Circle().fill(Theme.brandBlue.opacity(0.12))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 统计数字卡片
struct StatTile: View {
    let value: String
    let title: String
    let systemName: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.14), in: Circle())
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .card(padding: 14)
    }
}

/// 浮在渐变背景上的半透明小标签
struct InfoPill: View {
    let systemName: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.18), in: Capsule())
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
        HStack(spacing: 12) {
            Text("\(log.status)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(statusColor)
                .frame(width: 40, height: 26)
                .background(statusColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(log.method)
                        .font(.caption2.weight(.heavy))
                        .foregroundColor(.secondary)
                    Text(log.path)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [Self.timeFormatter.string(from: log.date), log.client]
        if log.bytes > 0 {
            parts.append(Format.bytes(Int64(log.bytes)))
        }
        return parts.joined(separator: " · ")
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
