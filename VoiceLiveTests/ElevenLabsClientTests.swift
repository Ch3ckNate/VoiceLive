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
}
