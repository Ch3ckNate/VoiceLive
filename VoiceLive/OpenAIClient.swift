import Foundation
import os.log

/// Thin HTTP client for the OpenAI Text-to-Speech endpoint.
/// POST https://api.openai.com/v1/audio/speech → raw MP3 bytes.
final class OpenAIClient: TextToSpeechClient {
    struct Configuration {
        let apiKey: String
        let model: String
        let voice: String
        let baseURL: URL

        init(
            apiKey: String = Config.openAIKey,
            model: String = Config.openAIModel,
            voice: String = Config.openAIVoice,
            baseURL: URL = URL(string: "https://api.openai.com/v1")!
        ) {
            self.apiKey = apiKey
            self.model = model
            self.voice = voice
            self.baseURL = baseURL
        }
    }

    private let config: Configuration
    private let session: URLSession
    private let log = Logger(subsystem: Config.logSubsystem, category: "OpenAIClient")

    init(config: Configuration = Configuration(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func synthesize(text: String) async throws -> Data {
        guard !config.apiKey.isEmpty, config.apiKey != "PASTE_YOUR_OPENAI_KEY_HERE" else {
            throw OpenAIError.missingAPIKey
        }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.model,
            "input": text,
            "voice": config.voice,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            guard !data.isEmpty else { throw OpenAIError.emptyAudio }
            return data
        case 401:
            throw OpenAIError.unauthorized
        case 429:
            throw OpenAIError.rateLimited
        case 500...599:
            throw OpenAIError.serverError(http.statusCode)
        default:
            throw OpenAIError.httpError(http.statusCode)
        }
    }
}

enum OpenAIError: Error, Equatable {
    case missingAPIKey
    case invalidResponse
    case emptyAudio
    case unauthorized
    case rateLimited
    case serverError(Int)
    case httpError(Int)

    /// Short, user-facing description for the menu bar dropdown. Not
    /// localized — this is a personal-use app — but phrased so the reader
    /// can act on it (fix key, wait, etc.) rather than just "error".
    var userMessage: String {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is missing. Paste it into Config.swift and rebuild."
        case .invalidResponse:
            return "OpenAI returned an unexpected response."
        case .emptyAudio:
            return "OpenAI returned empty audio."
        case .unauthorized:
            return "OpenAI rejected the API key (401). Check it's valid."
        case .rateLimited:
            return "OpenAI rate limited (429). Wait a moment and try again."
        case .serverError(let code):
            return "OpenAI server error (\(code)). Try again shortly."
        case .httpError(let code):
            return "OpenAI returned HTTP \(code)."
        }
    }
}
