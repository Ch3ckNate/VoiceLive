# VoiceLive — Design Spec

**Date:** 2026-04-10
**Author:** Nathan
**Status:** Approved for implementation planning

---

## 1. Purpose

VoiceLive is a personal-use macOS menu bar utility that reads highlighted text aloud via the ElevenLabs text-to-speech API. The author primarily works in Claude Code inside iTerm and wants a single keystroke gesture to listen to Claude's responses while doing other things.

**Core gesture:** highlight text in any app → press `⌥R` → audio plays through system output.

Scope is intentionally tight: one user, one Mac, one hotkey, one voice. No settings UI, no shipping, no multi-user concerns.

## 2. Non-Goals

- Not a shippable product. No code signing for distribution, no installer, no App Store submission.
- No settings window. Configuration lives in a hardcoded `Config.swift` file, gitignored.
- No voice switching at runtime, no hotkey rebinding at runtime — both require a rebuild.
- No true audio streaming. The app waits for the full ElevenLabs response before playback starts.
- No long-form text chunking. Selections over 5000 characters are rejected with an error notification.
- No retry logic. Failures are surfaced immediately; the user re-triggers by pressing `⌥R` again.
- No analytics, telemetry, crash reporting, or usage logging beyond `os_log`.

## 3. User Experience

### Happy path

1. Nathan highlights a paragraph in iTerm (or any macOS app with selectable text).
2. He presses `⌥R`.
3. The menu bar icon briefly shows a loading state (~500ms–1.5s).
4. The icon switches to a playing state and audio plays through the default output device.
5. When playback finishes, the icon returns to idle.

### Interrupt behavior

If `⌥R` is pressed while a previous pipeline is still active (either audio playing, *or* ElevenLabs request still in flight):

1. Any in-flight ElevenLabs request is cancelled.
2. Any currently-playing audio stops immediately.
3. The pipeline runs fresh with the new selection.
4. No queueing; the new audio replaces the old regardless of whether the old pipeline had reached the playback stage.

### Menu bar dropdown

Clicking the menu bar icon opens a minimal dropdown:

```
VoiceLive
─────────────
Status: Idle
─────────────
Quit VoiceLive   ⌘Q
```

No preferences, no about, no additional controls.

### Icon states

| State | SF Symbol | When |
|---|---|---|
| idle | `speaker.wave.2` | Default; no activity |
| loading | `speaker.wave.2.bubble` | Between hotkey press and audio playback start |
| playing | `speaker.wave.3.fill` | During audio playback |
| error | `exclamationmark.triangle.fill` | For 2 seconds after any failure, then reverts to idle |

All icons use SF Symbols as template images so they auto-adapt to light and dark menu bars.

## 4. Architecture

### Tech stack

- **Language:** Swift 5.9+
- **UI framework:** SwiftUI (for `MenuBarExtra` and any future UI)
- **Minimum macOS:** 14.0 (Sonoma) — required for SwiftUI `MenuBarExtra`
- **Hotkey API:** Carbon `RegisterEventHotKey` (Option is a standard modifier, so no `CGEventTap` needed)
- **Event posting API:** `CGEventPost` for simulated `⌘C`
- **Audio API:** `AVAudioPlayer` (simple in-memory playback)
- **HTTP API:** `URLSession` with async/await
- **App sandbox:** **DISABLED.** This is mandatory. `CGEventPost` cannot post events to other processes from a sandboxed app, and `RegisterEventHotKey` has similar restrictions. The generated `.xcodeproj` must set `ENABLE_APP_SANDBOX = NO` and either omit the entitlements file entirely or explicitly set `com.apple.security.app-sandbox = NO`. Without this the app builds, launches, and then silently fails every hotkey press.
- **Project scaffolding tool:** [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (installed via Homebrew). Generates the `.xcodeproj` deterministically from a `project.yml` spec file checked into the repo. This lets Claude Code drive the entire workflow (scaffold, build, run) without requiring manual Xcode GUI interaction for project setup.
- **Build tool:** `xcodebuild` (driven via XcodeBuildMCP during implementation, operating on the `.xcodeproj` that xcodegen produced).

### Component breakdown

The app is split into small single-purpose components. A single `AppState` coordinator owns the pipeline logic; every other component is a dumb worker.

| Component | Responsibility | Approx. lines |
|---|---|---|
| `VoiceLiveApp.swift` | `@main` SwiftUI `App` with `MenuBarExtra`. Instantiates `AppState` and wires hotkey → pipeline. | ~40 |
| `Config.swift` | Hardcoded constants: ElevenLabs API key, voice ID, model ID, character limit, Cmd+C settle delay. **Gitignored.** | ~15 |
| `Config.example.swift` | Template committed to git so the project builds after clone with a placeholder config. | ~15 |
| `HotkeyManager.swift` | Registers `⌥R` globally via Carbon `RegisterEventHotKey`. **Must also call `InstallEventHandler` on `GetApplicationEventTarget()`** so the Carbon event loop actually dispatches hotkey events to our callback (registering alone is not enough). Fires a closure when pressed. Handles unregistration (`UnregisterEventHotKey` + `RemoveEventHandler`) on shutdown. | ~80 |
| `SelectionCapturer.swift` | Saves pasteboard contents, simulates `⌘C` via `CGEventPost`, reads selection, restores original pasteboard. Synchronous. | ~60 |
| `ElevenLabsClient.swift` | Async HTTP client. `func synthesize(text: String) async throws -> Data`. POSTs to `/v1/text-to-speech/{voice_id}/stream`. | ~70 |
| `AudioPlayer.swift` | Wraps `AVAudioPlayer`. **Holds the `AVAudioPlayer` instance as a stored property** so ARC does not deallocate it mid-playback (a local variable would stop audio instantly). Exposes `play(data:)`, `stop()`, and a completion callback via `AVAudioPlayerDelegate.audioPlayerDidFinishPlaying`. | ~50 |
| `StatusItemController.swift` | `@Observable` state object holding the current icon state. Publishes changes to the menu bar icon. | ~40 |
| `AppState.swift` | Pipeline coordinator. Holds `inFlightTask: Task<Void, Never>?` so that rapid `⌥R` presses cancel the previous in-flight pipeline (HTTP request *and* pending playback) before starting a new one. The only place the flow lives. Wired to `HotkeyManager`'s callback. | ~100 |

**Total estimate:** ~450 lines of Swift across 8 files.

### Data flow

```
User highlights text in any app
        │
        ▼
User presses ⌥R
        │
        ▼
HotkeyManager callback fires on main thread
        │
        ▼
AppState.handleHotkey()
  ├─ inFlightTask?.cancel()           # cancel any pending HTTP request
  ├─ If audioPlayer.isPlaying → audioPlayer.stop()
  ├─ statusItem.state = .loading
        │
        ▼
SelectionCapturer.capture() (synchronous, ~50ms)
  ├─ saved = NSPasteboard.general.string
  ├─ initialChangeCount = NSPasteboard.general.changeCount
  ├─ CGEventPost keyDown/keyUp ⌘C
  ├─ Sleep for Config.settleDelayMs (default 40ms)
  ├─ If NSPasteboard.general.changeCount == initialChangeCount:
  │      → no selection was captured; return nil (triggers "No text selected")
  ├─ captured = NSPasteboard.general.string
  ├─ Restore NSPasteboard.general.string = saved
  └─ Return captured text
        │
        ▼
Validate captured text
  ├─ nil or whitespace-only → error pipeline
  ├─ length > Config.maxChars → error pipeline
  └─ else → continue
        │
        ▼
inFlightTask = Task { ElevenLabsClient.synthesize(text:) }
  ├─ POST /v1/text-to-speech/{voice_id}/stream
  │  Headers: xi-api-key, Content-Type: application/json
  │  Body: {"text": "...", "model_id": "eleven_turbo_v2_5"}
  │  Returns: audio Data (full body)
  └─ Inside the Task: check Task.isCancelled after the await; if cancelled,
     do NOT call audioPlayer.play() (the new hotkey press has already
     superseded us)
        │
        ▼
AppState
  ├─ statusItem.state = .playing
  └─ audioPlayer.play(data: audio)
        │
        ▼
AVAudioPlayer plays to default output
        │
        ▼
On playback completion
  └─ statusItem.state = .idle
```

### Key design decisions

**Synchronous clipboard capture.** The save/post/restore sequence runs on the main thread in under ~50ms. Keeping it synchronous avoids async races with the pasteboard and feels instant to the user.

**Fixed 40ms settle delay after ⌘C.** macOS needs a short moment for the target app to process the synthetic `⌘C` and populate the pasteboard. 40ms is tunable via a constant near the top of `SelectionCapturer.swift`.

**Full download before playback.** We wait for the entire ElevenLabs response before starting `AVAudioPlayer`. Simpler than real streaming and still fast (~500ms–1.5s for typical selections). True streaming via `AVAudioEngine` is a possible future upgrade if latency becomes annoying.

**Interrupt rule: cancel-then-start.** Every hotkey press cancels the in-flight pipeline before starting a new one. This covers two distinct cases in a single rule:

1. *Audio currently playing* → `audioPlayer.stop()` cuts it instantly.
2. *ElevenLabs request in flight (not yet playing)* → `inFlightTask?.cancel()` aborts the URLSession request and marks the Task as cancelled. When the (now-cancelled) Task reaches its playback step, it sees `Task.isCancelled == true` and skips `audioPlayer.play()`.

Without case 2, rapid `⌥R` presses during the loading window would spawn parallel pipelines and the losing one would still fire `.play()`, causing audible stuttering.

**`AppState` owns the pipeline.** All sequencing lives in one method (`handleHotkey`). Workers are dumb and testable in isolation. Changing behavior (e.g., adding a notification when playback starts) means editing exactly one file.

## 5. Configuration

`Config.swift` is hardcoded and gitignored:

```swift
// Config.swift (GITIGNORED)
enum Config {
    static let elevenLabsApiKey = "sk-..."
    static let voiceId = "..."                    // See `curl https://api.elevenlabs.io/v1/voices`
    static let modelId = "eleven_turbo_v2_5"
    static let maxChars = 5000
    static let settleDelayMs: UInt32 = 40
    static let bundleId = "com.nathan.voicelive"
}
```

A `Config.example.swift` template is committed so the repo is consistent after fresh clone. `README.md` explains the one-line rename-and-fill-in step.

## 6. Permissions

The app requires two macOS permissions:

### 6.1 Accessibility (required for clipboard simulation)

Used to post synthetic `⌘C` events via `CGEventPost`. On first launch:

1. `AppState.init()` calls `AXIsProcessTrustedWithOptions([.promptKey: true])`.
2. macOS shows the standard prompt: *"VoiceLive would like to control this computer using accessibility features."*
3. User clicks through to System Settings → Privacy & Security → Accessibility → toggles VoiceLive on.
4. User quits and relaunches the app (required for the permission to take effect).

On every subsequent launch the app checks `AXIsProcessTrusted()`. If not granted, the menu bar icon shows the error state and clicking it (or triggering the hotkey) posts a notification explaining how to grant the permission, with a button to open the Accessibility settings directly.

### 6.2 Notifications (required for error feedback)

Used to show error messages via `UNUserNotificationCenter`. On first launch:

1. `AppState.init()` calls `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])`.
2. macOS shows the standard prompt: *"VoiceLive Would Like to Send You Notifications."*
3. User clicks Allow.

If the user denies notification permission, the app logs a warning via `os_log` and enters a permanent error icon state until the user manually enables notifications in System Settings → Notifications → VoiceLive. Without notification permission the error feedback path is broken, so the app explicitly refuses to "run silently."

## 7. Error Handling

No retries. No fallbacks. Every failure produces: (a) menu bar icon enters `.error` state for 2 seconds then reverts to idle, and (b) a macOS notification with a human-readable description.

| Failure | Detection | Notification text |
|---|---|---|
| Accessibility not granted | `AXIsProcessTrusted() == false` at launch or hotkey press | "VoiceLive needs Accessibility permission. Open System Settings → Privacy & Security → Accessibility." (Notification click opens System Settings.) |
| No text selected | `NSPasteboard.changeCount` unchanged after simulated `⌘C` (target app did not respond to the copy) | "No text selected." |
| Selection is not text | `changeCount` incremented, but `NSPasteboard.general.string(forType: .string)` returns `nil` (user selected an image, file, or other non-text content) | "Selection is not text." |
| Whitespace-only selection | `text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` | "No text selected." |
| Hotkey registration failed | `RegisterEventHotKey` returns non-zero `OSStatus` at launch (another app owns `⌥R`) | "Could not register ⌥R hotkey — another app may be using it. Check Keyboard Shortcuts or quit the conflicting app." |
| Notification permission denied | `UNUserNotificationCenter` authorization status is `.denied` at launch | Logged to `os_log` only (can't show a notification to tell you notifications are off). Menu bar icon stays in error state until granted. |
| Selection too long | `text.count > Config.maxChars` (note: Swift's `String.count` counts grapheme clusters, not UTF-16 units; for the English-heavy Claude Code output this will match ElevenLabs' count closely enough) | "Selection too long ({count} characters, max {maxChars})." |
| Network error | `URLSession` throws | "Network error: {localizedDescription}." |
| ElevenLabs 401 | HTTP status 401 | "ElevenLabs: invalid API key." |
| ElevenLabs 429 | HTTP status 429 | "ElevenLabs: rate limited. Try again in a moment." |
| ElevenLabs other non-2xx | Any other non-2xx status | "ElevenLabs error: HTTP {code}." |
| Audio decode/init failure | `AVAudioPlayer(data:)` throws | "Audio playback failed." |

**Error state is non-blocking.** If a new hotkey press arrives during the 2s error window, the pipeline runs normally; the error state is just a visual cue, not a gate.

**Logging.** All errors go to `os_log` under the `com.nathan.voicelive` subsystem. Tail with:

```
log stream --predicate 'subsystem == "com.nathan.voicelive"'
```

No file-based logging, no structured logging, no log rotation.

## 8. Testing Strategy

For a personal utility this small, unit tests are concentrated where manual verification is hardest:

**Unit tests (~10 tests):**
- `ElevenLabsClient` with a mocked `URLSession`:
  - 200 with audio body → returns Data
  - 401 → throws `.invalidApiKey`
  - 429 → throws `.rateLimited`
  - 500 → throws `.httpError(500)`
  - Network failure → throws `.networkError`
  - Empty body → throws `.emptyResponse`
  - Request body contains the passed text
  - Request headers include `xi-api-key` and `Content-Type`
  - Request URL includes the configured voice ID
  - Request body includes the configured model ID

**Manual smoke tests (acceptance criteria):**
- Highlight text in iTerm + press `⌥R` → hears audio matching selection
- Highlight text in Safari + press `⌥R` → hears audio matching selection
- Highlight text in Notes + press `⌥R` → hears audio matching selection
- Press `⌥R` with no selection → sees error notification "No text selected"
- Select an image in Safari, press `⌥R` → sees error notification "Selection is not text"
- Press `⌥R` twice in quick succession → first playback cuts off, second plays
- Kill network, press `⌥R` → sees error notification with network error
- Paste a bad API key into `Config.swift`, rebuild, press `⌥R` → sees "invalid API key" notification
- Paste a 6000-character selection → sees "Selection too long" notification

**Not tested:**
- `HotkeyManager`: can't meaningfully unit test OS-level hotkey registration. Covered by smoke test.
- `SelectionCapturer`: interacts with the OS pasteboard. Covered by smoke test.
- `AudioPlayer`: trivial `AVAudioPlayer` wrapper. Covered by smoke test.
- `StatusItemController`: observable state, visually verified during smoke test.

## 9. Project Layout

```
VoiceLive/
├── project.yml                     ← xcodegen spec (source of truth)
├── VoiceLive.xcodeproj/            ← GITIGNORED (regenerated from project.yml)
├── VoiceLive/
│   ├── VoiceLiveApp.swift
│   ├── Config.swift                ← GITIGNORED (real API key)
│   ├── Config.example.swift        ← committed template
│   ├── HotkeyManager.swift
│   ├── SelectionCapturer.swift
│   ├── ElevenLabsClient.swift
│   ├── AudioPlayer.swift
│   ├── StatusItemController.swift
│   ├── AppState.swift
│   ├── Info.plist                  ← LSUIElement = true, etc.
│   └── Assets.xcassets/
├── VoiceLiveTests/
│   └── ElevenLabsClientTests.swift
├── docs/
│   └── superpowers/
│       └── specs/
│           └── 2026-04-10-voicelive-design.md
├── .gitignore
└── README.md
```

## 10. Git Workflow

Per Nathan's Cresta greenfield rules:

- Single branch: `nathan/feat/voicelive`
- All commits land directly on this branch — no sub-branches
- Commits are incremental (one per logical chunk, not one per session)
- Conventional commit format: `feat:`, `fix:`, `chore:`, `test:`
- No AI attribution in commit messages, PR titles, or PR bodies
- `.gitignore` excludes: `VoiceLive/Config.swift`, `build/`, `DerivedData/`, `*.xcuserstate`, `*.xcworkspace/xcuserdata/`, `.DS_Store`, `VoiceLive.xcodeproj/` (since it's regenerated by xcodegen from `project.yml`)

## 11. Implementation Tooling

Implementation is fully automatable (no Xcode GUI interaction required) via two tools:

### 11.1 xcodegen (for project scaffolding)

`xcodegen` generates a `.xcodeproj` deterministically from a checked-in YAML spec. This avoids the need to click through Xcode's "New Project" wizard.

```bash
brew install xcodegen
```

A `project.yml` at the repo root declares targets, sources, settings, Info.plist keys, and framework links. Claude Code writes the YAML, runs `xcodegen generate`, and produces a ready-to-build `.xcodeproj`. The YAML is the source of truth — any setting changes go through the YAML, not the Xcode GUI.

**Key settings the `project.yml` must include for VoiceLive:**

- `ENABLE_APP_SANDBOX: NO` (critical — see Section 4 Tech Stack)
- `LSUIElement: true` in Info.plist (menu bar app with no Dock icon)
- `MACOSX_DEPLOYMENT_TARGET: 14.0`
- `CODE_SIGN_IDENTITY: "-"` (ad-hoc / "Sign to Run Locally" — no developer account needed)
- `CODE_SIGN_STYLE: Manual`
- Link `Carbon.framework` (for `RegisterEventHotKey`)
- Link `AVFoundation.framework` (for `AVAudioPlayer`)
- Link `UserNotifications.framework` (for notifications)
- Link `AppKit.framework` (implicitly via SwiftUI but explicit for `NSPasteboard`, `NSWorkspace`)
- `PRODUCT_BUNDLE_IDENTIFIER: com.nathan.voicelive`
- Usage description string `NSAppleEventsUsageDescription` is not required (we do not use AppleScript/AppleEvents; we use `CGEventPost` which is gated by Accessibility not by an Info.plist key)

### 11.2 XcodeBuildMCP (for building and running)

[XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) is an MCP server that exposes `xcodebuild` tooling to Claude Code. It operates on *existing* `.xcodeproj` files (it does not scaffold new projects — that's what xcodegen handles).

```bash
brew tap getsentry/xcodebuildmcp
brew install xcodebuildmcp
```

Added to Claude Code's MCP config:

```json
{
  "mcpServers": {
    "XcodeBuildMCP": {
      "command": "xcodebuildmcp",
      "args": ["mcp"]
    }
  }
}
```

Claude Code uses XcodeBuildMCP to: list schemes, build the project, capture compiler errors, run the built `.app`, and capture its log output. All iteration happens without manual Xcode interaction.

### 11.3 Code signing

For personal use on Nathan's own Mac, no Apple Developer account is required. The `CODE_SIGN_IDENTITY: "-"` setting means "ad-hoc signed" — the binary is signed with a throwaway identity sufficient for local execution but not distribution. Gatekeeper will not block execution of locally-built apps signed this way.

### 11.4 Limits of automation (manual steps that cannot be automated)

These steps require Nathan's physical presence at the Mac running the app because macOS requires explicit human consent:

1. **Grant Accessibility permission on first hotkey press.** macOS shows a dialog; Nathan clicks through to System Settings → Privacy & Security → Accessibility → toggles VoiceLive on. Quits and relaunches the app.
2. **Grant Notification permission on first launch.** macOS shows a prompt; Nathan clicks Allow.
3. **(Optional) Add VoiceLive to Login Items.** System Settings → General → Login Items → + → select `VoiceLive.app`.

Everything else — scaffolding, coding, building, unit testing, iterating on compiler errors — is fully automated.

## 12. Out of Scope (Explicitly)

The following are intentionally *not* in scope for this design and should not be added during implementation without a new spec:

- Settings UI (SwiftUI preferences window)
- Voice dropdown populated from `/v1/voices`
- Hotkey rebinding UI
- Keychain storage for the API key
- Streaming audio playback via `AVAudioEngine`
- Text chunking for selections over 5000 characters
- Retry logic with exponential backoff
- Multiple profiles (different voices for different contexts)
- Clipboard history integration
- CLI companion
- Status bar animation during loading
- A "read clipboard directly" fallback mode

Any of these can become a follow-up project with its own spec.

## 13. Open Questions Resolved During Brainstorming

| Question | Resolution |
|---|---|
| Clipboard capture vs. manual copy-first? | Simulated `⌘C` (Accessibility permission acceptable) |
| Tech stack: Swift vs. Python vs. Electron? | Swift + SwiftUI (reliability over iteration speed for a daily-use utility) |
| Interrupt, queue, or toggle on repeat hotkey? | Interrupt (stop-then-start) |
| Which hotkey? | `⌥R` (Option is a standard modifier, avoids `CGEventTap`) |
| Hardcoded config or settings UI? | Hardcoded in `Config.swift`, gitignored |
| Visual feedback? | Menu bar icon state changes only (no confirmation sound) |
| Error verbosity? | Icon error state + macOS notification with details |

## 14. Success Criteria

The project is done when all of the following are true:

1. `⌥R` works globally in iTerm, Safari, and Notes with arbitrary selections
2. Interrupt behavior works: second press during playback replaces the first
3. All eleven error cases in Section 7 produce the correct feedback (notification text for ten of them; `os_log` + permanent error icon for the "notification permission denied" case)
4. Menu bar icon transitions through idle → loading → playing → idle on success
5. Menu bar icon shows error state for 2 seconds on any failure
6. Unit tests for `ElevenLabsClient` pass and cover all ten listed cases
7. Manual smoke test checklist passes end-to-end
8. After quitting the app, pressing `⌥R` does nothing (the hotkey is properly unregistered in `applicationWillTerminate`). After relaunching, the hotkey works again on first press.
9. `Config.swift` is gitignored; `Config.example.swift` is committed
10. The `.app` launches cleanly from `/Applications` after being added as a macOS Login Item
