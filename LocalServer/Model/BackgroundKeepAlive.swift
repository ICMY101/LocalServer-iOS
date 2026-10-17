import AVFoundation

/// 循环播放一段静音音频，让 App 在后台保持运行，服务器不被挂起。
/// 需要 Info.plist 中的 UIBackgroundModes = audio。
/// 注意：上架 App Store 可能因此被拒，仅建议自用。
final class BackgroundKeepAlive {
    private var player: AVAudioPlayer?

    var isActive: Bool { player != nil }

    func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV())
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            print("BackgroundKeepAlive 启动失败：\(error)")
        }
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 生成 1 秒 8kHz 16bit 单声道的静音 WAV
    private static func silentWAV(sampleRate: UInt32 = 8000) -> Data {
        let dataSize = sampleRate * 2
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
    }
}
