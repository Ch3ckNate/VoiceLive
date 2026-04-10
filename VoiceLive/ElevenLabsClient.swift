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

final class ElevenLabsClient: TextSynthesizing {
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
}
