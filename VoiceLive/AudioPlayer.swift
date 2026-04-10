import Foundation
import AVFoundation

/// Plays audio data via AVAudioPlayer. The AVAudioPlayer instance is held
/// as a stored property for the entire playback duration — if it were a
/// local variable, ARC would deallocate it immediately and playback would
/// cut off within a fraction of a second.
final class AudioPlayer: NSObject {
    private var player: AVAudioPlayer?

    /// Callback fired on the main thread when playback completes naturally
    /// (not when explicitly stopped via `stop()`).
    var onFinished: (() -> Void)?

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    func play(data: Data) throws {
        let p = try AVAudioPlayer(data: data)
        p.delegate = self
        p.prepareToPlay()
        p.play()
        self.player = p
    }

    /// Stop playback immediately. Does NOT fire `onFinished`.
    func stop() {
        player?.stop()
        player = nil
    }
}

extension AudioPlayer: AudioPlaying {}

extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.player = nil
            self?.onFinished?()
        }
    }
}
