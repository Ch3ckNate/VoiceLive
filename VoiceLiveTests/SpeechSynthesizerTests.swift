import XCTest
@testable import VoiceLive

@MainActor
final class SpeechSynthesizerTests: XCTestCase {
    var client: MockTextToSpeechClient!
    var player: MockAudioPlayer!
    var synth: SpeechSynthesizer!

    override func setUp() async throws {
        try await super.setUp()
        client = MockTextToSpeechClient()
        player = MockAudioPlayer()
        synth = SpeechSynthesizer(client: client, player: player)
    }

    override func tearDown() async throws {
        synth = nil
        client = nil
        player = nil
        try await super.tearDown()
    }

    // MARK: - Happy path

    func test_speak_fetchesAudioThenStartsPlayback() async {
        synth.speak(text: "hello")

        await waitUntil { self.player.playCallCount == 1 }

        XCTAssertEqual(client.synthesizeCallCount, 1)
        XCTAssertEqual(client.lastText, "hello")
        XCTAssertEqual(player.playCallCount, 1)
        XCTAssertTrue(player.isPlaying)
    }

    func test_playerFinish_firesOnFinished() async {
        var finishCount = 0
        synth.onFinished = { finishCount += 1 }

        synth.speak(text: "hi")
        await waitUntil { self.player.playCallCount == 1 }

        player.simulateFinish()

        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(synth.isSpeaking)
    }

    // MARK: - isSpeaking semantics

    func test_isSpeaking_trueImmediatelyAfterSpeak() {
        synth.speak(text: "x")
        // fetchTask is set synchronously in speak() before the first await,
        // so isSpeaking should be true immediately.
        XCTAssertTrue(synth.isSpeaking)
    }

    func test_isSpeaking_falseAfterPlayerFinishes() async {
        synth.speak(text: "done")
        await waitUntil { self.player.playCallCount == 1 }
        player.simulateFinish()
        XCTAssertFalse(synth.isSpeaking)
    }

    // MARK: - Stop

    func test_stop_cancelsFetchAndStopsPlayer() async {
        synth.speak(text: "hi")
        await waitUntil { self.player.playCallCount == 1 }
        XCTAssertTrue(synth.isSpeaking)

        synth.stop()

        XCTAssertEqual(player.stopCallCount, 1)
        XCTAssertFalse(synth.isSpeaking)
    }

    // MARK: - Cancel-then-start

    func test_speak_whilePlaying_stopsPlayerBeforeStartingNewFetch() async {
        synth.speak(text: "first")
        await waitUntil { self.player.playCallCount == 1 }

        synth.speak(text: "second")
        await waitUntil { self.player.playCallCount == 2 }

        XCTAssertEqual(player.stopCallCount, 1) // explicit stop before the second speak
        XCTAssertEqual(client.synthesizeCallCount, 2)
        XCTAssertEqual(player.playCallCount, 2)
        XCTAssertEqual(client.lastText, "second")
    }

    // MARK: - Error paths

    func test_synthesisError_firesOnFinished() async {
        var finishCount = 0
        synth.onFinished = { finishCount += 1 }
        client.nextResult = .failure(OpenAIError.unauthorized)

        synth.speak(text: "oops")

        await waitUntil { finishCount == 1 }
        XCTAssertEqual(player.playCallCount, 0)
        XCTAssertFalse(synth.isSpeaking)
    }

    func test_synthesisError_firesOnErrorWithMappedMessage() async {
        var errorMessages: [String] = []
        synth.onError = { errorMessages.append($0) }
        client.nextResult = .failure(OpenAIError.unauthorized)

        synth.speak(text: "oops")

        await waitUntil { !errorMessages.isEmpty }
        XCTAssertEqual(errorMessages, [OpenAIError.unauthorized.userMessage])
    }

    func test_synthesisError_networkError_mapsToNetworkMessage() async {
        var errorMessages: [String] = []
        synth.onError = { errorMessages.append($0) }
        let networkError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )
        client.nextResult = .failure(networkError)

        synth.speak(text: "offline")

        await waitUntil { !errorMessages.isEmpty }
        XCTAssertEqual(errorMessages.count, 1)
        XCTAssertTrue(errorMessages[0].hasPrefix("Network error:"))
        XCTAssertTrue(errorMessages[0].contains("offline"))
    }

    func test_playbackError_firesOnFinished() async {
        var finishCount = 0
        synth.onFinished = { finishCount += 1 }
        player.nextPlayError = AudioPlayerError.playbackFailed

        synth.speak(text: "bad data")

        await waitUntil { finishCount == 1 }
        XCTAssertEqual(player.playCallCount, 1)
        XCTAssertFalse(synth.isSpeaking)
    }

    func test_playbackError_firesOnErrorWithMappedMessage() async {
        var errorMessages: [String] = []
        synth.onError = { errorMessages.append($0) }
        player.nextPlayError = AudioPlayerError.playbackFailed

        synth.speak(text: "bad data")

        await waitUntil { !errorMessages.isEmpty }
        XCTAssertEqual(errorMessages.count, 1)
        XCTAssertTrue(errorMessages[0].contains("Audio playback failed"))
    }

    // MARK: - Chunking

    func test_chunk_emptyText_returnsEmpty() {
        XCTAssertEqual(SpeechSynthesizer.chunk(text: "", targetSize: 200), [])
        XCTAssertEqual(SpeechSynthesizer.chunk(text: "   \n\t", targetSize: 200), [])
    }

    func test_chunk_singleShortSentence_returnsOneChunk() {
        let result = SpeechSynthesizer.chunk(text: "Hello world.", targetSize: 200)
        XCTAssertEqual(result, ["Hello world."])
    }

    func test_chunk_manyShortSentences_packsIntoFewerChunks() {
        let text = "First sentence. Second sentence. Third sentence. Fourth sentence."
        let result = SpeechSynthesizer.chunk(text: text, targetSize: 200)
        // All four fit in a single chunk at 200 chars.
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("First"))
        XCTAssertTrue(result[0].contains("Fourth"))
    }

    func test_chunk_exceedsTarget_splitsOnSentenceBoundary() {
        // Each sentence ~25 chars, target 40 → ~1-2 sentences per chunk.
        let text = "Sentence one is here. Sentence two is here. Sentence three is here. Sentence four is here."
        let result = SpeechSynthesizer.chunk(text: text, targetSize: 40)
        XCTAssertGreaterThan(result.count, 1)
        // Each chunk should still end cleanly at a sentence boundary.
        for chunk in result {
            XCTAssertTrue(chunk.hasSuffix("."), "Chunk did not end on sentence boundary: \(chunk)")
        }
    }

    func test_chunk_longSingleSentence_becomesOneChunk() {
        // Single sentence longer than target — don't butcher it.
        let long = String(repeating: "a ", count: 200) + "end."
        let result = SpeechSynthesizer.chunk(text: long, targetSize: 50)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Chunked playback

    /// Build a synthesizer with a tiny chunk target so short, clean test
    /// text actually chunks. The default 200-char target would merge
    /// these into a single chunk.
    private func makeChunkingSynth(targetSize: Int = 30) -> SpeechSynthesizer {
        SpeechSynthesizer(client: client, player: player, chunkTargetSize: targetSize)
    }

    func test_speak_multiChunkText_playsFirstEnqueuesRest() async {
        let chunkingSynth = makeChunkingSynth()
        client.nextResult = .success(Data([0xAA]))
        // Each sentence ~25 chars; target 30 forces one sentence per chunk.
        let text = "First sentence is here. Second sentence is here. Third sentence is here."
        chunkingSynth.speak(text: text)

        await waitUntil {
            self.client.synthesizeCallCount >= 3
        }

        // Exactly one play() call for the first chunk; the rest go through enqueue().
        XCTAssertEqual(player.playCallCount, 1)
        XCTAssertGreaterThanOrEqual(player.enqueueCallCount, 2)
        XCTAssertEqual(client.synthesizeCallCount, player.playCallCount + player.enqueueCallCount)
    }

    func test_speak_multiChunk_onFinishedOnlyAfterAllChunksDone() async {
        let chunkingSynth = makeChunkingSynth()
        var finishCount = 0
        chunkingSynth.onFinished = { finishCount += 1 }

        let text = "First sentence is here. Second sentence is here."
        chunkingSynth.speak(text: text)

        await waitUntil { self.client.synthesizeCallCount >= 2 }

        // After the last chunk has been handed to the player, fetchTask is
        // nil. The mock player does not auto-advance, so simulateFinish
        // here represents "the full queue is drained". The synthesizer
        // should now surface onFinished.
        player.simulateFinish()
        XCTAssertEqual(finishCount, 1)
    }

    // MARK: - Helpers

    /// Poll a predicate on the main actor until it's true or we time out.
    /// Used to wait for the async fetchTask to complete its MainActor hop.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ predicate: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        XCTFail("waitUntil timed out after \(timeout)s")
    }
}
