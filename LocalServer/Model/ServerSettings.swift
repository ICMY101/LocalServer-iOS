import Foundation

struct ServerSettings: Codable, Equatable {
    var port: UInt16 = 8080
    var allowLAN = true
    var autoStart = true
    var directoryListing = true
    var spaFallback = false
    var cors = false
    var webAdmin = true
    var keepScreenOn = false
    var backgroundAudio = false

    var routerConfig: Router.Config {
        Router.Config(directoryListing: directoryListing, spaFallback: spaFallback, webAdmin: webAdmin, cors: cors)
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
