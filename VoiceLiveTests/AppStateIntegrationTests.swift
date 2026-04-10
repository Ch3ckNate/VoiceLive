import XCTest
@testable import VoiceLive

@MainActor
final class AppStateIntegrationTests: XCTestCase {
    var hotkey: MockHotkeyRegistering!
    var selection: MockSelectionCapturer!
    var synthesizer: MockSpeechSynthesizer!
    var notifications: MockNotificationPresenter!
    var state: AppState!

    override func setUp() async throws {
        try await super.setUp()
        hotkey = MockHotkeyRegistering()
        selection = MockSelectionCapturer()
        synthesizer = MockSpeechSynthesizer()
        notifications = MockNotificationPresenter()
        state = AppState(
            hotkeyManager: hotkey,
            selectionCapturer: selection,
            synthesizer: synthesizer,
            notifications: notifications
        )
    }

    override func tearDown() async throws {
        state = nil
        hotkey = nil
        selection = nil
        synthesizer = nil
        notifications = nil
        try await super.tearDown()
    }

    // MARK: - Happy path

    func test_handleHotkey_happyPath_speaksCapturedText() {
        selection.nextResult = .captured("Read this aloud")

        state.handleHotkey()

        XCTAssertEqual(selection.captureCallCount, 1)
        XCTAssertEqual(synthesizer.spokenTexts, ["Read this aloud"])
        XCTAssertEqual(synthesizer.speakCallCount, 1)
        XCTAssertEqual(state.statusItem.state, .playing)
        XCTAssertTrue(notifications.shown.isEmpty)
        XCTAssertNil(state.lastError)
    }

    func test_handleHotkey_clearsPreviousLastError() {
        state.lastError = "stale"
        selection.nextResult = .captured("fresh")

        state.handleHotkey()

        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.statusItem.state, .playing)
    }

    func test_handleHotkey_trimsWhitespaceBeforeSpeaking() {
        selection.nextResult = .captured("  hello  \n")

        state.handleHotkey()

        XCTAssertEqual(synthesizer.spokenTexts, ["hello"])
    }

    func test_synthesizerFinishCallback_returnsStateToIdle() {
        selection.nextResult = .captured("short")
        state.handleHotkey()
        XCTAssertEqual(state.statusItem.state, .playing)

        synthesizer.simulateFinish()

        XCTAssertEqual(state.statusItem.state, .idle)
    }

    // MARK: - Selection failures

    func test_handleHotkey_noSelection_notifiesAndFlashesError() {
        selection.nextResult = .noSelection

        state.handleHotkey()

        XCTAssertEqual(notifications.shown.count, 1)
        let body = notifications.shown.first?.body ?? ""
        XCTAssertTrue(body.contains("No text selected"))
        XCTAssertTrue(body.contains("⌘C"))
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(state.lastError, body)
        XCTAssertEqual(synthesizer.speakCallCount, 0)
    }

    func test_handleHotkey_notText_notifiesAndFlashesError() {
        selection.nextResult = .notText

        state.handleHotkey()

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "Selection is not text (image or file).")])
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(state.lastError, "Selection is not text (image or file).")
        XCTAssertEqual(synthesizer.speakCallCount, 0)
    }

    func test_handleHotkey_whitespaceOnlyText_notifiesAsEmptyTrim() {
        selection.nextResult = .captured("   \n\t  ")

        state.handleHotkey()

        XCTAssertEqual(notifications.shown, [.init(title: "VoiceLive", body: "Selection was empty after trimming whitespace.")])
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(state.lastError, "Selection was empty after trimming whitespace.")
        XCTAssertEqual(synthesizer.speakCallCount, 0)
    }

    func test_handleHotkey_tooLong_notifiesWithCharCount() {
        let overLimit = String(repeating: "a", count: Config.maxChars + 1)
        selection.nextResult = .captured(overLimit)

        state.handleHotkey()

        XCTAssertEqual(notifications.shown.count, 1)
        let body = notifications.shown.first?.body ?? ""
        XCTAssertTrue(body.contains("\(Config.maxChars + 1) characters"))
        XCTAssertTrue(body.contains("max \(Config.maxChars)"))
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(state.lastError, body)
        XCTAssertEqual(synthesizer.speakCallCount, 0)
    }

    // MARK: - Synthesizer error surfacing

    func test_synthesizerError_populatesLastErrorAndShowsNotification() {
        selection.nextResult = .captured("hello")
        state.handleHotkey()
        XCTAssertEqual(state.statusItem.state, .playing)

        synthesizer.simulateError("OpenAI rejected the API key (401). Check it's valid.")

        XCTAssertEqual(state.lastError, "OpenAI rejected the API key (401). Check it's valid.")
        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(
            notifications.shown.last,
            .init(title: "VoiceLive", body: "OpenAI rejected the API key (401). Check it's valid.")
        )
    }

    func test_synthesizerFinishAfterError_doesNotClobberLastErrorToIdle() {
        // The real SpeechSynthesizer fires onError then onFinished. The
        // finish callback must not reset the state back to .idle or we'd
        // lose the error immediately.
        selection.nextResult = .captured("hi")
        state.handleHotkey()
        synthesizer.simulateError("OpenAI server error (500). Try again shortly.")

        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(state.lastError, "OpenAI server error (500). Try again shortly.")
    }

    func test_handleHotkey_exactlyMaxChars_succeeds() {
        let atLimit = String(repeating: "a", count: Config.maxChars)
        selection.nextResult = .captured(atLimit)

        state.handleHotkey()

        XCTAssertEqual(synthesizer.speakCallCount, 1)
        XCTAssertEqual(state.statusItem.state, .playing)
    }

    // MARK: - Cancel-then-start interrupt rule

    func test_handleHotkey_whileSpeaking_stopsPreviousSpeech() {
        // First press starts speaking
        selection.nextResult = .captured("first")
        state.handleHotkey()
        XCTAssertEqual(state.statusItem.state, .playing)
        XCTAssertEqual(synthesizer.speakCallCount, 1)
        XCTAssertTrue(synthesizer.isSpeaking)

        // Second press stops the first and starts the second
        selection.nextResult = .captured("second")
        state.handleHotkey()

        XCTAssertEqual(synthesizer.stopCallCount, 1)
        XCTAssertEqual(synthesizer.speakCallCount, 2)
        XCTAssertEqual(synthesizer.spokenTexts, ["first", "second"])
        XCTAssertEqual(state.statusItem.state, .playing)
        XCTAssertTrue(notifications.shown.isEmpty)
    }

    // MARK: - Shutdown

    func test_shutdown_stopsSynthesizerAndUnregistersHotkey() {
        selection.nextResult = .captured("hi")
        state.handleHotkey()

        state.shutdown()

        XCTAssertEqual(synthesizer.stopCallCount, 1)
        XCTAssertEqual(hotkey.unregisterCallCount, 1)
    }

    // MARK: - Bootstrap

    func test_bootstrap_happyPath_registersHotkey() async {
        notifications.authorizationResult = true

        await state.bootstrap()

        XCTAssertEqual(notifications.authorizationCallCount, 1)
        XCTAssertEqual(hotkey.registerCallCount, 1)
    }

    func test_bootstrap_notificationDenied_stillRegistersHotkey() async {
        notifications.authorizationResult = false

        await state.bootstrap()

        // Notification permission is optional — bootstrap continues so the
        // hotkey still registers. The menu bar icon conveys errors visually.
        XCTAssertEqual(hotkey.registerCallCount, 1)
    }

    func test_bootstrap_hotkeyRegistrationFails_showsNotificationAndErrorState() async {
        notifications.authorizationResult = true
        hotkey.registerError = HotkeyError.registrationFailed(-9868)

        await state.bootstrap()

        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(notifications.shown.count, 1)
        XCTAssertTrue(notifications.shown.first?.body.contains("⌥R hotkey") == true)
        XCTAssertEqual(state.lastError, notifications.shown.first?.body)
    }

    func test_bootstrap_handlerInstallFails_showsDistinctNotification() async {
        notifications.authorizationResult = true
        hotkey.registerError = HotkeyError.handlerInstallFailed(-50)

        await state.bootstrap()

        XCTAssertEqual(state.statusItem.state, .error)
        XCTAssertEqual(notifications.shown.count, 1)
        XCTAssertTrue(notifications.shown.first?.body.contains("keyboard event handler") == true)
        XCTAssertEqual(state.lastError, notifications.shown.first?.body)
    }

    // MARK: - Hotkey callback wiring

    func test_hotkeyCallback_firesHandleHotkey() {
        selection.nextResult = .captured("wired")

        hotkey.fireHotkey()

        XCTAssertEqual(synthesizer.spokenTexts, ["wired"])
    }
}
