import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstracts the HTTP layer so the client can be tested without a network
/// and so the platform-specific streaming API (`URLSession.bytes`) stays in
/// one place.
public protocol HTTPLineTransport: Sendable {
    /// Sends the request and returns the status code and the body as lines.
    func send(_ request: URLRequest) async throws -> (statusCode: Int, lines: AsyncThrowingStream<String, Error>)
}

/// Minimal client for the Claude Messages API (no official Swift SDK exists,
/// so this speaks raw HTTPS + Server-Sent Events).
public struct ClaudeClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let apiVersion = "2023-06-01"

    public let apiKey: String
    public let baseURL: URL
    public let transport: HTTPLineTransport

    public init(apiKey: String, baseURL: URL = ClaudeClient.defaultBaseURL, transport: HTTPLineTransport) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport
    }

    public func makeURLRequest(_ request: MessageRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !request.betaHeaders.isEmpty {
            urlRequest.setValue(request.betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        urlRequest.httpBody = try encoder.encode(request)
        return urlRequest
    }

    /// Streams a message. Text arrives as `.textDelta`; the stream ends with
    /// `.completed` or throws a `ClaudeError`.
    public func stream(_ request: MessageRequest) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ClaudeError.missingAPIKey
                    }
                    let urlRequest = try makeURLRequest(request)
                    let (status, lines) = try await transport.send(urlRequest)

                    guard (200..<300).contains(status) else {
                        var body = ""
                        for try await line in lines { body += line + "\n" }
                        throw Self.httpError(status: status, body: body)
                    }

                    var parser = SSEParser()
                    var state = StreamState()
                    for try await line in lines {
                        for event in parser.consume(line: line) {
                            for output in try state.handle(event) { continuation.yield(output) }
                        }
                        if state.finished { break }
                    }
                    if !state.finished, let event = parser.finish() {
                        for output in try state.handle(event) { continuation.yield(output) }
                    }
                    guard state.finished else {
                        throw ClaudeError.invalidResponse("stream ended before message_stop")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience: streams and returns the full text.
    public func complete(_ request: MessageRequest, onDelta: (@Sendable (String) -> Void)? = nil) async throws -> (text: String, model: String?, usage: ClaudeUsage) {
        var text = ""
        var model: String?
        var usage = ClaudeUsage()
        for try await event in stream(request) {
            switch event {
            case let .started(m): model = m
            case .thinking: break
            case let .textDelta(delta):
                text += delta
                onDelta?(delta)
            case let .completed(_, u): usage = u
            }
        }
        return (text, model, usage)
    }

    static func httpError(status: Int, body: String) -> ClaudeError {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            return .http(status: status, type: error["type"] as? String, message: (error["message"] as? String) ?? body)
        }
        return .http(status: status, type: nil, message: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Tracks a single streamed message and converts raw SSE events.
struct StreamState {
    private(set) var finished = false
    private var usage = ClaudeUsage()
    private var stopReason: String?
    private var stopDetails: [String: Any]?
    private var announcedThinking = false

    mutating func handle(_ event: SSEEvent) throws -> [ClaudeStreamEvent] {
        guard let data = event.data.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String ?? event.event
        else {
            throw ClaudeError.invalidResponse("malformed event: \(event.data.prefix(200))")
        }

        switch type {
        case "message_start":
            let message = json["message"] as? [String: Any]
            if let u = message?["usage"] as? [String: Any] { merge(usage: u) }
            return [.started(model: (message?["model"] as? String) ?? "")]

        case "content_block_start":
            let block = json["content_block"] as? [String: Any]
            switch block?["type"] as? String {
            case "thinking", "redacted_thinking":
                guard !announcedThinking else { return [] }
                announcedThinking = true
                return [.thinking]
            case "text":
                if let text = block?["text"] as? String, !text.isEmpty { return [.textDelta(text)] }
                return []
            case "fallback":
                // A fallback model took over after a decline; report which model continues.
                if let to = block?["to"] as? [String: Any], let model = to["model"] as? String {
                    return [.started(model: model)]
                }
                return []
            default:
                return []
            }

        case "content_block_delta":
            let delta = json["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String {
                return [.textDelta(text)]
            }
            return []

        case "message_delta":
            if let delta = json["delta"] as? [String: Any] {
                if let reason = delta["stop_reason"] as? String { stopReason = reason }
                if let details = delta["stop_details"] as? [String: Any] { stopDetails = details }
            }
            if let u = json["usage"] as? [String: Any] { merge(usage: u) }
            return []

        case "message_stop":
            finished = true
            if stopReason == "refusal" {
                throw ClaudeError.refusal(
                    category: stopDetails?["category"] as? String,
                    explanation: stopDetails?["explanation"] as? String
                )
            }
            return [.completed(stopReason: stopReason, usage: usage)]

        case "error":
            let error = json["error"] as? [String: Any]
            throw ClaudeError.api(
                type: (error?["type"] as? String) ?? "error",
                message: (error?["message"] as? String) ?? event.data
            )

        default: // ping, content_block_stop, unknown future events
            return []
        }
    }

    private mutating func merge(usage u: [String: Any]) {
        if let v = u["input_tokens"] as? Int { usage.inputTokens = v }
        if let v = u["output_tokens"] as? Int { usage.outputTokens = v }
        if let v = u["cache_read_input_tokens"] as? Int { usage.cacheReadInputTokens = v }
        if let v = u["cache_creation_input_tokens"] as? Int { usage.cacheCreationInputTokens = v }
    }
}

#if canImport(Darwin)
/// Production transport built on `URLSession.bytes(for:)`.
public struct URLSessionLineTransport: HTTPLineTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (statusCode: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, lines)
    }
}
#endif
