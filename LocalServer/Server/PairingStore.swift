import CryptoKit
import Foundation

/// 已配对的电脑或浏览器
struct PairedDevice: Codable, Identifiable, Equatable, Sendable {
    /// 会话令牌的 SHA-256，令牌本身只保存在浏览器的 Cookie 中
    let id: String
    var name: String
    var address: String
    let pairedAt: Date
    var lastSeen: Date
}

/// 浏览器打开配对页时发给 App 的请求，App 据此弹出配对码
struct PairingRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let deviceName: String
    let address: String
    let date: Date
}

/// PIN 配对：手机上显示一次性 6 位配对码，在电脑浏览器中输入即可完成配对。
/// 配对码 5 分钟过期，配对成功后立即更换；连续输错 5 次锁定 1 分钟。
/// 已配对设备保存在 App 私有目录中，重启后仍然有效，可在 App 中随时取消配对。
/// 所有方法都可以在任意线程调用。
final class PairingStore: @unchecked Sendable {
    enum PairError: Error, Equatable {
        case wrongPIN(remainingAttempts: Int)
        case locked(seconds: Int)
        case expired
    }

    static let pinLength = 6
    static let pinLifetime: TimeInterval = 300
    private static let maxFailures = 5
    private static let lockDuration: TimeInterval = 60
    private static let maxDevices = 32
    private static let requestInterval: TimeInterval = 5

    /// 配对码或已配对设备变化时回调
    var onChange: (@Sendable () -> Void)?
    /// 有浏览器请求配对时回调
    var onPairingRequest: (@Sendable (PairingRequest) -> Void)?

    private let lock = NSLock()
    private let fileURL: URL?
    private var devices: [String: PairedDevice] = [:]
    private var pin = ""
    private var pinExpires = Date.distantPast
    private var failures: [String: (count: Int, lockedUntil: Date)] = [:]
    private var lastRequest: [String: Date] = [:]

    /// fileURL 为 nil 时只保存在内存中（用于测试）
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            devices = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        }
        regenerateLocked()
    }

    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("paired-devices.json")
    }

    // MARK: - 配对码

    /// 当前配对码；过期时自动更换
    func currentPIN() -> (pin: String, expires: Date) {
        lock.lock()
        defer { lock.unlock() }
        if pinExpires <= Date() {
            regenerateLocked()
        }
        return (pin, pinExpires)
    }

    func regeneratePIN() {
        lock.lock()
        regenerateLocked()
        lock.unlock()
        onChange?()
    }

    private func regenerateLocked() {
        pin = String((0..<Self.pinLength).map { _ in "0123456789".randomElement()! })
        pinExpires = Date().addingTimeInterval(Self.pinLifetime)
    }

    // MARK: - 配对流程

    /// 浏览器打开配对页时调用；同一地址 5 秒内只通知一次
    func requestPairing(address: String, userAgent: String?) {
        let now = Date()
        lock.lock()
        if let last = lastRequest[address], now.timeIntervalSince(last) < Self.requestInterval {
            lock.unlock()
            return
        }
        lastRequest[address] = now
        if pinExpires <= now {
            regenerateLocked()
        }
        lock.unlock()
        onPairingRequest?(PairingRequest(deviceName: DeviceName.from(userAgent: userAgent), address: address, date: now))
    }

    /// 校验配对码，成功时返回新的会话令牌
    func pair(pin supplied: String, address: String, userAgent: String?) -> Result<String, PairError> {
        let now = Date()
        lock.lock()
        if let record = failures[address], record.lockedUntil > now {
            lock.unlock()
            return .failure(.locked(seconds: Int(record.lockedUntil.timeIntervalSince(now).rounded(.up))))
        }
        if pinExpires <= now {
            regenerateLocked()
            lock.unlock()
            onChange?()
            return .failure(.expired)
        }
        let digits = supplied.filter(\.isNumber)
        guard Self.constantTimeEquals(digits, pin) else {
            var record = failures[address] ?? (count: 0, lockedUntil: Date.distantPast)
            record.count += 1
            let remaining = Self.maxFailures - record.count
            if remaining <= 0 {
                failures[address] = (count: 0, lockedUntil: now.addingTimeInterval(Self.lockDuration))
                lock.unlock()
                return .failure(.locked(seconds: Int(Self.lockDuration)))
            }
            failures[address] = record
            lock.unlock()
            return .failure(.wrongPIN(remainingAttempts: remaining))
        }

        failures[address] = nil
        let token = Self.randomToken()
        let device = PairedDevice(
            id: Self.hash(token),
            name: DeviceName.from(userAgent: userAgent),
            address: address,
            pairedAt: now,
            lastSeen: now
        )
        devices[device.id] = device
        if devices.count > Self.maxDevices,
           let oldest = devices.values.min(by: { $0.lastSeen < $1.lastSeen }) {
            devices[oldest.id] = nil
        }
        // 一个配对码只能用一次
        regenerateLocked()
        saveLocked()
        lock.unlock()
        onChange?()
        return .success(token)
    }

    /// 令牌是否属于已配对设备；顺便更新“最近访问”时间
    func isPaired(token: String?, address: String) -> Bool {
        guard let token, !token.isEmpty else { return false }
        let id = Self.hash(token)
        lock.lock()
        guard var device = devices[id] else {
            lock.unlock()
            return false
        }
        let now = Date()
        var changed = false
        // 每分钟最多写一次文件，避免频繁的磁盘写入
        if now.timeIntervalSince(device.lastSeen) > 60 || device.address != address {
            device.lastSeen = now
            device.address = address
            devices[id] = device
            saveLocked()
            changed = true
        }
        lock.unlock()
        if changed {
            onChange?()
        }
        return true
    }

    // MARK: - 设备管理

    var pairedDevices: [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func revoke(id: String) {
        lock.lock()
        devices[id] = nil
        saveLocked()
        lock.unlock()
        onChange?()
    }

    func revoke(token: String) {
        revoke(id: Self.hash(token))
    }

    func revokeAll() {
        lock.lock()
        devices.removeAll()
        saveLocked()
        lock.unlock()
        onChange?()
    }

    // MARK: - 工具

    private func saveLocked() {
        guard let fileURL else { return }
        let list = Array(devices.values)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// 比较耗时与内容无关，避免通过响应时间逐位猜测
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices {
            difference |= x[index] ^ y[index]
        }
        return difference == 0
    }
}

/// 根据 User-Agent 生成易读的设备名，例如“Windows · Chrome”
enum DeviceName {
    static func from(userAgent: String?) -> String {
        guard let ua = userAgent, !ua.isEmpty else { return "未知设备" }
        let system: String
        if ua.contains("iPhone") {
            system = "iPhone"
        } else if ua.contains("iPad") {
            system = "iPad"
        } else if ua.contains("Android") {
            system = "Android"
        } else if ua.contains("Windows") {
            system = "Windows"
        } else if ua.contains("Mac OS X") || ua.contains("Macintosh") {
            system = "Mac"
        } else if ua.contains("CrOS") {
            system = "ChromeOS"
        } else if ua.contains("Linux") {
            system = "Linux"
        } else {
            system = "设备"
        }

        let browser: String
        if ua.contains("Edg/") {
            browser = "Edge"
        } else if ua.contains("OPR/") || ua.contains("Opera") {
            browser = "Opera"
        } else if ua.contains("Firefox/") || ua.contains("FxiOS") {
            browser = "Firefox"
        } else if ua.contains("Chrome/") || ua.contains("CriOS") {
            browser = "Chrome"
        } else if ua.contains("Safari/") {
            browser = "Safari"
        } else {
            browser = "浏览器"
        }
        return "\(system) · \(browser)"
    }
}
