import XCTest
@testable import VoiceLive

@MainActor
final class StatusItemControllerTests: XCTestCase {
    func test_initialState_isIdle() {
        let controller = StatusItemController()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.iconName, "speaker.wave.2")
        XCTAssertEqual(controller.statusLabel, "Idle")
    }

    func test_loadingState_hasCorrectIconAndLabel() {
        let controller = StatusItemController()
        controller.state = .loading
        XCTAssertEqual(controller.iconName, "speaker.wave.2.bubble")
        XCTAssertEqual(controller.statusLabel, "Loading…")
    }

    func test_playingState_hasCorrectIconAndLabel() {
        let controller = StatusItemController()
        controller.state = .playing
        XCTAssertEqual(controller.iconName, "speaker.wave.3.fill")
        XCTAssertEqual(controller.statusLabel, "Playing")
    }

    func test_errorState_hasCorrectIconAndLabel() {
        let controller = StatusItemController()
        controller.state = .error
        XCTAssertEqual(controller.iconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(controller.statusLabel, "Error")
    }

    func test_flashError_setsStateToErrorImmediately() {
        let controller = StatusItemController()
        controller.flashError()
        XCTAssertEqual(controller.state, .error)
    }

    func test_flashError_supersededByNewerStateChange() async {
        let controller = StatusItemController()
        controller.flashError()
        XCTAssertEqual(controller.state, .error)

        // Newer state change during the 2-second flash window
        controller.state = .playing

        // Wait past the flash timeout; the flash should NOT revert playing → idle
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertEqual(controller.state, .playing)
    }
}
