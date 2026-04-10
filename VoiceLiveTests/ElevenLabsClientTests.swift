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
