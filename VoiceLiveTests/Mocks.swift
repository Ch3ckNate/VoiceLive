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

final class MockSynthesizer: TextSynthesizing, @unchecked Sendable {
    var stub: @Sendable (String) async throws -> Data = { _ in Data([0x01, 0x02, 0x03]) }
    var receivedTexts: [String] = []

    func synthesize(text: String) async throws -> Data {
        receivedTexts.append(text)
        return try await stub(text)
    }
}

final class MockAudioPlayer: AudioPlaying {
    var isPlaying: Bool = false
    var onFinished: (() -> Void)?
    var playCallCount = 0
    var stopCallCount = 0
    var receivedData: [Data] = []
    var playError: Error?

    func play(data: Data) throws {
        playCallCount += 1
        receivedData.append(data)
        if let playError { throw playError }
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
