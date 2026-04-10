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
