import SwiftUI

/// 全局视觉规范：品牌色、卡片、图标徽章、文件类型配色
enum Theme {
    static let brandBlue = Color(red: 0.23, green: 0.42, blue: 1.0)
    static let brandPurple = Color(red: 0.48, green: 0.30, blue: 1.0)

    static let brandGradient = LinearGradient(
        colors: [brandBlue, brandPurple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let runningGradient = LinearGradient(
        colors: [Color(red: 0.05, green: 0.66, blue: 0.56), Color(red: 0.16, green: 0.47, blue: 0.98)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let stoppedGradient = LinearGradient(
        colors: [Color(red: 0.33, green: 0.36, blue: 0.45), Color(red: 0.20, green: 0.22, blue: 0.29)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let failedGradient = LinearGradient(
        colors: [Color(red: 0.93, green: 0.33, blue: 0.30), Color(red: 0.96, green: 0.55, blue: 0.20)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardRadius: CGFloat = 20
}

// MARK: - 卡片

struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

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
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// 卡片上方的小标题
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
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

// MARK: - 图标徽章

/// 圆角方块里的白色 SF Symbol，类似系统“设置”的图标
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// 设置项的标签：彩色图标 + 文字
struct SettingsLabel: View {
    let title: String
    let systemName: String
    let color: Color

    init(_ title: String, systemName: String, color: Color) {
        self.title = title
        self.systemName = systemName
        self.color = color
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: systemName, color: color, size: 29)
            Text(title)
        }
    }
}

// MARK: - 文件类型

struct FileKind {
    let symbol: String
    let color: Color
    let label: String

    static func of(_ item: FileItem) -> FileKind {
        if item.isDirectory {
            return FileKind(symbol: "folder.fill", color: Theme.brandBlue, label: "文件夹")
        }
        return of(extension: item.url.pathExtension)
    }

    static func of(extension ext: String) -> FileKind {
        switch ext.lowercased() {
        case "html", "htm":
            return FileKind(symbol: "globe", color: .orange, label: "网页")
        case "css":
            return FileKind(symbol: "paintbrush.fill", color: .blue, label: "样式")
        case "js", "mjs", "ts", "jsx", "tsx", "vue":
            return FileKind(symbol: "curlybraces", color: Color(red: 0.85, green: 0.65, blue: 0.0), label: "脚本")
        case "json", "xml", "webmanifest", "map":
            return FileKind(symbol: "doc.text.fill", color: .gray, label: "数据")
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "avif", "heic", "bmp":
            return FileKind(symbol: "photo.fill", color: .green, label: "图片")
        case "mp4", "mov", "m4v", "webm":
            return FileKind(symbol: "film.fill", color: .purple, label: "视频")
        case "mp3", "m4a", "wav", "aac", "ogg", "flac":
            return FileKind(symbol: "music.note", color: .pink, label: "音频")
        case "woff", "woff2", "ttf", "otf":
            return FileKind(symbol: "textformat", color: .teal, label: "字体")
        case "pdf":
            return FileKind(symbol: "doc.richtext.fill", color: .red, label: "PDF")
        case "zip":
            return FileKind(symbol: "doc.zipper", color: .indigo, label: "压缩包")
        case "md", "txt", "csv":
            return FileKind(symbol: "doc.plaintext.fill", color: .gray, label: "文本")
        default:
            return FileKind(symbol: "doc.fill", color: Color(.systemGray2), label: "文件")
        }
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

    /// 6 位配对码显示为“123 456”
    static func pin(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        return String(pin.prefix(3)) + " " + String(pin.suffix(3))
    }
}

// MARK: - 触感反馈

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
