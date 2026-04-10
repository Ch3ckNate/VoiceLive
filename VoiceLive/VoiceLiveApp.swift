import SwiftUI

@main
struct VoiceLiveApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("VoiceLive — empty shell")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "speaker.wave.2")
        }
        .menuBarExtraStyle(.window)
    }
}
