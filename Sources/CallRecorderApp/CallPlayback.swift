import AVFoundation
import CallRecorderCore
import Foundation
import Observation

/// One call's recording, played from a millisecond.
///
/// The timeline draws a playhead that has to move while the audio runs, and a task that awaited
/// each position would queue work behind the audio it is describing. The position is read from the
/// player instead, twenty times a second, on the main run loop.
@MainActor
@Observable
final class CallPlayback {
    private(set) var url: URL?
    private(set) var durationMs: Int = 0
    private(set) var positionMs: Int = 0
    private(set) var isPlaying = false
    /// What went wrong when the recording could not be opened, if anything.
    private(set) var failure: String?

    /// How often the player is read while it is running.
    static let tickInterval: TimeInterval = 0.05

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// Opens the recording, and does nothing when it is the one already open.
    func load(_ url: URL) {
        guard self.url != url else { return }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            self.url = url
            durationMs = Int((player.duration * 1_000).rounded())
            failure = nil
        } catch {
            // A recording that cannot be opened is not a broken window: the timeline still draws
            // what was said, and the cards still work. The row says which part cannot be done.
            player = nil
            self.url = url
            durationMs = 0
            failure = error.localizedDescription
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if positionMs >= durationMs { seek(toMs: 0) }
        player.play()
        isPlaying = true
        startTicking()
    }

    /// Plays from a millisecond, which is what a click on a bar asks for.
    func play(fromMs milliseconds: Int) {
        seek(toMs: milliseconds)
        play()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    func seek(toMs milliseconds: Int) {
        guard durationMs > 0 else {
            positionMs = 0
            return
        }
        let clamped = min(max(0, milliseconds), durationMs)
        positionMs = clamped
        player?.currentTime = Double(clamped) / 1_000
    }

    func stop() {
        pause()
        positionMs = 0
        player?.currentTime = 0
    }

    private func startTicking() {
        stopTicking()
        let ticker = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readPosition() }
        }
        // The common mode is what keeps the playhead moving while the user scrolls the timeline,
        // and a playhead that stops when the pointer moves is the one case this cannot have.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Reads the position out of the player, and notices the end of the recording.
    private func readPosition() {
        guard let player else { return }
        positionMs = min(Int((player.currentTime * 1_000).rounded()), durationMs)
        guard isPlaying, !player.isPlaying else { return }
        isPlaying = false
        positionMs = durationMs
        stopTicking()
    }
}
