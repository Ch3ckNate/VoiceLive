# VoiceLive

Personal-use macOS menu bar app. Highlight text in any app, press `⌥R`, and
VoiceLive reads it aloud via ElevenLabs TTS.

## Setup

1. Install xcodegen: `brew install xcodegen`
2. Copy the config template and fill in your API key:
   ```
   cp VoiceLive/Config.example.swift VoiceLive/Config.swift
   # Open VoiceLive/Config.swift and paste your ElevenLabs API key and voice ID
   ```
3. Generate the Xcode project: `xcodegen generate`
4. Build: `xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive build`
5. Find the built `.app` in `~/Library/Developer/Xcode/DerivedData/VoiceLive-*/Build/Products/Debug/VoiceLive.app`
6. Drag it to `/Applications`
7. First launch: grant Accessibility + Notifications permissions when prompted
8. Optionally add to System Settings → General → Login Items

## Finding your voice ID

```
curl -s https://api.elevenlabs.io/v1/voices \
  -H "xi-api-key: YOUR_API_KEY" | jq '.voices[] | {voice_id, name}'
```

Paste the `voice_id` you want into `Config.swift`.
