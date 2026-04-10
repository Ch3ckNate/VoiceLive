# VoiceLive

Personal-use macOS 14+ menu bar app. Highlight text in any app, press `⌥R`,
and VoiceLive reads it aloud via ElevenLabs TTS. Pressing `⌥R` again cancels
any in-flight request or playback and starts a new one.

## Setup

1. Install xcodegen: `brew install xcodegen`
2. Copy the config template and fill in your API key:
   ```
   cp VoiceLive/Config.example.swift VoiceLive/Config.swift
   # Open VoiceLive/Config.swift and paste your ElevenLabs API key and voice ID
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

## Running tests

```
xcodebuild test \
  -project VoiceLive.xcodeproj \
  -scheme VoiceLive \
  -destination 'platform=macOS'
```

Test targets:
- `ElevenLabsClientTests` — HTTP client behaviour via `MockURLProtocol`
- `AppStateIntegrationTests` — full pipeline via protocol mocks in `Mocks.swift`
- `StatusItemControllerTests` — menu bar state transitions

`AppState` takes its collaborators through the protocols in
`VoiceLive/Protocols.swift`, so tests inject fakes without touching real
hotkeys, network, audio, or notifications.

## Finding your voice ID

```
curl -s https://api.elevenlabs.io/v1/voices \
  -H "xi-api-key: YOUR_API_KEY" | jq '.voices[] | {voice_id, name}'
```

Paste the `voice_id` you want into `Config.swift`.
