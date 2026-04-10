import SwiftUI
import AppKit

@main
struct VoiceLiveApp: App {
    @State private var appState: AppState

    init() {
        let state = AppState()
        _appState = State(wrappedValue: state)
        Task { @MainActor in
            await state.bootstrap()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("VoiceLive")
                    .font(.headline)
                Divider()
                Text("Status: \(appState.statusItem.statusLabel)")
                    .foregroundStyle(.secondary)
                if let err = appState.lastError {
                    Divider()
                    Text("Last error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Button("Quit VoiceLive") {
                    appState.shutdown()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(12)
            .frame(minWidth: 260, maxWidth: 320, alignment: .leading)
        } label: {
            Image(systemName: appState.statusItem.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}
