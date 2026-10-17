import SwiftUI

/// 全局视觉规范：参考苹果官网的设计语言——
/// 中性灰背景、白色圆角卡片、单一的蓝色强调色、大而清晰的标题，不使用渐变。
enum Theme {
    static let cardRadius: CGFloat = 18
    static let accent = Color.accentColor
    static let positive = Color.green
}

// MARK: - 卡片

struct CardBackground: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            )
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// 区块标题：大号粗体，右侧可放“全部”等链接
struct SectionTitle: View {
    let title: String
    var trailing: AnyView?

    init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    init<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            trailing
                .font(.subheadline)
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - 图标

/// 浅灰圆角底上的单色符号
struct IconBadge: View {
    let systemName: String
    var color: Color = .secondary
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundColor(color)
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// 设置项的标签：强调色单色图标 + 文字
struct SettingsLabel: View {
    let title: String
    let systemName: String

    init(_ title: String, systemName: String) {
        self.title = title
        self.systemName = systemName
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemName)
                .foregroundColor(.accentColor)
        }
    }
}

/// 状态小圆点
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// 灰底小标签，例如“已关闭”“已拉黑”
struct PillTag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

// MARK: - 文件类型

struct FileKind {
    let symbol: String
    let label: String

    static func of(_ item: FileItem) -> FileKind {
        if item.isDirectory {
            return FileKind(symbol: "folder", label: "文件夹")
        }
        return of(extension: item.url.pathExtension)
    }

    static func of(extension ext: String) -> FileKind {
        switch ext.lowercased() {
        case "html", "htm": return FileKind(symbol: "safari", label: "网页")
        case "css": return FileKind(symbol: "paintbrush", label: "样式")
        case "js", "mjs", "ts", "jsx", "tsx", "vue": return FileKind(symbol: "curlybraces", label: "脚本")
        case "json", "xml", "webmanifest", "map": return FileKind(symbol: "doc.text", label: "数据")
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "avif", "heic", "bmp": return FileKind(symbol: "photo", label: "图片")
        case "mp4", "mov", "m4v", "webm": return FileKind(symbol: "film", label: "视频")
        case "mp3", "m4a", "wav", "aac", "ogg", "flac": return FileKind(symbol: "music.note", label: "音频")
        case "woff", "woff2", "ttf", "otf": return FileKind(symbol: "textformat", label: "字体")
        case "pdf": return FileKind(symbol: "doc.richtext", label: "PDF")
        case "zip": return FileKind(symbol: "doc.zipper", label: "压缩包")
        case "md", "txt", "csv": return FileKind(symbol: "doc.plaintext", label: "文本")
        default: return FileKind(symbol: "doc", label: "文件")
        }
    }
}

/// 根据设备名选择图标
enum DeviceSymbol {
    static func of(_ name: String) -> String {
        if name.hasPrefix("iPhone") || name.hasPrefix("Android") { return "iphone" }
        if name.hasPrefix("iPad") { return "ipad" }
        if name.hasPrefix("Mac") { return "laptopcomputer" }
        if name.hasPrefix("Windows") || name.hasPrefix("Linux") || name.hasPrefix("ChromeOS") { return "desktopcomputer" }
        return "network"
    }
}

// MARK: - 格式化

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        byteFormatter.string(fromByteCount: count)
    }

    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 10 { return "刚刚" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// 例如“3 小时 12 分”“45 秒”
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时 \(minutes % 60) 分" }
        return "\(hours / 24) 天 \(hours % 24) 小时"
    }
}

// MARK: - 触感反馈

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
