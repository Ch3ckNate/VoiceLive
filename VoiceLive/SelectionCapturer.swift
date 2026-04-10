import Foundation
import AppKit
import Carbon.HIToolbox

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
final class SelectionCapturer {
    enum CaptureResult {
        case captured(String)
        case noSelection   // changeCount unchanged; nothing was copied
        case notText       // changeCount changed, but pasteboard has no text
    }

    private let settleDelayMicroseconds: UInt32

    init(settleDelayMilliseconds: UInt32 = Config.settleDelayMs) {
        self.settleDelayMicroseconds = settleDelayMilliseconds * 1000
    }

    func capture() -> CaptureResult {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let initialChangeCount = pasteboard.changeCount

        simulateCommandC()
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

    private func simulateCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeC = CGKeyCode(kVK_ANSI_C)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
