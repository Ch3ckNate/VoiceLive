import Foundation
import os.log

/// Orchestrates a chunked two-stage TTS pipeline: split the input text
/// into sentence-sized chunks, fetch MP3 audio for each chunk from an
/// injected TextToSpeechClient, and feed chunks into an injected
/// AudioPlaying instance that queues and plays them in order.
///
/// Why chunking: OpenAI's /audio/speech returns the full MP3 in one shot,
/// so for a long paragraph the user waits ~10s before hearing anything.
/// By splitting into sentence-sized chunks we can start playing chunk 1
/// as soon as it arrives (~1s) while the remaining chunks fetch in the
/// background. Fetches are sequential so the API isn't hit with a burst,
/// but chunk 1 plays while chunks 2..N download, so the gaps stay small.
///
/// Threading: all public methods and mutable state are touched on the
/// main actor. AppState (the only caller) is @MainActor. Network work
/// runs inside a detached Task; we hop back to MainActor.run to mutate
/// state and talk to the player.
final class SpeechSynthesizer: SpeechSynthesizing {
    static let defaultChunkTargetSize: Int = 200

    private let client: any TextToSpeechClient
    private let player: any AudioPlaying
    private let chunkTargetSize: Int
    private let log = Logger(subsystem: Config.logSubsystem, category: "SpeechSynthesizer")

    private var fetchTask: Task<Void, Never>?

    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?
    var isSpeaking: Bool { fetchTask != nil || player.isPlaying }

    init(
        client: any TextToSpeechClient = OpenAIClient(),
        player: any AudioPlaying = AudioPlayer(),
        chunkTargetSize: Int = SpeechSynthesizer.defaultChunkTargetSize
    ) {
        self.client = client
        self.player = player
        self.chunkTargetSize = chunkTargetSize
        self.player.onFinished = { [weak self] in
            guard let self else { return }
            // Only bubble up "speech finished" once the whole pipeline is
            // quiet. If the fetch loop is still going, another chunk is
            // on its way and will restart playback via enqueue().
            if self.fetchTask == nil {
                self.onFinished?()
            }
        }
    }

    func speak(text: String) {
        fetchTask?.cancel()
        if player.isPlaying {
            player.stop()
        }

        let chunks = Self.chunk(text: text, targetSize: chunkTargetSize)
        guard !chunks.isEmpty else {
            log.info("No chunks to speak — text was empty after trimming")
            onFinished?()
            return
        }

        log.info("Speaking \(text.count, privacy: .public) chars in \(chunks.count, privacy: .public) chunk(s)")
        let client = self.client
        let startTime = Date()

        fetchTask = Task { [weak self] in
            for (index, chunk) in chunks.enumerated() {
                let chunkStart = Date()
                let isFirst = index == 0
                let isLast = index == chunks.count - 1
                do {
                    let audio = try await client.synthesize(text: chunk)
                    if Task.isCancelled { return }
                    let chunkElapsed = Date().timeIntervalSince(chunkStart)
                    let totalElapsed = Date().timeIntervalSince(startTime)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.log.info("Chunk \(index + 1, privacy: .public)/\(chunks.count, privacy: .public) fetched in \(String(format: "%.2f", chunkElapsed), privacy: .public)s")
                        if isFirst {
                            self.log.info("Time to first audio: \(String(format: "%.2f", totalElapsed), privacy: .public)s")
                        }
                        self.handleChunk(audio: audio, isFirst: isFirst)
                        if isLast {
                            self.fetchTask = nil
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { [weak self] in
                        self?.handleSynthesisError(error)
                    }
                    return
                }
            }
        }
    }

    func stop() {
        log.info("Stop requested")
        fetchTask?.cancel()
        fetchTask = nil
        if player.isPlaying {
            player.stop()
        }
    }

    private func handleChunk(audio: Data, isFirst: Bool) {
        do {
            if isFirst {
                try player.play(data: audio)
            } else {
                try player.enqueue(data: audio)
            }
        } catch {
            log.error("Playback start failed: \(String(describing: error), privacy: .public)")
            fetchTask?.cancel()
            fetchTask = nil
            onError?(Self.playbackMessage(for: error))
            onFinished?()
        }
    }

    private func handleSynthesisError(_ error: Error) {
        log.error("Synthesis failed: \(String(describing: error), privacy: .public)")
        fetchTask = nil
        onError?(Self.synthesisMessage(for: error))
        onFinished?()
    }

    /// Map a synthesis-side (network / HTTP) error to a short, actionable
    /// sentence for the menu bar dropdown.
    static func synthesisMessage(for error: Error) -> String {
        if let openAI = error as? OpenAIError {
            return openAI.userMessage
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Network error: \(nsError.localizedDescription)"
        }
        return "Synthesis failed: \(nsError.localizedDescription)"
    }

    /// Map a playback-side error (AVAudioPlayer init / play) to a short,
    /// actionable sentence for the menu bar dropdown.
    static func playbackMessage(for error: Error) -> String {
        if let player = error as? AudioPlayerError {
            switch player {
            case .playbackFailed:
                return "Audio playback failed. The decoded audio may be invalid."
            }
        }
        return "Audio playback failed: \((error as NSError).localizedDescription)"
    }

    /// Split `text` into chunks of at most `targetSize` characters, never
    /// breaking a sentence. Sentences are packed greedily: the current
    /// chunk grows until adding the next sentence would exceed the
    /// target, then a new chunk starts. A single sentence longer than
    /// `targetSize` becomes its own chunk untouched — splitting
    /// mid-sentence produces unnatural prosody.
    static func chunk(text: String, targetSize: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""

        trimmed.enumerateSubstrings(
            in: trimmed.startIndex..<trimmed.endIndex,
            options: .bySentences
        ) { substring, _, _, _ in
            guard let sentence = substring?.trimmingCharacters(in: .whitespaces),
                  !sentence.isEmpty else { return }
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= targetSize {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [trimmed] : chunks
    }
}
