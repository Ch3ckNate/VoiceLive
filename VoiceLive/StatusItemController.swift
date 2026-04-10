import SwiftUI
import Observation

@MainActor
@Observable
final class StatusItemController {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case error
    }

    var state: State = .idle

    var iconName: String {
        switch state {
        case .idle: return "speaker.wave.2"
        case .loading: return "speaker.wave.2.bubble"
        case .playing: return "speaker.wave.3.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var statusLabel: String {
        switch state {
        case .idle: return "Idle"
        case .loading: return "Loading…"
        case .playing: return "Playing"
        case .error: return "Error"
        }
    }

    /// Flash the error state for 2 seconds, then revert to idle.
    /// If a new state change arrives during the flash window, the flash is
    /// superseded (the newer state wins).
    func flashError() {
        state = .error
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            if self.state == .error {
                self.state = .idle
            }
        }
    }
}
