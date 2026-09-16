import AVFoundation
import Foundation

/// Playback for a meeting's mixed recording, kept in step with the transcript.
@MainActor
final class AudioPlayer: NSObject, ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoaded = false

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func load(_ url: URL?) {
        stop()
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else {
            isLoaded = false
            duration = 0
            return
        }
        player.prepareToPlay()
        player.delegate = self
        self.player = player
        duration = player.duration
        currentTime = 0
        isLoaded = true
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { pause() } else { resume() }
    }

    func play(from time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
        resume()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
    }

    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta) }

    func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        stopTicking()
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
        }
    }
}
