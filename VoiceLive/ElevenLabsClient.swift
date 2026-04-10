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
