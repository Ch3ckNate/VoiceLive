import Foundation
import AppKit
import SwiftUI
import Observation
import os.log

@MainActor
@Observable
final class AppState {
    let statusItem = StatusItemController()

    /// Human-readable description of the most recent failure, or nil if
    /// the app is healthy. Observable: the MenuBarExtra dropdown reads
    /// this to surface *why* something broke instead of a bare "error"
    /// label. Cleared when a new successful operation starts.
    var lastError: String?

    private let hotkeyManager: any HotkeyRegistering
    private let selectionCapturer: any SelectionCapturing
    private let synthesizer: any SpeechSynthesizing
    private let notifications: any NotificationPresenting
    private let log = Logger(subsystem: Config.logSubsystem, category: "AppState")

    init(
        hotkeyManager: any HotkeyRegistering = HotkeyManager(),
        selectionCapturer: any SelectionCapturing = SelectionCapturer(),
        synthesizer: any SpeechSynthesizing = SpeechSynthesizer(),
        notifications: any NotificationPresenting = NotificationManager.shared
    ) {
        self.hotkeyManager = hotkeyManager
        self.selectionCapturer = selectionCapturer
        self.synthesizer = synthesizer
        self.notifications = notifications

        self.synthesizer.onFinished = { [weak self] in
            guard let self else { return }
            // If a synthesis/playback error just fired, onError already
            // set statusItem.state = .error and populated lastError. Only
            // reset to idle on a clean finish.
            if self.lastError == nil {
                self.statusItem.state = .idle
            }
        }

        self.synthesizer.onError = { [weak self] message in
            guard let self else { return }
            self.log.error("Synthesizer error surfaced: \(message, privacy: .public)")
            self.lastError = message
            self.statusItem.state = .error
            self.notifications.show(title: "VoiceLive", body: message)
        }

        self.hotkeyManager.onHotkey = { [weak self] in
            self?.handleHotkey()
        }
    }

    /// Called once on app launch. Requests permissions, registers the
    /// hotkey, and surfaces any startup errors as notifications.
    func bootstrap() async {
        // 1. Notification permission — optional. The menu bar icon state
        //    conveys errors visually, so we proceed even if denied.
        let notifGranted = await notifications.requestAuthorization()
        if !notifGranted {
            log.info("Notification permission not granted — continuing without toast notifications")
        }

        // 2. Register the hotkey
        do {
            try hotkeyManager.register()
        } catch HotkeyError.registrationFailed(let code) {
            log.error("Hotkey registration failed: \(code, privacy: .public)")
            let msg = "Could not register ⌥R hotkey — another app may be using it. Check Keyboard Shortcuts or quit the conflicting app."
            notifications.show(title: "VoiceLive", body: msg)
            lastError = msg
            statusItem.state = .error
            return
        } catch HotkeyError.handlerInstallFailed(let code) {
            log.error("Hotkey handler install failed: \(code, privacy: .public)")
            let msg = "VoiceLive failed to install its keyboard event handler."
            notifications.show(title: "VoiceLive", body: msg)
            lastError = msg
            statusItem.state = .error
            return
        } catch {
            log.error("Unexpected hotkey error: \(String(describing: error), privacy: .public)")
            lastError = "Unexpected hotkey error: \((error as NSError).localizedDescription)"
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
            let msg = "VoiceLive needs Accessibility permission. Open System Settings → Privacy & Security → Accessibility, then quit and relaunch VoiceLive."
            notifications.show(title: "VoiceLive", body: msg)
            lastError = msg
            statusItem.state = .error
        }
    }

    /// Called by the HotkeyManager every time ⌥R is pressed. Implements
    /// the cancel-then-start interrupt rule: any in-flight speech is
    /// stopped before a new one starts.
    func handleHotkey() {
        // 1. Stop any currently-playing speech. AVSpeechSynthesizer fires
        //    didCancel (which we don't listen for), so onFinished won't be
        //    called and the new state won't get clobbered back to .idle.
        if synthesizer.isSpeaking {
            synthesizer.stop()
        }

        // Every press is a fresh attempt — clear any stale error so the
        // dropdown doesn't keep showing last time's failure indefinitely.
        lastError = nil
        statusItem.state = .loading

        // 2. Capture the selection synchronously
        let capture = selectionCapturer.capture()
        let text: String
        switch capture {
        case .captured(let t):
            text = t
        case .noSelection:
            reportHotkeyError("No text selected, or the app didn't respond to ⌘C. Highlight the text you want and press ⌥R again. Check Console.app (subsystem com.nathan.voicelive) for details.")
            return
        case .notText:
            reportHotkeyError("Selection is not text (image or file).")
            return
        }

        // 3. Validate the captured text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            reportHotkeyError("Selection was empty after trimming whitespace.")
            return
        }
        if trimmed.count > Config.maxChars {
            reportHotkeyError("Selection too long (\(trimmed.count) characters, max \(Config.maxChars)).")
            return
        }

        // 4. Speak. SpeechSynthesizer returns immediately and fires
        //    onFinished/onError via its callbacks as the pipeline runs.
        synthesizer.speak(text: trimmed)
        statusItem.state = .playing
    }

    /// Shared error path for hotkey-time failures (selection missing,
    /// wrong type, too long): surface via notification, persist for the
    /// dropdown, and flash the icon briefly.
    private func reportHotkeyError(_ message: String) {
        notifications.show(title: "VoiceLive", body: message)
        lastError = message
        statusItem.flashError()
    }

    func shutdown() {
        synthesizer.stop()
        hotkeyManager.unregister()
    }
}
