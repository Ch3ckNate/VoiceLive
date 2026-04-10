import Foundation
import Carbon.HIToolbox

enum HotkeyError: Error {
    case registrationFailed(OSStatus)
    case handlerInstallFailed(OSStatus)
}

/// Global hotkey registrar using the Carbon RegisterEventHotKey API.
/// This is still the canonical way to register global hotkeys on macOS
/// because the newer NSEvent APIs either only work in-app or require
/// CGEventTap (which is much more heavyweight).
///
/// Registering a hotkey alone is not enough — Carbon also requires an
/// event handler installed on the application event target. Without the
/// handler, the OS accepts the registration but never invokes any
/// callback.
final class HotkeyManager: HotkeyRegistering {
    /// Called on the main thread every time the hotkey fires.
    var onHotkey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // 4-char code "vlhk" used as the EventHotKeyID signature. Any unique
    // value works; this just identifies our hotkey to Carbon.
    private let signature: OSType = 0x766C686B  // 'v' 'l' 'h' 'k'

    func register() throws {
        // Build the EventHotKeyID
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)

        // Register ⌥R (Option + R)
        // kVK_ANSI_R = 15 (defined in Carbon.HIToolbox.Events.h)
        // optionKey = 2048 (defined in Carbon.HIToolbox.Events.h)
        var rawHotKeyRef: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &rawHotKeyRef
        )
        guard regStatus == noErr, let ref = rawHotKeyRef else {
            throw HotkeyError.registrationFailed(regStatus)
        }
        self.hotKeyRef = ref

        // Install the event handler so the hotkey actually dispatches
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onHotkey?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        guard handlerStatus == noErr, let hRef = handlerRef else {
            // Roll back the hotkey registration if handler install fails
            UnregisterEventHotKey(ref)
            self.hotKeyRef = nil
            throw HotkeyError.handlerInstallFailed(handlerStatus)
        }
        self.eventHandlerRef = hRef
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let hRef = eventHandlerRef {
            RemoveEventHandler(hRef)
            eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}
