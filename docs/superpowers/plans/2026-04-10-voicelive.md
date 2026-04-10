# VoiceLive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a personal-use macOS menu bar app that reads highlighted text aloud via ElevenLabs TTS when the user presses `⌥R`.

**Architecture:** Swift + SwiftUI menu bar app (`MenuBarExtra`) with a single `AppState` coordinator driving a dumb-worker pipeline: `HotkeyManager` → `SelectionCapturer` → `ElevenLabsClient` → `AudioPlayer`. Rapid hotkey presses cancel the previous in-flight `Task` before starting a new one. Project is scaffolded via `xcodegen` from a checked-in `project.yml`, and built/run via XcodeBuildMCP. **App sandbox is explicitly disabled** (mandatory for `CGEventPost` to work across process boundaries).

**Tech Stack:** Swift 5.9, SwiftUI `MenuBarExtra`, Carbon `RegisterEventHotKey`, `CGEventPost`, `NSPasteboard`, `URLSession` (async/await), `AVAudioPlayer`, `UNUserNotificationCenter`, `os_log`. Tooling: `xcodegen` (Homebrew), `xcodebuild` (via XcodeBuildMCP MCP server).

**Design spec:** `docs/superpowers/specs/2026-04-10-voicelive-design.md`

---

## File Structure

Files this plan creates (all paths relative to `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/`):

| File | Responsibility |
|---|---|
| `project.yml` | xcodegen project spec — source of truth for the Xcode project settings |
| `.gitignore` | Excludes `Config.swift`, regenerated `.xcodeproj`, build artifacts, macOS junk |
| `README.md` | One-line setup instructions for future-Nathan |
| `VoiceLive/Info.plist` | `LSUIElement = true`, bundle metadata |
| `VoiceLive/VoiceLiveApp.swift` | `@main` SwiftUI App with `MenuBarExtra`. Owns `AppState`, runs bootstrap |
| `VoiceLive/Config.example.swift` | Template `Config` enum committed to git |
| `VoiceLive/Config.swift` | Real `Config` with API key — **gitignored** |
| `VoiceLive/HotkeyManager.swift` | Registers `⌥R` via Carbon, installs event handler on RunLoop |
| `VoiceLive/SelectionCapturer.swift` | Simulates `⌘C` via `CGEventPost`, reads pasteboard, uses `changeCount` to detect "no selection" |
| `VoiceLive/ElevenLabsClient.swift` | Async HTTP client for `/v1/text-to-speech/{voice_id}/stream` |
| `VoiceLive/AudioPlayer.swift` | `AVAudioPlayer` wrapper (holds player as stored property) |
| `VoiceLive/StatusItemController.swift` | `@Observable` icon-state holder with `flashError()` helper |
| `VoiceLive/NotificationManager.swift` | `UNUserNotificationCenter` wrapper |
| `VoiceLive/AppState.swift` | Pipeline coordinator. Holds `inFlightTask`. Implements cancel-then-start rule |
| `VoiceLiveTests/ElevenLabsClientTests.swift` | 10 unit tests covering happy path + error catalog |
| `VoiceLiveTests/MockURLProtocol.swift` | Custom `URLProtocol` for mocking `URLSession` in tests |

---

## Task 1: Environment setup

**Files:**
- Create: `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/.git/` (via `git init`)

- [ ] **Step 1: Install xcodegen via Homebrew**

Run:
```bash
brew install xcodegen
```

Expected: installed without errors. Verify with:
```bash
xcodegen --version
```

(Note: the earlier plan draft also proposed installing XcodeBuildMCP, but it is not a Homebrew formula and registering an MCP server would require restarting the Claude Code session anyway. The rest of the plan uses the `xcodebuild` CLI directly, so no MCP server is needed.)

- [ ] **Step 3: Initialize git repo and create feature branch**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
git init
git checkout -b nathan/feat/voicelive
```

Expected: `Initialized empty Git repository` and `Switched to a new branch 'nathan/feat/voicelive'`.

- [ ] **Step 4: Verify Xcode is installed**

Run:
```bash
xcodebuild -version
```

Expected: Xcode version string (e.g. `Xcode 16.0`). If not installed, abort the plan.

---

## Task 2: xcodegen project scaffolding

**Files:**
- Create: `project.yml`
- Create: `VoiceLive/Info.plist`
- Create: `VoiceLive/VoiceLiveApp.swift` (minimal empty shell)
- Create: `VoiceLiveTests/` (empty directory at this point)

- [ ] **Step 1: Write `project.yml`**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/project.yml`:

```yaml
name: VoiceLive
options:
  bundleIdPrefix: com.nathan
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "5.9"
    ENABLE_APP_SANDBOX: NO
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    CODE_SIGNING_REQUIRED: NO
    CODE_SIGNING_ALLOWED: NO
    ENABLE_HARDENED_RUNTIME: NO
    DEVELOPMENT_TEAM: ""

targets:
  VoiceLive:
    type: application
    platform: macOS
    sources:
      - path: VoiceLive
    info:
      path: VoiceLive/Info.plist
      properties:
        LSUIElement: true
        CFBundleName: VoiceLive
        CFBundleDisplayName: VoiceLive
        CFBundleIdentifier: com.nathan.voicelive
        CFBundleShortVersionString: "1.0"
        CFBundleVersion: "1"
        CFBundleExecutable: VoiceLive
        NSHumanReadableCopyright: ""
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.nathan.voicelive
        PRODUCT_NAME: VoiceLive
        GENERATE_INFOPLIST_FILE: NO
        INFOPLIST_FILE: VoiceLive/Info.plist
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
    dependencies:
      - sdk: Carbon.framework
      - sdk: AVFoundation.framework
      - sdk: UserNotifications.framework
      - sdk: AppKit.framework

  VoiceLiveTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: VoiceLiveTests
    settings:
      base:
        BUNDLE_LOADER: "$(TEST_HOST)"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/VoiceLive.app/Contents/MacOS/VoiceLive"
    dependencies:
      - target: VoiceLive
```

- [ ] **Step 2: Write minimal `VoiceLive/VoiceLiveApp.swift` shell**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/VoiceLiveApp.swift`:

```swift
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
```

- [ ] **Step 3: Create placeholder `VoiceLive/Info.plist`**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: Create empty test directory**

Run:
```bash
mkdir -p /Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLiveTests
touch /Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLiveTests/.gitkeep
```

- [ ] **Step 5: Generate the Xcode project**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
```

Expected: `Loaded project:` followed by target listing, then `Created project at VoiceLive.xcodeproj`.

- [ ] **Step 6: Verify the project builds (empty shell)**

Use XcodeBuildMCP's `build_macos` tool (or the `xcodebuild` CLI):
```bash
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. If it fails, inspect the error, fix the `project.yml` or `Info.plist`, re-run `xcodegen generate`, and rebuild.

- [ ] **Step 7: Commit**

Run:
```bash
git add project.yml VoiceLive/VoiceLiveApp.swift VoiceLive/Info.plist VoiceLiveTests/.gitkeep
git commit -m "chore: scaffold Xcode project via xcodegen"
```

---

## Task 3: Gitignore, README, Config templates

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `VoiceLive/Config.example.swift`
- Create: `VoiceLive/Config.swift` (gitignored)

- [ ] **Step 1: Write `.gitignore`**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/.gitignore`:

```gitignore
# xcodegen regenerates this from project.yml
VoiceLive.xcodeproj/

# Real config with API key — never commit
VoiceLive/Config.swift

# Xcode build artifacts
build/
DerivedData/
*.xcuserstate
*.xcworkspace/xcuserdata/

# macOS cruft
.DS_Store

# Swift Package Manager
.build/
Packages/
```

- [ ] **Step 2: Write `README.md`**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/README.md`:

```markdown
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
```

- [ ] **Step 3: Write `Config.example.swift`**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/Config.example.swift`:

```swift
import Foundation

// Template for Config.swift. Copy this file to Config.swift and fill in the
// real values. Config.swift is gitignored so the real secrets never land
// in version control.
enum ConfigExample {
    static let elevenLabsApiKey: String = "PASTE_YOUR_ELEVENLABS_API_KEY_HERE"
    static let voiceId: String = "PASTE_A_VOICE_ID_HERE"
    static let modelId: String = "eleven_turbo_v2_5"
    static let maxChars: Int = 5000
    static let settleDelayMs: UInt32 = 40
    static let bundleId: String = "com.nathan.voicelive"
    static let logSubsystem: String = "com.nathan.voicelive"
}
```

- [ ] **Step 4: Write `Config.swift` with placeholders**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/Config.swift`:

```swift
import Foundation

// REAL secrets — this file is gitignored. Never commit it.
enum Config {
    static let elevenLabsApiKey: String = "PASTE_YOUR_ELEVENLABS_API_KEY_HERE"
    static let voiceId: String = "PASTE_A_VOICE_ID_HERE"
    static let modelId: String = "eleven_turbo_v2_5"
    static let maxChars: Int = 5000
    static let settleDelayMs: UInt32 = 40
    static let bundleId: String = "com.nathan.voicelive"
    static let logSubsystem: String = "com.nathan.voicelive"
}
```

- [ ] **Step 5: Regenerate the Xcode project and rebuild**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

Run:
```bash
git add .gitignore README.md VoiceLive/Config.example.swift
git commit -m "chore: add gitignore, README, and config template"
```

Note: `Config.swift` is NOT added because `.gitignore` excludes it. Verify with `git status` — `Config.swift` should be untracked and unlisted.

---

## Task 4: ElevenLabsClient error types and protocol skeleton

**Files:**
- Create: `VoiceLive/ElevenLabsClient.swift`

- [ ] **Step 1: Write the error enum and client skeleton**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/ElevenLabsClient.swift`:

```swift
import Foundation

enum ElevenLabsError: Error, Equatable {
    case invalidApiKey
    case rateLimited
    case httpError(Int)
    case networkError(String)
    case emptyResponse
    case invalidURL
}

struct ElevenLabsRequestBody: Encodable {
    let text: String
    let modelId: String

    enum CodingKeys: String, CodingKey {
        case text
        case modelId = "model_id"
    }
}

final class ElevenLabsClient {
    private let apiKey: String
    private let voiceId: String
    private let modelId: String
    private let session: URLSession

    init(apiKey: String, voiceId: String, modelId: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.voiceId = voiceId
        self.modelId = modelId
        self.session = session
    }

    func synthesize(text: String) async throws -> Data {
        fatalError("not implemented")
    }
}
```

- [ ] **Step 2: Regenerate Xcode project and build**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

Run:
```bash
git add VoiceLive/ElevenLabsClient.swift
git commit -m "feat: add ElevenLabsClient skeleton with error types"
```

---

## Task 5: Mock URLProtocol for tests

**Files:**
- Create: `VoiceLiveTests/MockURLProtocol.swift`

- [ ] **Step 1: Write the mock URLProtocol**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLiveTests/MockURLProtocol.swift`:

```swift
import Foundation

// Custom URLProtocol that intercepts URLSession requests during tests and
// returns canned responses set via `requestHandler`. Use by creating a
// URLSessionConfiguration with `protocolClasses = [MockURLProtocol.self]`
// and passing a session built from it into ElevenLabsClient.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.receivedRequests.append(request)

        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "MockURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No request handler set"]
            ))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
        receivedRequests = []
    }
}
```

- [ ] **Step 2: Regenerate project and build tests target**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build-for-testing
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VoiceLiveTests/MockURLProtocol.swift
git commit -m "test: add MockURLProtocol helper"
```

---

## Task 6: ElevenLabsClient happy path (TDD)

**Files:**
- Create: `VoiceLiveTests/ElevenLabsClientTests.swift`
- Modify: `VoiceLive/ElevenLabsClient.swift` (implement `synthesize`)

- [ ] **Step 1: Write the failing happy-path test**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLiveTests/ElevenLabsClientTests.swift`:

```swift
import XCTest
@testable import VoiceLive

final class ElevenLabsClientTests: XCTestCase {
    var session: URLSession!
    var client: ElevenLabsClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = ElevenLabsClient(
            apiKey: "test-api-key",
            voiceId: "test-voice-id",
            modelId: "test-model-id",
            session: session
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        client = nil
        super.tearDown()
    }

    func test_synthesize_status200_returnsAudioData() async throws {
        let expected = Data([0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02, 0x03])
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, expected)
        }

        let actual = try await client.synthesize(text: "Hello world")

        XCTAssertEqual(actual, expected)
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild test -project VoiceLive.xcodeproj -scheme VoiceLive \
    -only-testing:VoiceLiveTests/ElevenLabsClientTests/test_synthesize_status200_returnsAudioData
```

Expected: test fails with `fatalError("not implemented")` or similar (the skeleton throws `fatalError`).

- [ ] **Step 3: Implement `synthesize` to pass**

Replace the `synthesize` method in `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/ElevenLabsClient.swift`:

```swift
    func synthesize(text: String) async throws -> Data {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream") else {
            throw ElevenLabsError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body = ElevenLabsRequestBody(text: text, modelId: modelId)
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ElevenLabsError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsError.networkError("No HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            guard !data.isEmpty else { throw ElevenLabsError.emptyResponse }
            return data
        case 401:
            throw ElevenLabsError.invalidApiKey
        case 429:
            throw ElevenLabsError.rateLimited
        default:
            throw ElevenLabsError.httpError(httpResponse.statusCode)
        }
    }
```

- [ ] **Step 4: Run the test again and verify it passes**

Run the same command as Step 2. Expected: `Test Suite 'Selected tests' passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add VoiceLiveTests/ElevenLabsClientTests.swift VoiceLive/ElevenLabsClient.swift
git commit -m "feat: implement ElevenLabsClient happy path with test"
```

---

## Task 7: ElevenLabsClient error catalog tests

**Files:**
- Modify: `VoiceLiveTests/ElevenLabsClientTests.swift`

- [ ] **Step 1: Add tests for 401, 429, 500, network error, empty body**

Append the following methods inside the `ElevenLabsClientTests` class in `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLiveTests/ElevenLabsClientTests.swift` (before the closing `}`):

```swift
    func test_synthesize_status401_throwsInvalidApiKey() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await client.synthesize(text: "Hello")
            XCTFail("Expected invalidApiKey error")
        } catch let error as ElevenLabsError {
            XCTAssertEqual(error, .invalidApiKey)
        } catch {
            XCTFail("Expected ElevenLabsError, got \(error)")
        }
    }

    func test_synthesize_status429_throwsRateLimited() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await client.synthesize(text: "Hello")
            XCTFail("Expected rateLimited error")
        } catch let error as ElevenLabsError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("Expected ElevenLabsError, got \(error)")
        }
    }

    func test_synthesize_status500_throwsHttpError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await client.synthesize(text: "Hello")
            XCTFail("Expected httpError(500)")
        } catch let error as ElevenLabsError {
            XCTAssertEqual(error, .httpError(500))
        } catch {
            XCTFail("Expected ElevenLabsError, got \(error)")
        }
    }

    func test_synthesize_networkFailure_throwsNetworkError() async {
        MockURLProtocol.requestHandler = { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
            )
        }

        do {
            _ = try await client.synthesize(text: "Hello")
            XCTFail("Expected networkError")
        } catch let error as ElevenLabsError {
            if case .networkError = error {
                // ok
            } else {
                XCTFail("Expected networkError, got \(error)")
            }
        } catch {
            XCTFail("Expected ElevenLabsError, got \(error)")
        }
    }

    func test_synthesize_status200_emptyBody_throwsEmptyResponse() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await client.synthesize(text: "Hello")
            XCTFail("Expected emptyResponse error")
        } catch let error as ElevenLabsError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("Expected ElevenLabsError, got \(error)")
        }
    }
```

- [ ] **Step 2: Run the tests and verify all pass**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild test -project VoiceLive.xcodeproj -scheme VoiceLive \
    -only-testing:VoiceLiveTests/ElevenLabsClientTests
```

Expected: all 6 tests pass (happy path + 5 error cases). `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VoiceLiveTests/ElevenLabsClientTests.swift
git commit -m "test: add ElevenLabsClient error catalog coverage"
```

---

## Task 8: ElevenLabsClient request validation tests

**Files:**
- Modify: `VoiceLiveTests/ElevenLabsClientTests.swift`

- [ ] **Step 1: Add tests that validate the request shape**

Append inside the `ElevenLabsClientTests` class:

```swift
    func test_synthesize_urlContainsConfiguredVoiceId() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data([0x01]))
        }

        _ = try await client.synthesize(text: "Hi")

        let sent = MockURLProtocol.receivedRequests.first
        XCTAssertNotNil(sent)
        XCTAssertEqual(
            sent?.url?.absoluteString,
            "https://api.elevenlabs.io/v1/text-to-speech/test-voice-id/stream"
        )
    }

    func test_synthesize_setsXiApiKeyHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data([0x01]))
        }

        _ = try await client.synthesize(text: "Hi")

        let sent = MockURLProtocol.receivedRequests.first
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "xi-api-key"), "test-api-key")
    }

    func test_synthesize_setsContentTypeHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data([0x01]))
        }

        _ = try await client.synthesize(text: "Hi")

        let sent = MockURLProtocol.receivedRequests.first
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_synthesize_bodyContainsTextAndModelId() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data([0x01]))
        }

        _ = try await client.synthesize(text: "Read this aloud")

        let sent = MockURLProtocol.receivedRequests.first
        // Note: when a URLRequest is run through URLProtocol the httpBody is
        // often stripped in favour of httpBodyStream. Read either.
        let body: Data
        if let direct = sent?.httpBody {
            body = direct
        } else if let stream = sent?.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0 {
                    collected.append(buffer, count: read)
                } else {
                    break
                }
            }
            body = collected
        } else {
            XCTFail("No request body")
            return
        }

        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["text"] as? String, "Read this aloud")
        XCTAssertEqual(json?["model_id"] as? String, "test-model-id")
    }
```

- [ ] **Step 2: Run the tests and verify all pass**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild test -project VoiceLive.xcodeproj -scheme VoiceLive \
    -only-testing:VoiceLiveTests/ElevenLabsClientTests
```

Expected: all 10 tests pass.

- [ ] **Step 3: Commit**

```bash
git add VoiceLiveTests/ElevenLabsClientTests.swift
git commit -m "test: validate ElevenLabsClient request shape"
```

---

## Task 9: StatusItemController

**Files:**
- Create: `VoiceLive/StatusItemController.swift`

- [ ] **Step 1: Write the observable state class**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/StatusItemController.swift`:

```swift
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
```

- [ ] **Step 2: Regenerate project and build**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VoiceLive/StatusItemController.swift
git commit -m "feat: add StatusItemController with icon states"
```

---

## Task 10: AudioPlayer

**Files:**
- Create: `VoiceLive/AudioPlayer.swift`

- [ ] **Step 1: Write the AVAudioPlayer wrapper**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/AudioPlayer.swift`:

```swift
import Foundation
import AVFoundation

/// Plays audio data via AVAudioPlayer. The AVAudioPlayer instance is held
/// as a stored property for the entire playback duration — if it were a
/// local variable, ARC would deallocate it immediately and playback would
/// cut off within a fraction of a second.
final class AudioPlayer: NSObject {
    private var player: AVAudioPlayer?

    /// Callback fired on the main thread when playback completes naturally
    /// (not when explicitly stopped via `stop()`).
    var onFinished: (() -> Void)?

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    func play(data: Data) throws {
        let p = try AVAudioPlayer(data: data)
        p.delegate = self
        p.prepareToPlay()
        p.play()
        self.player = p
    }

    /// Stop playback immediately. Does NOT fire `onFinished`.
    func stop() {
        player?.stop()
        player = nil
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.player = nil
            self?.onFinished?()
        }
    }
}
```

- [ ] **Step 2: Regenerate project and build**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VoiceLive/AudioPlayer.swift
git commit -m "feat: add AudioPlayer wrapper with retained AVAudioPlayer"
```

---

## Task 11: HotkeyManager (Carbon)

**Files:**
- Create: `VoiceLive/HotkeyManager.swift`

- [ ] **Step 1: Write the Carbon hotkey wrapper with event handler**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/HotkeyManager.swift`:

```swift
import Foundation
import Carbon.HIToolbox

enum HotkeyError: Error {
    case registrationFailed(OSStatus)
    case handlerInstallFailed(OSStatus)
}

/// Global hotkey registrar using the Carbon RegisterEventHotKey API.
/// This is still the canonical way to register global hotkeys on macOS
/// because the newer NSEvent APIs either only work in-app or require
/// CGEventTap (which is much more heavyweight).
///
/// Registering a hotkey alone is not enough — Carbon also requires an
/// event handler installed on the application event target. Without the
/// handler, the OS accepts the registration but never invokes any
/// callback.
final class HotkeyManager {
    /// Called on the main thread every time the hotkey fires.
    var onHotkey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // 4-char code "vlhk" used as the EventHotKeyID signature. Any unique
    // value works; this just identifies our hotkey to Carbon.
    private let signature: OSType = 0x766C686B  // 'v' 'l' 'h' 'k'

    func register() throws {
        // Build the EventHotKeyID
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)

        // Register ⌥R (Option + R)
        // kVK_ANSI_R = 15 (defined in Carbon.HIToolbox.Events.h)
        // optionKey = 2048 (defined in Carbon.HIToolbox.Events.h)
        var rawHotKeyRef: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &rawHotKeyRef
        )
        guard regStatus == noErr, let ref = rawHotKeyRef else {
            throw HotkeyError.registrationFailed(regStatus)
        }
        self.hotKeyRef = ref

        // Install the event handler so the hotkey actually dispatches
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onHotkey?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        guard handlerStatus == noErr, let hRef = handlerRef else {
            // Roll back the hotkey registration if handler install fails
            UnregisterEventHotKey(ref)
            self.hotKeyRef = nil
            throw HotkeyError.handlerInstallFailed(handlerStatus)
        }
        self.eventHandlerRef = hRef
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let hRef = eventHandlerRef {
            RemoveEventHandler(hRef)
            eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}
```

- [ ] **Step 2: Regenerate project and build**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. If Carbon symbols (`kVK_ANSI_R`, `optionKey`, `kEventClassKeyboard`) are not found, the `Carbon.framework` dependency in `project.yml` is missing — check Task 2 Step 1.

- [ ] **Step 3: Commit**

```bash
git add VoiceLive/HotkeyManager.swift
git commit -m "feat: add Carbon-based global hotkey manager"
```

---

## Task 12: SelectionCapturer

**Files:**
- Create: `VoiceLive/SelectionCapturer.swift`

- [ ] **Step 1: Write the pasteboard capturer**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/SelectionCapturer.swift`:

```swift
import Foundation
import AppKit
import Carbon.HIToolbox

/// Captures the currently-selected text from any frontmost app by:
///   1. Saving the current pasteboard string
///   2. Recording the pasteboard changeCount
///   3. Simulating ⌘C via CGEventPost
///   4. Sleeping briefly for the target app to respond
///   5. Checking whether changeCount incremented — if not, no selection
///   6. Reading the captured text (if present)
///   7. Restoring the saved pasteboard string
///
/// The changeCount probe is what distinguishes "user had nothing selected"
/// from "user had something selected and also had something on the
/// clipboard." Without it, an unchanged clipboard after the fake ⌘C looks
/// identical to "captured the previous clipboard value".
final class SelectionCapturer {
    enum CaptureResult {
        case captured(String)
        case noSelection   // changeCount unchanged; nothing was copied
        case notText       // changeCount changed, but pasteboard has no text
    }

    private let settleDelayMicroseconds: UInt32

    init(settleDelayMilliseconds: UInt32 = Config.settleDelayMs) {
        self.settleDelayMicroseconds = settleDelayMilliseconds * 1000
    }

    func capture() -> CaptureResult {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let initialChangeCount = pasteboard.changeCount

        simulateCommandC()
        usleep(settleDelayMicroseconds)

        if pasteboard.changeCount == initialChangeCount {
            return .noSelection
        }

        let captured = pasteboard.string(forType: .string)

        // Restore the saved string regardless of result
        pasteboard.clearContents()
        if let saved {
            pasteboard.setString(saved, forType: .string)
        }

        guard let captured else { return .notText }
        return .captured(captured)
    }

    private func simulateCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeC = CGKeyCode(kVK_ANSI_C)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 2: Regenerate project and build**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VoiceLive/SelectionCapturer.swift
git commit -m "feat: add SelectionCapturer with changeCount detection"
```

---

## Task 13: NotificationManager

**Files:**
- Create: `VoiceLive/NotificationManager.swift`

- [ ] **Step 1: Write the notifications wrapper**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/NotificationManager.swift`:

```swift
import Foundation
import UserNotifications
import AppKit

final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    /// Request authorization to display notifications. Returns true if
    /// granted, false if denied or an error occurred.
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Check current authorization status without prompting.
    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Show a notification. Fire-and-forget — any error (e.g. permission
    /// denied after launch) is silently ignored.
    func show(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Open System Settings → Privacy & Security → Accessibility so the
    /// user can grant permission directly from the notification flow.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [ ] **Step 2: Regenerate project and build**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VoiceLive/NotificationManager.swift
git commit -m "feat: add NotificationManager wrapper"
```

---

## Task 14: AppState coordinator

**Files:**
- Create: `VoiceLive/AppState.swift`

- [ ] **Step 1: Write the pipeline coordinator**

Create `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/AppState.swift`:

```swift
import Foundation
import AppKit
import SwiftUI
import Observation
import os.log

@MainActor
@Observable
final class AppState {
    let statusItem = StatusItemController()

    private let hotkeyManager = HotkeyManager()
    private let selectionCapturer = SelectionCapturer()
    private let elevenLabsClient: ElevenLabsClient
    private let audioPlayer = AudioPlayer()
    private let notifications = NotificationManager.shared
    private let log = Logger(subsystem: Config.logSubsystem, category: "AppState")

    private var inFlightTask: Task<Void, Never>?

    init() {
        self.elevenLabsClient = ElevenLabsClient(
            apiKey: Config.elevenLabsApiKey,
            voiceId: Config.voiceId,
            modelId: Config.modelId
        )

        self.audioPlayer.onFinished = { [weak self] in
            guard let self else { return }
            self.statusItem.state = .idle
        }

        self.hotkeyManager.onHotkey = { [weak self] in
            self?.handleHotkey()
        }
    }

    /// Called once on app launch. Requests permissions, registers the
    /// hotkey, and surfaces any startup errors as notifications.
    func bootstrap() async {
        // 1. Notification permission — if denied the error feedback path
        //    is broken, so we bail into a permanent error state.
        let notifGranted = await notifications.requestAuthorization()
        if !notifGranted {
            log.error("Notification permission denied")
            statusItem.state = .error
            return
        }

        // 2. Register the hotkey
        do {
            try hotkeyManager.register()
        } catch HotkeyError.registrationFailed(let code) {
            log.error("Hotkey registration failed: \(code, privacy: .public)")
            notifications.show(
                title: "VoiceLive",
                body: "Could not register ⌥R hotkey — another app may be using it. Check Keyboard Shortcuts or quit the conflicting app."
            )
            statusItem.state = .error
            return
        } catch HotkeyError.handlerInstallFailed(let code) {
            log.error("Hotkey handler install failed: \(code, privacy: .public)")
            notifications.show(
                title: "VoiceLive",
                body: "VoiceLive failed to install its keyboard event handler."
            )
            statusItem.state = .error
            return
        } catch {
            log.error("Unexpected hotkey error: \(String(describing: error), privacy: .public)")
            statusItem.state = .error
            return
        }

        // 3. Accessibility — prompt if missing. We prompt last because the
        //    prompt is modal and may take the user out of our app.
        let axOptions: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ]
        let trusted = AXIsProcessTrustedWithOptions(axOptions)
        if !trusted {
            log.error("Accessibility not granted")
            notifications.show(
                title: "VoiceLive",
                body: "VoiceLive needs Accessibility permission. Open System Settings → Privacy & Security → Accessibility, then quit and relaunch VoiceLive."
            )
            statusItem.state = .error
        }
    }

    /// Called by the HotkeyManager every time ⌥R is pressed. Implements
    /// the cancel-then-start interrupt rule: any in-flight pipeline is
    /// torn down before a new one starts.
    func handleHotkey() {
        // 1. Cancel any in-flight task (ElevenLabs request may still be
        //    pending). The task checks Task.isCancelled after its awaits
        //    and skips playback if so.
        inFlightTask?.cancel()
        inFlightTask = nil

        // 2. Stop any currently playing audio instantly
        if audioPlayer.isPlaying {
            audioPlayer.stop()
        }

        statusItem.state = .loading

        // 3. Capture the selection synchronously
        let capture = selectionCapturer.capture()
        let text: String
        switch capture {
        case .captured(let t):
            text = t
        case .noSelection:
            notifications.show(title: "VoiceLive", body: "No text selected.")
            statusItem.flashError()
            return
        case .notText:
            notifications.show(title: "VoiceLive", body: "Selection is not text.")
            statusItem.flashError()
            return
        }

        // 4. Validate the captured text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            notifications.show(title: "VoiceLive", body: "No text selected.")
            statusItem.flashError()
            return
        }
        if trimmed.count > Config.maxChars {
            notifications.show(
                title: "VoiceLive",
                body: "Selection too long (\(trimmed.count) characters, max \(Config.maxChars))."
            )
            statusItem.flashError()
            return
        }

        // 5. Kick off async synthesis + playback
        inFlightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.elevenLabsClient.synthesize(text: trimmed)
                try Task.checkCancellation()
                try self.audioPlayer.play(data: audio)
                self.statusItem.state = .playing
            } catch is CancellationError {
                // Superseded by a newer hotkey press — do nothing
                return
            } catch ElevenLabsError.invalidApiKey {
                self.log.error("ElevenLabs 401")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "ElevenLabs: invalid API key."
                )
                self.statusItem.flashError()
            } catch ElevenLabsError.rateLimited {
                self.log.error("ElevenLabs 429")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "ElevenLabs: rate limited. Try again in a moment."
                )
                self.statusItem.flashError()
            } catch ElevenLabsError.httpError(let code) {
                self.log.error("ElevenLabs HTTP \(code, privacy: .public)")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "ElevenLabs error: HTTP \(code)."
                )
                self.statusItem.flashError()
            } catch ElevenLabsError.networkError(let msg) {
                self.log.error("Network error: \(msg, privacy: .public)")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "Network error: \(msg)."
                )
                self.statusItem.flashError()
            } catch ElevenLabsError.emptyResponse {
                self.log.error("ElevenLabs empty response")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "ElevenLabs returned an empty response."
                )
                self.statusItem.flashError()
            } catch {
                self.log.error("Playback failed: \(String(describing: error), privacy: .public)")
                self.notifications.show(
                    title: "VoiceLive",
                    body: "Audio playback failed."
                )
                self.statusItem.flashError()
            }
        }
    }

    func shutdown() {
        inFlightTask?.cancel()
        audioPlayer.stop()
        hotkeyManager.unregister()
    }
}
```

- [ ] **Step 2: Regenerate project and build**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VoiceLive/AppState.swift
git commit -m "feat: add AppState pipeline coordinator with cancel-then-start rule"
```

---

## Task 15: Wire everything into VoiceLiveApp.swift

**Files:**
- Modify: `VoiceLive/VoiceLiveApp.swift` (replace the shell with real wiring)

- [ ] **Step 1: Replace the shell with the full app entry**

Replace the contents of `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/VoiceLiveApp.swift` with:

```swift
import SwiftUI
import AppKit

@main
struct VoiceLiveApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("VoiceLive")
                    .font(.headline)
                Divider()
                Text("Status: \(appState.statusItem.statusLabel)")
                    .foregroundStyle(.secondary)
                Divider()
                Button("Quit VoiceLive") {
                    appState.shutdown()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(12)
            .frame(minWidth: 180)
            .task {
                await appState.bootstrap()
            }
        } label: {
            Image(systemName: appState.statusItem.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 2: Regenerate project and build**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. If you see errors about `@Observable` or `@State`, confirm `MACOSX_DEPLOYMENT_TARGET` is 14.0 in `project.yml`.

- [ ] **Step 3: Commit**

```bash
git add VoiceLive/VoiceLiveApp.swift
git commit -m "feat: wire AppState into VoiceLiveApp with MenuBarExtra"
```

---

## Task 16: Full build + unit test verification

**Files:** (none modified)

- [ ] **Step 1: Clean build of the entire app**

Run:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodegen generate
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug clean build
```

Expected: `** BUILD SUCCEEDED **`. Zero warnings (except possibly about `@testable import VoiceLive` which is normal).

- [ ] **Step 2: Run all unit tests**

Run:
```bash
xcodebuild test -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug
```

Expected: all 10 `ElevenLabsClientTests` pass. `** TEST SUCCEEDED **`.

- [ ] **Step 3: Locate the built `.app` bundle**

Run:
```bash
find ~/Library/Developer/Xcode/DerivedData -name "VoiceLive.app" -type d 2>/dev/null | head -1
```

Expected: a path like `~/Library/Developer/Xcode/DerivedData/VoiceLive-<hash>/Build/Products/Debug/VoiceLive.app`. Save this path — it's what Nathan drags to `/Applications` for the smoke test.

- [ ] **Step 4: Verify sandbox is disabled**

Run:
```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "VoiceLive.app" -type d 2>/dev/null | head -1)
codesign -d --entitlements - "$APP_PATH" 2>&1
```

Expected: either no entitlements at all, or entitlements WITHOUT `com.apple.security.app-sandbox = true`. If you see `<key>com.apple.security.app-sandbox</key><true/>`, the sandbox is still enabled and the app will silently fail at runtime — go back to `project.yml` and check `ENABLE_APP_SANDBOX: NO`.

- [ ] **Step 5: Commit any project regeneration artifacts**

Run `git status`. If anything outside the gitignored paths has changed, investigate and commit. Otherwise skip.

---

## Task 17: Manual smoke test checklist (requires Nathan at his Mac)

**Files:** (none)

This task cannot be automated. It covers the steps Nathan must perform manually because macOS requires explicit human consent for permissions and because the end-to-end flow involves real audio through real speakers.

- [ ] **Step 1: Fill in real credentials in `Config.swift`**

Open `/Users/nathan/Documents/Projects/Sandbox/VoiceLive/VoiceLive/Config.swift` and replace:
- `elevenLabsApiKey` with the real ElevenLabs API key
- `voiceId` with a valid voice ID (find one with `curl -s https://api.elevenlabs.io/v1/voices -H "xi-api-key: YOUR_KEY" | jq '.voices[] | {voice_id, name}'`)

Rebuild:
```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
xcodebuild -project VoiceLive.xcodeproj -scheme VoiceLive -configuration Debug build
```

- [ ] **Step 2: Copy the `.app` to `/Applications`**

```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "VoiceLive.app" -type d 2>/dev/null | head -1)
cp -R "$APP_PATH" /Applications/
```

- [ ] **Step 3: First launch — grant Notifications permission**

Double-click `/Applications/VoiceLive.app`. macOS shows: *"'VoiceLive' Would Like to Send You Notifications."* → click **Allow**.

- [ ] **Step 4: First hotkey press — grant Accessibility permission**

In iTerm, highlight the word "Hello". Press `⌥R`. macOS shows: *"VoiceLive would like to control this computer using accessibility features."*

Click through to System Settings → Privacy & Security → Accessibility. Toggle VoiceLive **on**. **Quit VoiceLive** (menu bar icon → Quit VoiceLive). **Relaunch** from `/Applications`.

- [ ] **Step 5: Happy path smoke tests**

Run each of the following and verify the expected outcome:

| Test | Expected |
|---|---|
| Highlight a sentence in iTerm, press `⌥R` | Hear the sentence read aloud |
| Highlight a sentence in Safari, press `⌥R` | Hear the sentence read aloud |
| Highlight a sentence in Notes, press `⌥R` | Hear the sentence read aloud |

- [ ] **Step 6: Error path smoke tests**

| Test | Expected |
|---|---|
| Press `⌥R` with nothing selected | Notification: "No text selected." Menu bar icon flashes red for 2s then returns to idle |
| Select an image in Safari, press `⌥R` | Notification: "Selection is not text." |
| Select > 5000 characters in a text editor, press `⌥R` | Notification: "Selection too long (X characters, max 5000)." |
| Turn off Wi-Fi, press `⌥R` on a selection | Notification containing "Network error:" |

- [ ] **Step 7: Interrupt test**

| Test | Expected |
|---|---|
| Press `⌥R` on a long selection, then quickly press `⌥R` on a different short selection | First audio cuts off instantly, second audio plays the short selection without mixing |
| Press `⌥R` on a selection, immediately (during the loading pause) press `⌥R` on a different selection | Only the second selection plays; first is aborted before any audio |

- [ ] **Step 8: Quit and relaunch test**

| Test | Expected |
|---|---|
| Quit VoiceLive via menu bar | `⌥R` does nothing afterward (hotkey released) |
| Relaunch VoiceLive from `/Applications` | `⌥R` works again on first press |

- [ ] **Step 9: (Optional) Add to Login Items**

System Settings → General → Login Items → **+** → select `/Applications/VoiceLive.app` → add. Reboot and verify VoiceLive appears in the menu bar automatically.

- [ ] **Step 10: Final commit on the branch**

```bash
cd /Users/nathan/Documents/Projects/Sandbox/VoiceLive
git log --oneline
```

Expected: a clean log of feat/test/chore commits, no AI attribution anywhere. All smoke tests passing. `nathan/feat/voicelive` branch is ready for personal use. No further action needed — VoiceLive is shipped (to Nathan, on Nathan's Mac).

---

## Rollback / Debugging Notes

If any step fails:

- **"Command not found: xcodegen" / "xcodebuildmcp"** → Task 1 didn't run. Install via Homebrew.
- **xcodegen fails with "unknown key"** → the installed xcodegen is too old. `brew upgrade xcodegen`.
- **xcodebuild error about missing Info.plist** → check `INFOPLIST_FILE: VoiceLive/Info.plist` setting and that the file exists.
- **Swift compiler: "Cannot find 'kVK_ANSI_R' in scope"** → `Carbon.framework` dependency missing from `project.yml`. Re-check Task 2 Step 1.
- **Swift compiler: "Cannot find '@Observable'"** → macOS deployment target is <14. Check `project.yml` Step 1.
- **App builds but `⌥R` does nothing at runtime** → sandbox check (Task 16 Step 4). If sandbox is on, the `CGEventPost` is a no-op.
- **App builds, hotkey fires, but "No text selected" every time** → `InstallEventHandler` was wired but not `CGEventPost` → check `SelectionCapturer.simulateCommandC()`. Also check Accessibility permission is really granted by running `tccutil list | grep voicelive` (if available) or via System Settings.
- **Audio starts and immediately stops** → `AVAudioPlayer` not retained. Check that `AudioPlayer.swift` stores the player as a property, not a local.
- **Unit tests hang** → check that every async test has an await and no mock handler is leaking between tests via `MockURLProtocol.reset()` in `setUp`.
