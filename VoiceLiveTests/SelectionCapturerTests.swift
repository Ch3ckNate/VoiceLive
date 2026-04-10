import XCTest
import AppKit
@testable import VoiceLive

final class SelectionCapturerTests: XCTestCase {
    var pasteboard: FakePasteboard!
    var capturer: SelectionCapturer!

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard()
    }

    override func tearDown() {
        capturer = nil
        pasteboard = nil
        super.tearDown()
    }

    // MARK: - changeCount probe

    func test_capture_changeCountUnchanged_returnsNoSelection() {
        pasteboard.stringForType = "previous clipboard"
        capturer = SelectionCapturer(settleDelayMilliseconds: 0, pasteboard: pasteboard) {
            // Simulate ⌘C did nothing — changeCount stays the same
        }

        let result = capturer.capture()

        XCTAssertEqual(result, .noSelection)
    }

    func test_capture_changeCountIncrementedWithString_returnsCaptured() {
        pasteboard.stringForType = "previous clipboard"
        capturer = SelectionCapturer(settleDelayMilliseconds: 0, pasteboard: pasteboard) { [weak self] in
            self?.pasteboard.stringForType = "newly selected text"
            self?.pasteboard.changeCount += 1
        }

        let result = capturer.capture()

        XCTAssertEqual(result, .captured("newly selected text"))
    }

    func test_capture_changeCountIncrementedButNoString_returnsNotText() {
        pasteboard.stringForType = "previous clipboard"
        capturer = SelectionCapturer(settleDelayMilliseconds: 0, pasteboard: pasteboard) { [weak self] in
            self?.pasteboard.stringForType = nil // e.g. an image was copied
            self?.pasteboard.changeCount += 1
        }

        let result = capturer.capture()

        XCTAssertEqual(result, .notText)
    }

    // MARK: - Save/restore clipboard

    func test_capture_successfulCapture_restoresOriginalClipboard() {
        pasteboard.stringForType = "original clipboard"
        capturer = SelectionCapturer(settleDelayMilliseconds: 0, pasteboard: pasteboard) { [weak self] in
            self?.pasteboard.stringForType = "captured selection"
            self?.pasteboard.changeCount += 1
        }

        _ = capturer.capture()

        XCTAssertEqual(pasteboard.clearContentsCallCount, 1)
        XCTAssertEqual(pasteboard.stringForType, "original clipboard")
    }

    func test_capture_notText_stillRestoresOriginalClipboard() {
        pasteboard.stringForType = "original clipboard"
        capturer = SelectionCapturer(settleDelayMilliseconds: 0, pasteboard: pasteboard) { [weak self] in
            self?.pasteboard.stringForType = nil
            self?.pasteboard.changeCount += 1
        }

        _ = capturer.capture()

        XCTAssertEqual(pasteboard.clearContentsCallCount, 1)
        XCTAssertEqual(pasteboard.stringForType, "original clipboard")
    }

    func test_capture_withEmptyInitialClipboard_doesNotRestoreString() {
        pasteboard.stringForType = nil
        capturer = SelectionCapturer(settleDelayMilliseconds: 0, pasteboard: pasteboard) { [weak self] in
            self?.pasteboard.stringForType = "captured"
            self?.pasteboard.changeCount += 1
        }

        _ = capturer.capture()

        XCTAssertEqual(pasteboard.clearContentsCallCount, 1)
        // With no saved value, setString should not be called after clear
        XCTAssertEqual(pasteboard.setStringCallCount, 0)
        XCTAssertNil(pasteboard.stringForType)
    }

    func test_capture_noSelection_doesNotRestoreClipboard() {
        pasteboard.stringForType = "untouched"
        capturer = SelectionCapturer(settleDelayMilliseconds: 0, pasteboard: pasteboard) {
            // no-op
        }

        _ = capturer.capture()

        // Short-circuits before restore logic
        XCTAssertEqual(pasteboard.clearContentsCallCount, 0)
        XCTAssertEqual(pasteboard.stringForType, "untouched")
    }

    // MARK: - Modifier release wait

    func test_capture_waitsForModifiersToRelease_beforeSimulatingCopy() {
        // Simulate Option still being held at the start, then released
        // after two polls. The real impl polls at 10ms intervals, so the
        // release timeout below is short enough to keep the test fast
        // even if the modifier reader never changes.
        pasteboard.stringForType = "previous"
        var pollCount = 0
        let flagsReader: () -> NSEvent.ModifierFlags = {
            pollCount += 1
            let flags: NSEvent.ModifierFlags = pollCount < 3 ? [.option] : []
            return flags
        }
        var simulateCopyCalled = false
        capturer = SelectionCapturer(
            settleDelayMilliseconds: 0,
            modifierReleaseTimeoutMilliseconds: 500,
            pasteboard: pasteboard,
            readModifierFlags: flagsReader,
            simulateCopy: {
                simulateCopyCalled = true
            }
        )

        _ = capturer.capture()

        XCTAssertTrue(simulateCopyCalled)
        // Poll happened until Option cleared (3+ reads)
        XCTAssertGreaterThanOrEqual(pollCount, 3)
    }

    func test_capture_modifiersNeverRelease_stillProceedsAfterTimeout() {
        pasteboard.stringForType = "previous"
        var simulateCopyCalled = false
        let stuckReader: () -> NSEvent.ModifierFlags = {
            let flags: NSEvent.ModifierFlags = [.option]
            return flags
        }
        capturer = SelectionCapturer(
            settleDelayMilliseconds: 0,
            modifierReleaseTimeoutMilliseconds: 20, // short timeout keeps test fast
            pasteboard: pasteboard,
            readModifierFlags: stuckReader,
            simulateCopy: { simulateCopyCalled = true }
        )

        _ = capturer.capture()

        // Proceeds anyway after the timeout — better to try than to hang.
        XCTAssertTrue(simulateCopyCalled)
    }

    func test_capture_noModifiersHeld_doesNotPollRepeatedly() {
        pasteboard.stringForType = "previous"
        var pollCount = 0
        let freeReader: () -> NSEvent.ModifierFlags = {
            pollCount += 1
            let flags: NSEvent.ModifierFlags = []
            return flags
        }
        capturer = SelectionCapturer(
            settleDelayMilliseconds: 0,
            modifierReleaseTimeoutMilliseconds: 500,
            pasteboard: pasteboard,
            readModifierFlags: freeReader,
            simulateCopy: { [weak self] in
                self?.pasteboard.stringForType = "got it"
                self?.pasteboard.changeCount += 1
            }
        )

        let result = capturer.capture()

        XCTAssertEqual(result, .captured("got it"))
        XCTAssertEqual(pollCount, 1) // single check, no loop
    }
}

// MARK: - Fake pasteboard

final class FakePasteboard: PasteboardAccess {
    var stringForType: String?
    var changeCount: Int = 0
    var clearContentsCallCount = 0
    var setStringCallCount = 0

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        return stringForType
    }

    @discardableResult
    func clearContents() -> Int {
        clearContentsCallCount += 1
        stringForType = nil
        changeCount += 1
        return changeCount
    }

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        setStringCallCount += 1
        stringForType = string
        return true
    }
}
