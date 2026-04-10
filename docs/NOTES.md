# VoiceLive Development Notes

Running log of findings, gotchas, and open threads from building VoiceLive. Not a polished doc — just stuff that burned me or that future-me will want to remember.

## Gotchas

### Ad-hoc re-signing revokes Accessibility permission

**Symptom:** After rebuilding and re-signing VoiceLive, pressing ⌥R shows "No text selected" in the dropdown — even when text is clearly selected.

**Root cause:** Every `codesign --force --deep --sign -` changes the code signature. macOS treats the re-signed binary as a different app from the perspective of its Privacy & Security database, so the prior Accessibility grant is silently invalidated. The app stays *listed* in System Settings → Privacy & Security → Accessibility but is toggled off behind the scenes.

Without Accessibility, `CGEvent.post(tap: .cghidEventTap)` for keyboard events targeted at other apps is silently dropped. The synthetic ⌘C never reaches the frontmost app, so `NSPasteboard.changeCount` never moves, and `SelectionCapturer` (correctly) reports "no selection."

**Why the bootstrap prompt doesn't save you:** `AXIsProcessTrustedWithOptions(prompt: true)` only surfaces the system dialog when the app is *absent* from the Accessibility list. If the app is present-but-disabled, the prompt never fires — you just silently get denied.

**Fix (every deploy):** Open System Settings → Privacy & Security → Accessibility → toggle VoiceLive off then on (or remove and re-add). Do this *immediately* after every `ditto` + `codesign` cycle.

**Diagnostic signal in logs:**
```
bash -c "log show --predicate 'subsystem == \"com.nathan.voicelive\"' --last 10m --info"
```
Look for `Accessibility not granted` at bootstrap and `changeCount unchanged after synthetic ⌘C` on every capture attempt. If you see both, it's this.

### Option modifier bleeds into synthetic ⌘C

**Symptom:** Selection capture fails in some apps even with Accessibility granted, especially when the hotkey is ⌥R (Option + R).

**Root cause:** The hotkey fires on keyDown, so at the moment we post our synthetic ⌘C, the user is still physically holding Option. `CGEvent.post(tap: .cghidEventTap)` merges the physical modifier state into the synthetic event at the HID tap layer — the target app sees `⌘⌥C`, not `⌘C`, and ignores it.

**Fix:** `SelectionCapturer.waitForModifiersRelease()` polls `NSEvent.modifierFlags` every 10ms for up to 300ms, waiting for Command/Option/Control/Shift to all clear before posting the synthetic event. Injected as a closure for testability.

### 40ms settle delay was too short for Electron apps

Pasteboard `changeCount` probe needs time for the target app to actually respond to the synthetic ⌘C. Native Cocoa apps respond in a handful of ms, but Electron/web views can take 50-100ms. Bumped `Config.settleDelayMs` from 40 to 150. Slower than I'd like but reliable.

### Swift trailing-closure binding bit me during test refactor

When I added `readModifierFlags` as a new init parameter to `SelectionCapturer`, I put it after `simulateCopy` — which broke every existing test call site using trailing closure syntax, because Swift silently re-bound the trailing closure to the new last parameter (with a type mismatch between `() -> Void` and `() -> NSEvent.ModifierFlags`).

**Lesson:** When adding closure parameters to a function with existing trailing-closure call sites, put the new closure *before* the existing trailing one, or explicitly label every call site. Don't append.

## Open Threads

- **Accessibility re-check in `handleHotkey()`** — `bootstrap()` already logs "Accessibility not granted" when the app lacks permission, but the first press of ⌥R immediately clears `lastError` and attempts capture, which silently fails and shows the misleading "No text selected" message. Fix: re-check `AXIsProcessTrustedWithOptions(nil)` at the top of `handleHotkey()` and surface a specific "re-enable in System Settings" error instead of falling through. Needs a `isAccessibilityTrusted: @escaping () -> Bool` injected dependency to keep tests deterministic.

- **TTS model choice** — currently on `tts-1` ($15/1M chars). `tts-1-hd` is 2x the cost but noticeably richer. Revisit if the robotic edge of `tts-1` becomes annoying. At ~20k chars/day usage, `tts-1` runs ~$9/month and `tts-1-hd` ~$18/month — cost isn't the deciding factor, ergonomics are.

- **Manual smoke test checklist** — there's a pending task for a structured smoke test across Safari, VS Code, Slack, Electron apps, Messages. I've been smoke-testing ad-hoc during development but never did a systematic pass.

- **Per-deploy code signing identity** — the ad-hoc signing workflow is what causes the Accessibility revocation every deploy. A real Developer ID cert would keep the signature stable across rebuilds and stop the revocation cycle. Not worth it until this escapes the "personal tool" phase.

## Design decisions worth remembering

- **ElevenLabs → OpenAI refactor:** Swapped TTS backends mid-build. OpenAI is cheaper ($15/1M vs ElevenLabs' pricier per-char), simpler API, and the quality on `tts-1` is fine for terminal output. Kept the `SpeechSynthesizing` protocol stable so AppState didn't care.

- **Chunked streaming TTS:** `SpeechSynthesizer` splits text into chunks and starts playback on the first chunk while later ones are still fetching. Time-to-first-audio is what matters for the hotkey UX — waiting for the full synthesis on long text felt broken.

- **Cancel-then-start interrupt rule:** Pressing ⌥R while speech is playing stops the current playback and starts the new one. Implemented by calling `synthesizer.stop()` at the top of `handleHotkey()`. `AVSpeechSynthesizer` fires `didCancel` which we don't listen for, so `onFinished` doesn't get called on the cancelled run, which means the new run's state transition doesn't get clobbered back to `.idle`.

- **`lastError` on `AppState`:** Observable field that the MenuBarExtra dropdown reads to show *why* something broke, instead of a generic "error" label. Cleared at the start of every `handleHotkey()` attempt. Populated by three paths: selection failures (`reportHotkeyError`), synthesizer errors (via `onError` callback), and bootstrap failures (hotkey registration, accessibility).

- **Dependency injection via protocols:** `HotkeyRegistering`, `SelectionCapturing`, `SpeechSynthesizing`, `NotificationPresenting`, `PasteboardAccess`. Every collaborator is injected into `AppState` so integration tests can run without touching the real system. `AppStateIntegrationTests.swift` exercises the full pipeline with mocks.

- **DI for `SelectionCapturer` timing and event posting:** `settleDelayMilliseconds`, `modifierReleaseTimeoutMilliseconds`, `pasteboard`, `readModifierFlags`, `simulateCopy` are all injectable. Tests use a `FakePasteboard` and a deterministic modifier-reader closure — no sleeps, no flakes.
