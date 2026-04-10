# VoiceLive

Personal-use macOS 14+ menu bar app. Highlight text in any app, press `⌥R`,
and VoiceLive reads it aloud via OpenAI TTS. Pressing `⌥R` again cancels
any in-flight request or playback and starts a new one.

## Setup

1. Install xcodegen: `brew install xcodegen`
2. Copy the config template and fill in your API key:
   ```
   cp VoiceLive/Config.example.swift VoiceLive/Config.swift
   # Open VoiceLive/Config.swift and paste your OpenAI API key
   ```
   `Config.swift` is gitignored.
3. Generate the Xcode project: `xcodegen generate`
4. Build: `xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive build`
5. Find the built `.app` in `~/Library/Developer/Xcode/DerivedData/VoiceLive-*/Build/Products/Debug/VoiceLive.app`
6. Drag it to `/Applications`
7. First launch: grant Accessibility + Notifications permissions when prompted.
   Accessibility is required for the selection-capture copy step; Notifications
   are used for error feedback. If Accessibility is denied, open
   System Settings → Privacy & Security → Accessibility, enable VoiceLive,
   then quit and relaunch.
8. Optionally add to System Settings → General → Login Items

**Note on re-signing:** Every time VoiceLive is rebuilt and re-signed with an
ad-hoc identity (`codesign --force --deep --sign -`), macOS silently revokes
the prior Accessibility grant because the code signature changes. If the app
suddenly reports "No text selected" after a redeploy, open System Settings →
Privacy & Security → Accessibility and toggle VoiceLive off then on. See
`docs/NOTES.md` for the full story.

## Running tests

```
xcodebuild test \
  -project VoiceLive.xcodeproj \
  -scheme VoiceLive \
  -destination 'platform=macOS'
```

Test targets:
- `OpenAIClientTests` — HTTP client behaviour via `MockURLProtocol`
- `SpeechSynthesizerTests` — chunked streaming + error mapping
- `SelectionCapturerTests` — pasteboard changeCount probe + modifier release wait
- `AppStateIntegrationTests` — full pipeline via protocol mocks in `Mocks.swift`
- `StatusItemControllerTests` — menu bar state transitions

`AppState` takes its collaborators through the protocols in
`VoiceLive/Protocols.swift`, so tests inject fakes without touching real
hotkeys, network, audio, or notifications.

## Config options

`Config.swift` exposes:

- `openAIKey` — your OpenAI API key from https://platform.openai.com/api-keys
- `openAIModel` — `tts-1` (fast, cheap, ~$15/1M chars) or `tts-1-hd` (higher quality, 2x cost)
- `openAIVoice` — one of `alloy`, `echo`, `fable`, `onyx`, `nova`, `shimmer`
- `maxChars` — clamp on selection length before synthesis (default 5000)
- `settleDelayMs` — how long to wait after synthetic ⌘C for the target app to populate the clipboard (default 150)
- `modifierReleaseTimeoutMs` — how long to wait for hotkey modifiers to release before posting the synthetic ⌘C (default 300)
