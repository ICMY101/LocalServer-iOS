import AVFoundation

/// 循环播放一段静音音频，让 App 在后台保持运行，服务器不被挂起。
/// 需要 Info.plist 中的 UIBackgroundModes = audio。
///
/// 省电措施：
/// - 只在 App 进入后台时播放，回到前台立即停止（由 ServerManager 控制）
/// - 请求较大的音频 IO 缓冲，减少音频硬件唤醒 CPU 的次数
/// - 与其他 App 的声音混合，不打断音乐播放
/// - 被电话等打断后自动恢复，避免保活悄悄失效
///
/// 注意：上架 App Store 可能因此被拒，仅建议自用。
final class BackgroundKeepAlive {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool { player != nil }

    /// 开始播放，返回是否成功
    @discardableResult
    func start() -> Bool {
        if let player {
            if !player.isPlaying {
                player.play()
            }
            return player.isPlaying
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setPreferredIOBufferDuration(0.5)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV)
            player.numberOfLoops = -1
            player.volume = 0
            guard player.play() else {
                try? session.setActive(false)
                return false
            }
            self.player = player
            observeSession()
            return true
        } catch {
            print("BackgroundKeepAlive 启动失败：\(error)")
            return false
        }
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // 电话、闹钟等打断结束后恢复播放
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.resume()
        })
        // 系统音频服务重置后需要重新创建播放器
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restart()
        })
    }

    private func resume() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    private func restart() {
        guard player != nil else { return }
        stop()
        start()
    }

    /// 5 秒的静音 WAV（8kHz、16bit、单声道），循环时唤醒次数更少
    private static let silentWAV: Data = {
        let sampleRate: UInt32 = 8000
        let dataSize = sampleRate * 2 * 5
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))          // fmt 块大小
        append(UInt16(1))           // PCM
        append(UInt16(1))           // 单声道
        append(sampleRate)
        append(sampleRate * 2)      // 字节率
        append(UInt16(2))           // 块对齐
        append(UInt16(16))          // 位深
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }()
}
