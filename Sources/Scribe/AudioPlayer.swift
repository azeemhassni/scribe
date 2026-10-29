import AVFoundation
import Foundation
import MediaPlayer

/// Playback for a meeting's mixed recording, kept in step with the transcript.
@MainActor
final class AudioPlayer: NSObject, ObservableObject {

    /// Matches the jump buttons in the player bar, so the keyboard and the UI
    /// move by the same amount.
    static let skipBackSeconds: TimeInterval = 10
    static let skipForwardSeconds: TimeInterval = 15

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoaded = false

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var title = ""
    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    func load(_ url: URL?, title: String) {
        stop()
        self.title = title
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
        publishNowPlaying()
    }

    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta) }

    func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTicking()
        registerRemoteCommands()
        publishNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
        publishNowPlaying()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        stopTicking()
        clearNowPlaying()
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

    // MARK: - Now Playing

    /// macOS routes the keyboard's play/pause key, Control Centre and headset
    /// buttons to whichever app currently holds Now Playing, so a player that
    /// never registers simply cannot be driven from any of them.
    ///
    /// Registration waits for the first actual play rather than happening on
    /// load: claiming Now Playing would take the media keys away from Music or
    /// a browser tab every time a meeting is merely opened to read.
    private func registerRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        func add(_ command: MPRemoteCommand,
                 _ body: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            remoteTargets.append((command, command.addTarget(handler: body)))
        }

        add(center.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        add(center.playCommand) { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        add(center.pauseCommand) { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        add(center.stopCommand) { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackSeconds)]
        add(center.skipBackwardCommand) { [weak self] _ in
            Task { @MainActor in self?.skip(-Self.skipBackSeconds) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForwardSeconds)]
        add(center.skipForwardCommand) { [weak self] _ in
            Task { @MainActor in self?.skip(Self.skipForwardSeconds) }
            return .success
        }

        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }

        // A recording is a single item; live track controls would do nothing.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func unregisterRemoteCommands() {
        for (command, token) in remoteTargets { command.removeTarget(token) }
        remoteTargets.removeAll()
    }

    /// The system extrapolates the playhead from the rate and the elapsed time
    /// it was last given, so this only needs calling when playback actually
    /// changes — not on every tick.
    private func publishNowPlaying() {
        guard !remoteTargets.isEmpty, let player else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Scribe",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        // macOS will not hand the media keys to a player that leaves the
        // playback state unset, however complete the rest of the info is.
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func clearNowPlaying() {
        guard !remoteTargets.isEmpty else { return }
        unregisterRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.player?.currentTime = 0
            // Without this the ticker keeps running past the end and puts the
            // playhead straight back to where it stopped.
            self.stopTicking()
            self.publishNowPlaying()
        }
    }
}
