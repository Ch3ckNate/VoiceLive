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
