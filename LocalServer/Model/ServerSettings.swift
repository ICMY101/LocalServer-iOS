import Foundation

struct ServerSettings: Codable, Equatable {
    var port: UInt16 = 8080
    var allowLAN = true
    var autoStart = true
    var bonjour = true
    var directoryListing = true
    var spaFallback = false
    var cors = false
    var liveReload = true
    var webAdmin = true
    /// 为空表示上传页面无需密码
    var adminPassword = ""
    var autoExtractZip = true
    var keepScreenOn = false
    var backgroundAudio = false
    /// 当前网站相对 www 的路径，空字符串表示 www 本身
    var siteRoot = ""

    init() {}

    var routerConfig: Router.Config {
        Router.Config(
            directoryListing: directoryListing,
            spaFallback: spaFallback,
            webAdmin: webAdmin,
            cors: cors,
            liveReload: liveReload,
            adminPassword: adminPassword,
            siteRoot: siteRoot
        )
    }

    // MARK: - 持久化

    private enum CodingKeys: String, CodingKey {
        case port, allowLAN, autoStart, bonjour, directoryListing, spaFallback, cors, liveReload
        case webAdmin, adminPassword, autoExtractZip, keepScreenOn, backgroundAudio, siteRoot
    }

    /// 逐个字段解码，缺失的字段使用默认值，这样新版本新增设置项时不会丢掉用户原有的设置
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerSettings()
        port = (try? container.decodeIfPresent(UInt16.self, forKey: .port)) ?? defaults.port
        allowLAN = (try? container.decodeIfPresent(Bool.self, forKey: .allowLAN)) ?? defaults.allowLAN
        autoStart = (try? container.decodeIfPresent(Bool.self, forKey: .autoStart)) ?? defaults.autoStart
        bonjour = (try? container.decodeIfPresent(Bool.self, forKey: .bonjour)) ?? defaults.bonjour
        directoryListing = (try? container.decodeIfPresent(Bool.self, forKey: .directoryListing)) ?? defaults.directoryListing
        spaFallback = (try? container.decodeIfPresent(Bool.self, forKey: .spaFallback)) ?? defaults.spaFallback
        cors = (try? container.decodeIfPresent(Bool.self, forKey: .cors)) ?? defaults.cors
        liveReload = (try? container.decodeIfPresent(Bool.self, forKey: .liveReload)) ?? defaults.liveReload
        webAdmin = (try? container.decodeIfPresent(Bool.self, forKey: .webAdmin)) ?? defaults.webAdmin
        adminPassword = (try? container.decodeIfPresent(String.self, forKey: .adminPassword)) ?? defaults.adminPassword
        autoExtractZip = (try? container.decodeIfPresent(Bool.self, forKey: .autoExtractZip)) ?? defaults.autoExtractZip
        keepScreenOn = (try? container.decodeIfPresent(Bool.self, forKey: .keepScreenOn)) ?? defaults.keepScreenOn
        backgroundAudio = (try? container.decodeIfPresent(Bool.self, forKey: .backgroundAudio)) ?? defaults.backgroundAudio
        siteRoot = (try? container.decodeIfPresent(String.self, forKey: .siteRoot)) ?? defaults.siteRoot
    }

    private static let storageKey = "ServerSettings"

    static func load() -> ServerSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(ServerSettings.self, from: data) else {
            return ServerSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// 生成 6 位数字访问码
    static func randomPassword() -> String {
        String((0..<6).map { _ in "0123456789".randomElement()! })
    }
}
