import Foundation
import AppKit
import Carbon.HIToolbox
import os.log

/// Captures the currently-selected text from any frontmost app by:
///   1. Saving the current pasteboard string
///   2. Recording the pasteboard changeCount
///   3. Simulating ⌘C via CGEventPost
///   4. Sleeping briefly for the target app to respond
///   5. Checking whether changeCount incremented — if not, no selection
///   6. Reading the captured text (if present)
///   7. Restoring the saved pasteboard string
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
    private let pasteboard: any PasteboardAccess
    private let simulateCopy: () -> Void
    private let log = Logger(subsystem: Config.logSubsystem, category: "SelectionCapturer")

    init(
        settleDelayMilliseconds: UInt32 = Config.settleDelayMs,
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        simulateCopy: (() -> Void)? = nil
    ) {
        self.settleDelayMicroseconds = settleDelayMilliseconds * 1000
        self.pasteboard = pasteboard
        self.simulateCopy = simulateCopy ?? SelectionCapturer.defaultSimulateCommandC
    }

    func capture() -> CaptureResult {
        let saved = pasteboard.string(forType: .string)
        let initialChangeCount = pasteboard.changeCount

        simulateCopy()
        usleep(settleDelayMicroseconds)

        if pasteboard.changeCount == initialChangeCount {
            return .noSelection
        }

        let captured = pasteboard.string(forType: .string)

        // Restore the saved string regardless of result
        pasteboard.clearContents()
        if let saved {
            pasteboard.setString(saved, forType: .string)
        }

        guard let captured else { return .notText }
        return .captured(captured)
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
