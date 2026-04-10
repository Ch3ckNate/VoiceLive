import Foundation
import AppKit
import SwiftUI
import Observation
import os.log

@MainActor
@Observable
final class AppState {
    let statusItem = StatusItemController()

    private let hotkeyManager: any HotkeyRegistering
    private let selectionCapturer: any SelectionCapturing
    private let synthesizer: any TextSynthesizing
    private let audioPlayer: any AudioPlaying
    private let notifications: any NotificationPresenting
    private let log = Logger(subsystem: Config.logSubsystem, category: "AppState")

    private(set) var inFlightTask: Task<Void, Never>?

    init(
        hotkeyManager: any HotkeyRegistering = HotkeyManager(),
        selectionCapturer: any SelectionCapturing = SelectionCapturer(),
        synthesizer: any TextSynthesizing = ElevenLabsClient(
            apiKey: Config.elevenLabsApiKey,
            voiceId: Config.voiceId,
            modelId: Config.modelId
        ),
        audioPlayer: any AudioPlaying = AudioPlayer(),
        notifications: any NotificationPresenting = NotificationManager.shared
    ) {
        self.hotkeyManager = hotkeyManager
        self.selectionCapturer = selectionCapturer
        self.synthesizer = synthesizer
        self.audioPlayer = audioPlayer
        self.notifications = notifications

        self.audioPlayer.onFinished = { [weak self] in
            guard let self else { return }
            self.statusItem.state = .idle
        }

        self.hotkeyManager.onHotkey = { [weak self] in
            self?.handleHotkey()
        }
    }

    /// Called once on app launch. Requests permissions, registers the
    /// hotkey, and surfaces any startup errors as notifications.
    func bootstrap() async {
        // 1. Notification permission — if denied the error feedback path
        //    is broken, so we bail into a permanent error state.
        let notifGranted = await notifications.requestAuthorization()
        if !notifGranted {
            log.error("Notification permission denied")
            statusItem.state = .error
            return
        }

        // 2. Register the hotkey
        do {
            try hotkeyManager.register()
        } catch HotkeyError.registrationFailed(let code) {
            log.error("Hotkey registration failed: \(code, privacy: .public)")
            notifications.show(
                title: "VoiceLive",
                body: "Could not register ⌥R hotkey — another app may be using it. Check Keyboard Shortcuts or quit the conflicting app."
            )
            statusItem.state = .error
            return
        } catch HotkeyError.handlerInstallFailed(let code) {
            log.error("Hotkey handler install failed: \(code, privacy: .public)")
            notifications.show(
                title: "VoiceLive",
                body: "VoiceLive failed to install its keyboard event handler."
            )
            statusItem.state = .error
            return
        } catch {
            log.error("Unexpected hotkey error: \(String(describing: error), privacy: .public)")
            statusItem.state = .error
            return
        }

        // 3. Accessibility — prompt if missing. We prompt last because the
        //    prompt is modal and may take the user out of our app.
        let axOptions: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ]
        let trusted = AXIsProcessTrustedWithOptions(axOptions)
        if !trusted {
            log.error("Accessibility not granted")
            notifications.show(
                title: "VoiceLive",
                body: "VoiceLive needs Accessibility permission. Open System Settings → Privacy & Security → Accessibility, then quit and relaunch VoiceLive."
            )
            statusItem.state = .error
        }
    }

    /// Called by the HotkeyManager every time ⌥R is pressed. Implements
    /// the cancel-then-start interrupt rule: any in-flight pipeline is
    /// torn down before a new one starts.
    func handleHotkey() {
        // 1. Cancel any in-flight task (ElevenLabs request may still be
        //    pending). The task checks Task.isCancelled after its awaits
        //    and skips playback if so.
        inFlightTask?.cancel()
        inFlightTask = nil

        // 2. Stop any currently playing audio instantly
        if audioPlayer.isPlaying {
            audioPlayer.stop()
        }

        statusItem.state = .loading

        // 3. Capture the selection synchronously
        let capture = selectionCapturer.capture()
        let text: String
        switch capture {
        case .captured(let t):
            text = t
        case .noSelection:
            notifications.show(title: "VoiceLive", body: "No text selected.")
            statusItem.flashError()
            return
        case .notText:
            notifications.show(title: "VoiceLive", body: "Selection is not text.")
            statusItem.flashError()
            return
        }

        // 4. Validate the captured text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            notifications.show(title: "VoiceLive", body: "No text selected.")
            statusItem.flashError()
            return
        }
        if trimmed.count > Config.maxChars {
            notifications.show(
                title: "VoiceLive",
                body: "Selection too long (\(trimmed.count) characters, max \(Config.maxChars))."
            )
            statusItem.flashError()
            return
        }

        // 5. Kick off async synthesis + playback
        inFlightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.synthesizer.synthesize(text: trimmed)
                try Task.checkCancellation()
                try self.audioPlayer.play(data: audio)
                self.statusItem.state = .playing
            } catch is CancellationError {
                // Superseded by a newer hotkey press — do nothing
                return
            } catch ElevenLabsError.invalidApiKey {
                self.log.error("ElevenLabs 401")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "ElevenLabs: invalid API key."
                )
                self.statusItem.flashError()
            } catch ElevenLabsError.rateLimited {
                self.log.error("ElevenLabs 429")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "ElevenLabs: rate limited. Try again in a moment."
                )
                self.statusItem.flashError()
            } catch ElevenLabsError.httpError(let code) {
                self.log.error("ElevenLabs HTTP \(code, privacy: .public)")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "ElevenLabs error: HTTP \(code)."
                )
                self.statusItem.flashError()
            } catch ElevenLabsError.networkError(let msg) {
                self.log.error("Network error: \(msg, privacy: .public)")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "Network error: \(msg)."
                )
                self.statusItem.flashError()
            } catch ElevenLabsError.emptyResponse {
                self.log.error("ElevenLabs empty response")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "ElevenLabs returned an empty response."
                )
                self.statusItem.flashError()
            } catch ElevenLabsError.invalidURL {
                self.log.error("ElevenLabs invalid URL (check voiceId)")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "Configuration error: invalid voice ID."
                )
                self.statusItem.flashError()
            } catch {
                self.log.error("Playback failed: \(String(describing: error), privacy: .public)")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "Audio playback failed."
                )
                self.statusItem.flashError()
            }
        }
    }

    func shutdown() {
        inFlightTask?.cancel()
        audioPlayer.stop()
        hotkeyManager.unregister()
    }
}
