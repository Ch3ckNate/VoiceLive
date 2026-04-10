import XCTest
@testable import VoiceLive

final class OpenAIClientTests: XCTestCase {
    var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        session = nil
        super.tearDown()
    }

    private func makeClient(
        apiKey: String = "sk-test",
        model: String = "tts-1",
        voice: String = "onyx"
    ) -> OpenAIClient {
        let cfg = OpenAIClient.Configuration(
            apiKey: apiKey,
            model: model,
            voice: voice,
            baseURL: URL(string: "https://api.openai.com/v1")!
        )
        return OpenAIClient(config: cfg, session: session)
    }

    // MARK: - Happy path

    func test_synthesize_sendsCorrectRequest() async throws {
        var capturedRequest: URLRequest?
        let expectedAudio = Data([0xFF, 0xFB, 0x90, 0x00])

        MockURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, expectedAudio)
        }

        let client = makeClient()
        let audio = try await client.synthesize(text: "hello world")

        XCTAssertEqual(audio, expectedAudio)
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")

        // URLProtocol doesn't expose httpBody directly — use bodyStream.
        let body = capturedRequest?.httpBodyStreamData() ?? capturedRequest?.httpBody ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "tts-1")
        XCTAssertEqual(json?["voice"] as? String, "onyx")
        XCTAssertEqual(json?["input"] as? String, "hello world")
        XCTAssertEqual(json?["response_format"] as? String, "mp3")
    }

    // MARK: - Error paths

    func test_synthesize_missingAPIKey_throws() async {
        let client = makeClient(apiKey: "")
        await assertThrows(OpenAIError.missingAPIKey) {
            _ = try await client.synthesize(text: "hi")
        }
    }

    func test_synthesize_placeholderAPIKey_throws() async {
        let client = makeClient(apiKey: "PASTE_YOUR_OPENAI_KEY_HERE")
        await assertThrows(OpenAIError.missingAPIKey) {
            _ = try await client.synthesize(text: "hi")
        }
    }

    func test_synthesize_unauthorized_throws() async {
        stubResponse(status: 401)
        let client = makeClient()
        await assertThrows(OpenAIError.unauthorized) {
            _ = try await client.synthesize(text: "hi")
        }
    }

    func test_synthesize_rateLimited_throws() async {
        stubResponse(status: 429)
        let client = makeClient()
        await assertThrows(OpenAIError.rateLimited) {
            _ = try await client.synthesize(text: "hi")
        }
    }

    func test_synthesize_serverError_throws() async {
        stubResponse(status: 503)
        let client = makeClient()
        await assertThrows(OpenAIError.serverError(503)) {
            _ = try await client.synthesize(text: "hi")
        }
    }

    func test_synthesize_otherHTTPError_throws() async {
        stubResponse(status: 404)
        let client = makeClient()
        await assertThrows(OpenAIError.httpError(404)) {
            _ = try await client.synthesize(text: "hi")
        }
    }

    func test_synthesize_emptyAudio_throws() async {
        stubResponse(status: 200, body: Data())
        let client = makeClient()
        await assertThrows(OpenAIError.emptyAudio) {
            _ = try await client.synthesize(text: "hi")
        }
    }

    func test_synthesize_networkFailure_throws() async {
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = makeClient()
        do {
            _ = try await client.synthesize(text: "hi")
            XCTFail("Expected network error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("Expected URLError, got \(error)")
        }
    }

    // MARK: - Helpers

    private func stubResponse(status: Int, body: Data = Data([0x01, 0x02])) {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
    }

    private func assertThrows(
        _ expected: OpenAIError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () async throws -> Void
    ) async {
        do {
            try await block()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch let error as OpenAIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected OpenAIError.\(expected), got \(error)", file: file, line: line)
        }
    }
}

private extension URLRequest {
    /// URLProtocol's startLoading receives a request whose body has been
    /// converted to a bodyStream. This reads the stream back into Data.
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
