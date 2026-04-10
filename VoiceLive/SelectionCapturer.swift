import Foundation
import AppKit
import Carbon.HIToolbox
import os.log

/// Captures the currently-selected text from any frontmost app by:
///   1. Saving the current pasteboard string
///   2. Recording the pasteboard changeCount
///   3. Waiting for the user's hotkey modifiers to release (otherwise
///      Option from ⌥R gets mashed into the synthetic ⌘C at the HID tap)
///   4. Simulating ⌘C via CGEventPost
///   5. Sleeping briefly for the target app to respond
///   6. Checking whether changeCount incremented — if not, no selection
///   7. Reading the captured text (if present)
///   8. Restoring the saved pasteboard string
///
/// The changeCount probe is what distinguishes "user had nothing selected"
/// from "user had something selected and also had something on the
/// clipboard." Without it, an unchanged clipboard after the fake ⌘C looks
/// identical to "captured the previous clipboard value".
final class SelectionCapturer: SelectionCapturing {
    enum CaptureResult: Equatable {
        case captured(String)
        case noSelection   // changeCount unchanged; nothing was copied
        case notText       // changeCount changed, but pasteboard has no text
    }

    private let settleDelayMicroseconds: UInt32
    private let modifierReleaseTimeoutMicroseconds: UInt32
    private let pasteboard: any PasteboardAccess
    private let simulateCopy: () -> Void
    private let readModifierFlags: () -> NSEvent.ModifierFlags
    private let log = Logger(subsystem: Config.logSubsystem, category: "SelectionCapturer")

    init(
        settleDelayMilliseconds: UInt32 = Config.settleDelayMs,
        modifierReleaseTimeoutMilliseconds: UInt32 = Config.modifierReleaseTimeoutMs,
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        readModifierFlags: (() -> NSEvent.ModifierFlags)? = nil,
        simulateCopy: (() -> Void)? = nil
    ) {
        self.settleDelayMicroseconds = settleDelayMilliseconds * 1000
        self.modifierReleaseTimeoutMicroseconds = modifierReleaseTimeoutMilliseconds * 1000
        self.pasteboard = pasteboard
        self.simulateCopy = simulateCopy ?? SelectionCapturer.defaultSimulateCommandC
        self.readModifierFlags = readModifierFlags ?? { NSEvent.modifierFlags }
    }

    func capture() -> CaptureResult {
        let saved = pasteboard.string(forType: .string)
        let initialChangeCount = pasteboard.changeCount
        log.info("Capture start: initial changeCount=\(initialChangeCount, privacy: .public)")

        // Wait until the user has released the hotkey's modifier keys.
        // Without this, the synthetic ⌘C gets ⌥ OR'd into its modifier
        // state at the HID event tap layer (because the ⌥R hotkey fires
        // on keyDown while Option is still physically held), and the
        // target app sees ⌘⌥C and ignores it.
        waitForModifiersRelease()

        simulateCopy()
        usleep(settleDelayMicroseconds)

        let afterChangeCount = pasteboard.changeCount
        if afterChangeCount == initialChangeCount {
            log.error("changeCount unchanged after synthetic ⌘C (\(initialChangeCount, privacy: .public)) — target app did not copy. Either nothing was selected or the app didn't respond to ⌘C within \(self.settleDelayMicroseconds / 1000, privacy: .public)ms.")
            return .noSelection
        }
        log.info("changeCount moved \(initialChangeCount, privacy: .public) → \(afterChangeCount, privacy: .public)")

        let captured = pasteboard.string(forType: .string)

        // Restore the saved string regardless of result
        pasteboard.clearContents()
        if let saved {
            pasteboard.setString(saved, forType: .string)
        }

        guard let captured else {
            log.error("Clipboard changed but contained no string (probably an image or file)")
            return .notText
        }
        log.info("Captured \(captured.count, privacy: .public) characters")
        return .captured(captured)
    }

    /// Poll the current modifier state every 10ms until Command, Option,
    /// Control, and Shift are all released, or until the timeout expires.
    /// Called synchronously on the main thread — the hotkey handler is
    /// @MainActor and the whole capture pipeline is blocking by design.
    private func waitForModifiersRelease() {
        let pollInterval: UInt32 = 10_000 // 10 ms
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        var elapsed: UInt32 = 0
        while elapsed < modifierReleaseTimeoutMicroseconds {
            let flags = readModifierFlags()
            if flags.intersection(relevant).isEmpty {
                if elapsed > 0 {
                    log.info("Modifiers released after \(elapsed / 1000, privacy: .public)ms")
                }
                return
            }
            usleep(pollInterval)
            elapsed += pollInterval
        }
        log.notice("Timed out waiting for modifiers to release after \(self.modifierReleaseTimeoutMicroseconds / 1000, privacy: .public)ms — proceeding anyway; synthetic ⌘C may be corrupted by held modifiers")
    }

    private static func defaultSimulateCommandC() {
        let log = Logger(subsystem: Config.logSubsystem, category: "SelectionCapturer")
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            log.error("CGEventSource(.hidSystemState) returned nil — synthetic ⌘C cannot be posted")
            return
        }
        let keyCodeC = CGKeyCode(kVK_ANSI_C)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false) else {
            log.error("CGEvent creation returned nil — synthetic ⌘C cannot be posted")
            return
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }
}
