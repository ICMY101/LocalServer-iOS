import AVFoundation
import Foundation

/// 播放运行时 tracks 里的音乐、音效与语音。
/// 每个通道记住自己正在放的文件，文件没变就不重新解码。
final class VNAudio {
    private var players: [String: AVAudioPlayer] = [:]
    private var files: [String: String] = [:]

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    func update(tracks: [String: VNTrack], assets: GameAssets?) {
        for (channel, track) in tracks {
            guard let file = track.file, let assets else {
                stop(channel)
                continue
            }
            if files[channel] == file, let player = players[channel] {
                player.volume = Float(track.volume)
                if !player.isPlaying, track.loop { player.play() }
                continue
            }
            guard let data = assets.audioData(named: file),
                  let player = try? AVAudioPlayer(data: data) else {
                stop(channel)
                continue
            }
            players[channel]?.stop()
            player.numberOfLoops = track.loop ? -1 : 0
            player.volume = Float(track.volume)
            _ = player.prepareToPlay()
            player.play()
            players[channel] = player
            files[channel] = file
        }

        // tracks 里已经没有的通道要停掉（`stop` 指令留下的是 file = nil）
        for channel in players.keys.filter({ tracks[$0]?.file == nil }) {
            stop(channel)
        }
    }

    func stop(_ channel: String) {
        players[channel]?.stop()
        players[channel] = nil
        files[channel] = nil
    }

    func stopAll() {
        for player in players.values { player.stop() }
        players.removeAll()
        files.removeAll()
    }
}
