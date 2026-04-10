import Foundation
import AVFoundation
import os.log

/// Thin AVAudioPlayer wrapper that plays raw MP3 data from memory with an
/// internal FIFO queue. Callers start the first chunk with `play(data:)`
/// and append follow-ups with `enqueue(data:)`. When the current chunk
/// finishes naturally, the delegate pops the next one off the queue and
/// starts it with no audible gap (assuming the next chunk is queued in
/// time). `onFinished` fires on the main queue only when the current
/// player stops AND the queue is empty — explicit `stop()` is treated as
/// a silent cancel and does not fire the callback.
final class AudioPlayer: NSObject, AudioPlaying {
    private var player: AVAudioPlayer?
    private var queue: [Data] = []
    private let log = Logger(subsystem: Config.logSubsystem, category: "AudioPlayer")

    var onFinished: (() -> Void)?
    var isPlaying: Bool { (player?.isPlaying ?? false) || !queue.isEmpty }

    func play(data: Data) throws {
        queue.removeAll()
        try startPlaying(data: data)
    }

    func enqueue(data: Data) throws {
        if player == nil {
            try startPlaying(data: data)
        } else {
            queue.append(data)
        }
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
    }

    private func startPlaying(data: Data) throws {
        let newPlayer = try AVAudioPlayer(data: data)
        newPlayer.delegate = self
        newPlayer.prepareToPlay()
        player = newPlayer
        if !newPlayer.play() {
            log.error("AVAudioPlayer.play() returned false")
            throw AudioPlayerError.playbackFailed
        }
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.player = nil
            if self.queue.isEmpty {
                self.onFinished?()
                return
            }
            let next = self.queue.removeFirst()
            do {
                try self.startPlaying(data: next)
            } catch {
                self.log.error("Failed to start queued chunk: \(String(describing: error), privacy: .public)")
                self.queue.removeAll()
                self.onFinished?()
            }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        log.error("AVAudioPlayer decode error: \(String(describing: error), privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.queue.removeAll()
            self?.player = nil
            self?.onFinished?()
        }
    }
}

enum AudioPlayerError: Error, Equatable {
    case playbackFailed
}
