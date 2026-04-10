import Foundation

// Protocols used by AppState for dependency injection. Production code
// uses the concrete types; tests substitute mocks.

protocol HotkeyRegistering: AnyObject {
    var onHotkey: (() -> Void)? { get set }
    func register() throws
    func unregister()
}

protocol SelectionCapturing {
    func capture() -> SelectionCapturer.CaptureResult
}

protocol TextSynthesizing {
    func synthesize(text: String) async throws -> Data
}

protocol AudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    var onFinished: (() -> Void)? { get set }
    func play(data: Data) throws
    func stop()
}

protocol NotificationPresenting {
    func show(title: String, body: String)
    func requestAuthorization() async -> Bool
}
