import XCTest
@testable import PollyCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Replays canned lines and records the request it was given.
final class MockTransport: HTTPLineTransport, @unchecked Sendable {
    let status: Int
    let lines: [String]
    private(set) var lastRequest: URLRequest?

    init(status: Int = 200, lines: [String]) {
        self.status = status
        self.lines = lines
    }

    func send(_ request: URLRequest) async throws -> (statusCode: Int, lines: AsyncThrowingStream<String, Error>) {
        lastRequest = request
        let lines = self.lines
        return (status, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}

final class ClaudeClientTests: XCTestCase {
    private func sse(_ events: [(String, String)], blankLines: Bool = true) -> [String] {
        events.flatMap { name, data -> [String] in
            blankLines ? ["event: \(name)", "data: \(data)", ""] : ["event: \(name)", "data: \(data)"]
        }
    }

    private var happyPath: [(String, String)] {
        [
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":1200,"output_tokens":1,"cache_read_input_tokens":1000}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("ping", #"{"type":"ping"}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", ##"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"# Weekly "}}"##),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"sync"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ]
    }

    private func request(model: ClaudeModel = .opus) -> MessageRequest {
        let meeting = Meeting(segments: [TranscriptSegment(speaker: .me, start: 0, end: 2, text: "Hello")])
        return MeetingPrompts.summaryRequest(for: meeting, myName: nil, model: model, effort: .medium)
    }

    func testStreamsTextAndUsage() async throws {
        let transport = MockTransport(lines: sse(happyPath))
        let client = ClaudeClient(apiKey: "sk-test", transport: transport)

        var events: [ClaudeStreamEvent] = []
        for try await event in client.stream(request()) { events.append(event) }

        XCTAssertEqual(events.first, .started(model: "claude-opus-5-5"))
        XCTAssertTrue(events.contains(.thinking))
        let text = events.compactMap { if case let .textDelta(t) = $0 { return t } else { return nil } }.joined()
        XCTAssertEqual(text, "# Weekly sync")
        guard case let .completed(stopReason, usage) = events.last else { return XCTFail("missing completion") }
        XCTAssertEqual(stopReason, "end_turn")
        XCTAssertEqual(usage.inputTokens, 1200)
        XCTAssertEqual(usage.outputTokens, 42)
        XCTAssertEqual(usage.cacheReadInputTokens, 1000)
    }

    func testToleratesMissingBlankLines() async throws {
        // URL.AsyncBytes.lines drops empty lines; the parser must still split events.
        let transport = MockTransport(lines: sse(happyPath, blankLines: false))
        let client = ClaudeClient(apiKey: "sk-test", transport: transport)
        let result = try await client.complete(request())
        XCTAssertEqual(result.text, "# Weekly sync")
        XCTAssertEqual(result.model, "claude-opus-5-5")
    }

    func testRequestShapeForOpus() throws {
        let transport = MockTransport(lines: [])
        let client = ClaudeClient(apiKey: "sk-test", transport: transport)
        let urlRequest = try client.makeURLRequest(request(model: .opus))

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertNil(body["thinking"], "Opus 5.5 thinking is always on; the parameter is omitted")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual((content.first?["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        XCTAssertTrue((content.first?["text"] as? String)?.contains("<transcript>") ?? false)
        XCTAssertNil(content.last?["cache_control"])
    }

    func testRequestShapeForHaikuOmitsUnsupportedFeatures() throws {
        let client = ClaudeClient(apiKey: "sk-test", transport: MockTransport(lines: []))
        let urlRequest = try client.makeURLRequest(request(model: .haiku))
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "anthropic-beta"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertNil(body["output_config"])
        XCTAssertNil(body["fallbacks"])
    }

    func testHTTPErrorIsDecoded() async {
        let transport = MockTransport(status: 401, lines: [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#])
        let client = ClaudeClient(apiKey: "sk-bad", transport: transport)
        do {
            _ = try await client.complete(request())
            XCTFail("expected error")
        } catch let error as ClaudeError {
            XCTAssertEqual(error, .http(status: 401, type: "authentication_error", message: "invalid x-api-key"))
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMidStreamErrorEvent() async {
        let lines = sse([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{}}}"#),
            ("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
        ])
        let client = ClaudeClient(apiKey: "sk", transport: MockTransport(lines: lines))
        do {
            _ = try await client.complete(request())
            XCTFail("expected error")
        } catch let error as ClaudeError {
            XCTAssertEqual(error, .api(type: "overloaded_error", message: "Overloaded"))
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRefusalThrows() async {
        let lines = sse([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"nope"}},"usage":{"output_tokens":0}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let client = ClaudeClient(apiKey: "sk", transport: MockTransport(lines: lines))
        do {
            _ = try await client.complete(request())
            XCTFail("expected refusal")
        } catch let error as ClaudeError {
            XCTAssertEqual(error, .refusal(category: "cyber", explanation: "nope"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFallbackBlockReportsNewModel() async throws {
        let lines = sse([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Hi"}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let client = ClaudeClient(apiKey: "sk", transport: MockTransport(lines: lines))
        let result = try await client.complete(request())
        XCTAssertEqual(result.model, "claude-opus-4-8")
        XCTAssertEqual(result.text, "Hi")
    }

    func testTruncatedStreamThrows() async {
        let lines = sse([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#),
        ])
        let client = ClaudeClient(apiKey: "sk", transport: MockTransport(lines: lines))
        do {
            _ = try await client.complete(request())
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error is ClaudeError)
        }
    }

    func testMissingAPIKey() async {
        let client = ClaudeClient(apiKey: "  ", transport: MockTransport(lines: []))
        do {
            _ = try await client.complete(request())
            XCTFail("expected error")
        } catch let error as ClaudeError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
