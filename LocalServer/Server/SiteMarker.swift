import Foundation

/// 站点的开启状态保存在站点文件夹里：存在隐藏文件 `.site-disabled` 即表示已关闭。
/// 这样无论在 App、网页管理还是「文件」App 中重命名或移动文件夹，状态都会跟着文件夹走。
/// 以 `.` 开头的文件不会被访问、不会出现在列表中，也不会被打包进 zip。
enum SiteMarker {
    static let fileName = ".site-disabled"

    static func isDisabled(_ siteFolder: URL) -> Bool {
        FileManager.default.fileExists(atPath: siteFolder.appendingPathComponent(fileName).path)
    }

    static func setEnabled(_ enabled: Bool, for siteFolder: URL) throws {
        let marker = siteFolder.appendingPathComponent(fileName)
        if enabled {
            if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
        } else if !FileManager.default.fileExists(atPath: marker.path) {
            try Data("此站点已在「本地服务器」中关闭。删除此文件即可重新开启。\n".utf8).write(to: marker)
        }
    }

    /// root 下已关闭的站点名
    static func disabledSites(in root: URL) -> [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && isDisabled($0) }
            .map(\.lastPathComponent)
            .sorted()
    }
}
