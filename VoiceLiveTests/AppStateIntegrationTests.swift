import XCTest
@testable import VoiceLive

@MainActor
final class AppStateIntegrationTests: XCTestCase {
    var hotkey: MockHotkeyRegistering!
    var selection: MockSelectionCapturer!
    var synthesizer: MockSynthesizer!
    var audio: MockAudioPlayer!
    var notifications: MockNotificationPresenter!
    var state: AppState!

    override func setUp() async throws {
        try await super.setUp()
        hotkey = MockHotkeyRegistering()
        selection = MockSelectionCapturer()
        synthesizer = MockSynthesizer()
        audio = MockAudioPlayer()
        notifications = MockNotificationPresenter()
        state = AppState(
            hotkeyManager: hotkey,
            selectionCapturer: selection,
            synthesizer: synthesizer,
            audioPlayer: audio,
            notifications: notifications
        )
    }

    override func tearDown() async throws {
        state = nil
        hotkey = nil
        selection = nil
        synthesizer = nil
        audio = nil
        notifications = nil
        try await super.tearDown()
    }

    // MARK: - Happy path

    func test_handleHotkey_happyPath_runsFullPipeline() async {
        let expectedAudio = Data([0xFF, 0xFB, 0x90, 0x01])
        selection.nextResult = .captured("Read this aloud")
        synthesizer.stub = { _ in expectedAudio }

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(selection.captureCallCount, 1)
        XCTAssertEqual(synthesizer.receivedTexts, ["Read this aloud"])
        XCTAssertEqual(audio.receivedData, [expectedAudio])
        XCTAssertEqual(audio.playCallCount, 1)
        XCTAssertEqual(state.statusItem.state, .playing)
        XCTAssertTrue(notifications.shown.isEmpty)
    }

    func test_handleHotkey_trimsWhitespaceBeforeSendingToSynthesizer() async {
        selection.nextResult = .captured("  hello  \n")

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(synthesizer.receivedTexts, ["hello"])
    }

    func test_audioPlayerFinishCallback_returnsStateToIdle() async {
        selection.nextResult = .captured("short")
        state.handleHotkey()
        await state.inFlightTask?.value
        XCTAssertEqual(state.statusItem.state, .playing)

        audio.simulateFinish()

        XCTAssertEqual(state.statusItem.state, .idle)
    }

    // MARK: - Selection failures

    func test_handleHotkey_noSelection_notifiesAndFlashesError() async {
        selection.nextResult = .noSelection

        state.handleHotkey()

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "No text selected.")])
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(synthesizer.receivedTexts, [])
        XCTAssertEqual(audio.playCallCount, 0)
    }

    func test_handleHotkey_notText_notifiesAndFlashesError() async {
        selection.nextResult = .notText

        state.handleHotkey()

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "Selection is not text.")])
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(synthesizer.receivedTexts, [])
    }

    func test_handleHotkey_whitespaceOnlyText_notifiesAsNoSelection() async {
        selection.nextResult = .captured("   \n\t  ")

        state.handleHotkey()

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "No text selected.")])
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(synthesizer.receivedTexts, [])
    }

    func test_handleHotkey_tooLong_notifiesWithCharCount() async {
        let overLimit = String(repeating: "a", count: Config.maxChars + 1)
        selection.nextResult = .captured(overLimit)

        state.handleHotkey()

        XCTAssertEqual(notifications.shown.count, 1)
        let body = notifications.shown.first?.body ?? ""
        XCTAssertTrue(body.contains("\(Config.maxChars + 1) characters"))
        XCTAssertTrue(body.contains("max \(Config.maxChars)"))
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(synthesizer.receivedTexts, [])
    }

    func test_handleHotkey_exactlyMaxChars_succeeds() async {
        let atLimit = String(repeating: "a", count: Config.maxChars)
        selection.nextResult = .captured(atLimit)

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(synthesizer.receivedTexts.count, 1)
        XCTAssertEqual(state.statusItem.state, .playing)
    }

    // MARK: - Synthesizer error catalog

    func test_handleHotkey_invalidApiKey_mapsToCorrectNotification() async {
        selection.nextResult = .captured("hi")
        synthesizer.stub = { _ in throw ElevenLabsError.invalidApiKey }

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "ElevenLabs: invalid API key.")])
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(audio.playCallCount, 0)
    }

    func test_handleHotkey_rateLimited_mapsToCorrectNotification() async {
        selection.nextResult = .captured("hi")
        synthesizer.stub = { _ in throw ElevenLabsError.rateLimited }

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(
            notifications.shown,
            [.init(title: "VoiceLive", body: "ElevenLabs: rate limited. Try again in a moment.")]
        )
        XCTAssertEqual(state.statusItem.state, .error)
    }

    func test_handleHotkey_httpError_includesStatusCodeInNotification() async {
        selection.nextResult = .captured("hi")
        synthesizer.stub = { _ in throw ElevenLabsError.httpError(503) }

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "ElevenLabs error: HTTP 503.")])
        XCTAssertEqual(state.statusItem.state, .error)
    }

    func test_handleHotkey_networkError_includesMessageInNotification() async {
        selection.nextResult = .captured("hi")
        synthesizer.stub = { _ in throw ElevenLabsError.networkError("offline") }

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "Network error: offline.")])
        XCTAssertEqual(state.statusItem.state, .error)
    }

    func test_handleHotkey_emptyResponse_mapsToCorrectNotification() async {
        selection.nextResult = .captured("hi")
        synthesizer.stub = { _ in throw ElevenLabsError.emptyResponse }

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(
            notifications.shown,
            [.init(title: "VoiceLive", body: "ElevenLabs returned an empty response.")]
        )
        XCTAssertEqual(state.statusItem.state, .error)
    }

    func test_handleHotkey_unknownError_mapsToGenericPlaybackFailedNotification() async {
        struct WeirdError: Error {}
        selection.nextResult = .captured("hi")
        synthesizer.stub = { _ in throw WeirdError() }

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "Audio playback failed.")])
        XCTAssertEqual(state.statusItem.state, .error)
    }

    func test_handleHotkey_audioPlayerThrows_mapsToGenericPlaybackFailed() async {
        struct PlaybackFailed: Error {}
        selection.nextResult = .captured("hi")
        synthesizer.stub = { _ in Data([0x01]) }
        audio.playError = PlaybackFailed()

        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "Audio playback failed.")])
        XCTAssertEqual(state.statusItem.state, .error)
    }

    // MARK: - Cancel-then-start interrupt rule

    func test_cancelThenStart_secondPressSupersedesFirst() async {
        // First press: slow synth that will be cancelled
        selection.nextResult = .captured("first")
        synthesizer.stub = { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            return Data([0xAA])
        }

        state.handleHotkey()
        let firstTask = state.inFlightTask

        // Second press: fast synth that should win
        selection.nextResult = .captured("second")
        synthesizer.stub = { _ in Data([0xBB]) }
        state.handleHotkey()
        let secondTask = state.inFlightTask

        // Both tasks should complete (first via cancellation, second normally)
        await firstTask?.value
        await secondTask?.value

        // Only the second press reached the audio player
        XCTAssertEqual(audio.receivedData, [Data([0xBB])])
        XCTAssertEqual(audio.playCallCount, 1)
        XCTAssertEqual(state.statusItem.state, .playing)
        // No cancellation notification shown (cancel is silent)
        XCTAssertTrue(notifications.shown.isEmpty)
    }

    func test_handleHotkey_whileAudioIsPlaying_stopsPreviousAudio() async {
        // First press completes normally
        selection.nextResult = .captured("first")
        synthesizer.stub = { _ in Data([0xAA]) }
        state.handleHotkey()
        await state.inFlightTask?.value
        XCTAssertEqual(state.statusItem.state, .playing)
        XCTAssertEqual(audio.playCallCount, 1)

        // audio.isPlaying is true from the mock play()
        XCTAssertTrue(audio.isPlaying)

        // Second press should stop the audio before doing anything else
        selection.nextResult = .captured("second")
        synthesizer.stub = { _ in Data([0xBB]) }
        state.handleHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(audio.playCallCount, 2)
        XCTAssertEqual(audio.receivedData, [Data([0xAA]), Data([0xBB])])
    }

    // MARK: - Shutdown

    func test_shutdown_cancelsInFlightTaskStopsAudioUnregistersHotkey() async {
        selection.nextResult = .captured("hi")
        synthesizer.stub = { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            return Data([0x01])
        }
        state.handleHotkey()
        let task = state.inFlightTask
        XCTAssertNotNil(task)

        state.shutdown()
        await task?.value

        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(hotkey.unregisterCallCount, 1)
        XCTAssertEqual(audio.playCallCount, 0) // synth was cancelled before play
    }

    // MARK: - Bootstrap

    func test_bootstrap_happyPath_registersHotkey() async {
        notifications.authorizationResult = true

        await state.bootstrap()

        XCTAssertEqual(notifications.authorizationCallCount, 1)
        XCTAssertEqual(hotkey.registerCallCount, 1)
    }

    func test_bootstrap_notificationDenied_bailsWithErrorState() async {
        notifications.authorizationResult = false

        await state.bootstrap()

        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(hotkey.registerCallCount, 0)
    }

    func test_bootstrap_hotkeyRegistrationFails_showsNotificationAndErrorState() async {
        notifications.authorizationResult = true
        hotkey.registerError = HotkeyError.registrationFailed(-9868)

        await state.bootstrap()

        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(notifications.shown.count, 1)
        XCTAssertTrue(notifications.shown.first?.body.contains("⌥R hotkey") == true)
    }

    func test_bootstrap_handlerInstallFails_showsDistinctNotification() async {
        notifications.authorizationResult = true
        hotkey.registerError = HotkeyError.handlerInstallFailed(-50)

        await state.bootstrap()

        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(notifications.shown.count, 1)
        XCTAssertTrue(notifications.shown.first?.body.contains("keyboard event handler") == true)
    }

    // MARK: - Hotkey callback wiring

    func test_hotkeyCallback_firesHandleHotkey() async {
        selection.nextResult = .captured("wired")
        synthesizer.stub = { _ in Data([0x42]) }

        hotkey.fireHotkey()
        await state.inFlightTask?.value

        XCTAssertEqual(synthesizer.receivedTexts, ["wired"])
        XCTAssertEqual(audio.receivedData, [Data([0x42])])
    }
}
