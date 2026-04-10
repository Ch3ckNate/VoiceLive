import Foundation
@testable import VoiceLive

// Mock collaborators for AppState integration tests. Each mock records
// what it was asked to do so tests can assert on the full pipeline.

final class MockHotkeyRegistering: HotkeyRegistering {
    var onHotkey: (() -> Void)?
    var registerCallCount = 0
    var unregisterCallCount = 0
    var registerError: Error?

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
    }

    func unregister() {
        unregisterCallCount += 1
    }

    func fireHotkey() {
        onHotkey?()
    }
}

final class MockSelectionCapturer: SelectionCapturing {
    var nextResult: SelectionCapturer.CaptureResult = .captured("Hello world")
    var captureCallCount = 0

    func capture() -> SelectionCapturer.CaptureResult {
        captureCallCount += 1
        return nextResult
    }
}

final class MockSpeechSynthesizer: SpeechSynthesizing {
    var isSpeaking: Bool = false
    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?

    var spokenTexts: [String] = []
    var speakCallCount = 0
    var stopCallCount = 0

    func speak(text: String) {
        speakCallCount += 1
        spokenTexts.append(text)
        isSpeaking = true
    }

    func stop() {
        stopCallCount += 1
        isSpeaking = false
    }

    /// Test helper: simulate natural playback completion.
    func simulateFinish() {
        isSpeaking = false
        onFinished?()
    }

    /// Test helper: simulate a synthesis/playback failure. Fires onError
    /// with the given message, then onFinished — mirrors production
    /// SpeechSynthesizer's error path.
    func simulateError(_ message: String) {
        isSpeaking = false
        onError?(message)
        onFinished?()
    }
}

final class MockTextToSpeechClient: TextToSpeechClient {
    var nextResult: Result<Data, Error> = .success(Data([0xFF, 0xFB])) // minimal MP3-ish bytes
    var synthesizeCallCount = 0
    var lastText: String?

    func synthesize(text: String) async throws -> Data {
        synthesizeCallCount += 1
        lastText = text
        switch nextResult {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}

final class MockAudioPlayer: AudioPlaying {
    var isPlaying: Bool = false
    var onFinished: (() -> Void)?

    var playedDataHistory: [Data] = []
    var enqueuedDataHistory: [Data] = []
    var playCallCount = 0
    var enqueueCallCount = 0
    var stopCallCount = 0
    var nextPlayError: Error?
    var nextEnqueueError: Error?

    func play(data: Data) throws {
        playCallCount += 1
        playedDataHistory.append(data)
        if let error = nextPlayError {
            nextPlayError = nil
            throw error
        }
        isPlaying = true
    }

    func enqueue(data: Data) throws {
        enqueueCallCount += 1
        enqueuedDataHistory.append(data)
        if let error = nextEnqueueError {
            nextEnqueueError = nil
            throw error
        }
        isPlaying = true
    }

    func stop() {
        stopCallCount += 1
        isPlaying = false
    }

    /// Test helper: simulate natural playback completion.
    func simulateFinish() {
        isPlaying = false
        onFinished?()
    }
}

final class MockNotificationPresenter: NotificationPresenting {
    struct Shown: Equatable {
        let title: String
        let body: String
    }
    var shown: [Shown] = []
    var authorizationResult: Bool = true
    var authorizationCallCount = 0

    func show(title: String, body: String) {
        shown.append(Shown(title: title, body: body))
    }

    func requestAuthorization() async -> Bool {
        authorizationCallCount += 1
        return authorizationResult
    }
}
