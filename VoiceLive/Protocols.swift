import Foundation
import AppKit

// Protocols used by AppState for dependency injection. Production code
// uses the concrete types; tests substitute mocks.

protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PasteboardAccess {}

protocol HotkeyRegistering: AnyObject {
    var onHotkey: (() -> Void)? { get set }
    func register() throws
    func unregister()
}

protocol SelectionCapturing {
    func capture() -> SelectionCapturer.CaptureResult
}

/// High-level "speak this text" abstraction used by AppState. Concrete
/// implementation composes an OpenAI TTS client and an audio player.
/// `onError` fires with a user-facing message when synthesis or playback
/// fails; `onFinished` always fires when the pipeline stops (success or
/// failure) so the caller can return to idle.
protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    var onFinished: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func speak(text: String)
    func stop()
}

/// HTTP client that turns text into MP3 audio data. Injectable so tests
/// can stub the network without hitting OpenAI.
protocol TextToSpeechClient: AnyObject {
    func synthesize(text: String) async throws -> Data
}

/// Plays back decoded audio data. Supports queueing so a speech synthesizer
/// can start playing chunk 1 immediately and append chunks 2..N as they
/// arrive — the player auto-advances once each chunk finishes.
/// `onFinished` fires once the entire queue is exhausted.
protocol AudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    var onFinished: (() -> Void)? { get set }
    func play(data: Data) throws
    func enqueue(data: Data) throws
    func stop()
}

protocol NotificationPresenting {
    func show(title: String, body: String)
    func requestAuthorization() async -> Bool
}
