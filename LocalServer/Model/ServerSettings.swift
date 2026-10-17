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
    /// 电脑端管理页需要先用手机上的配对码配对
    var requirePairing = true
    var autoExtractZip = true
    var keepScreenOn = false
    /// 网页在系统浏览器中打开，App 会进入后台，所以默认开启后台保活
    var backgroundAudio = true
    /// 后台保活时，连续多少分钟没有请求就停止保活让系统挂起 App；0 表示一直保活
    var keepAliveIdleMinutes = 15
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
            requirePairing: requirePairing,
            siteRoot: siteRoot
        )
    }

    // MARK: - 持久化

    private enum CodingKeys: String, CodingKey {
        case port, allowLAN, autoStart, bonjour, directoryListing, spaFallback, cors, liveReload
        case webAdmin, requirePairing, autoExtractZip, keepScreenOn, backgroundAudio, keepAliveIdleMinutes, siteRoot
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
        requirePairing = (try? container.decodeIfPresent(Bool.self, forKey: .requirePairing)) ?? defaults.requirePairing
        autoExtractZip = (try? container.decodeIfPresent(Bool.self, forKey: .autoExtractZip)) ?? defaults.autoExtractZip
        keepScreenOn = (try? container.decodeIfPresent(Bool.self, forKey: .keepScreenOn)) ?? defaults.keepScreenOn
        backgroundAudio = (try? container.decodeIfPresent(Bool.self, forKey: .backgroundAudio)) ?? defaults.backgroundAudio
        keepAliveIdleMinutes = (try? container.decodeIfPresent(Int.self, forKey: .keepAliveIdleMinutes)) ?? defaults.keepAliveIdleMinutes
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
}
