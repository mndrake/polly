import Foundation

/// Models offered in Settings, with the request features each supports.
public enum ClaudeModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-4-5"

    public static let `default`: ClaudeModel = .opus

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus: return "Claude Opus 5.5 — best quality"
        case .sonnet: return "Claude Sonnet 5.5 — faster, lower cost"
        case .haiku: return "Claude Haiku 4.5 — fastest, lowest cost"
        }
    }

    /// `output_config.effort` is accepted (Haiku 4.5 rejects it).
    public var supportsEffort: Bool { self != .haiku }

    /// Server-side refusal fallbacks (`fallbacks: "default"`).
    public var supportsDefaultFallbacks: Bool { self != .haiku }
}

public enum ClaudeEffort: String, Codable, Sendable, CaseIterable, Identifiable {
    case low, medium, high

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

// MARK: - Request

public struct MessageRequest: Encodable, Sendable {
    public struct CacheControl: Encodable, Sendable {
        public var type = "ephemeral"
    }

    public struct TextBlock: Encodable, Sendable {
        public var type = "text"
        public var text: String
        public var cache_control: CacheControl?

        public init(_ text: String, cached: Bool = false) {
            self.text = text
            self.cache_control = cached ? CacheControl() : nil
        }
    }

    public struct Message: Encodable, Sendable {
        public var role: String
        public var content: [TextBlock]

        public init(role: String, content: [TextBlock]) {
            self.role = role
            self.content = content
        }
    }

    public struct OutputConfig: Encodable, Sendable {
        public var effort: String
    }

    public var model: String
    public var max_tokens: Int
    public var stream: Bool
    public var system: [TextBlock]?
    public var messages: [Message]
    public var output_config: OutputConfig?
    public var fallbacks: String?

    public init(
        model: ClaudeModel,
        maxTokens: Int,
        system: String?,
        messages: [Message],
        effort: ClaudeEffort?,
        stream: Bool = true
    ) {
        self.model = model.rawValue
        self.max_tokens = maxTokens
        self.stream = stream
        self.system = system.map { [TextBlock($0)] }
        self.messages = messages
        self.output_config = (model.supportsEffort ? effort : nil).map { OutputConfig(effort: $0.rawValue) }
        self.fallbacks = model.supportsDefaultFallbacks ? "default" : nil
    }

    /// Beta headers required by the features this request uses.
    public var betaHeaders: [String] {
        fallbacks == nil ? [] : ["server-side-fallback-2026-07-01"]
    }
}

// MARK: - Response / stream events

public struct ClaudeUsage: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadInputTokens: Int = 0
    public var cacheCreationInputTokens: Int = 0

    public init() {}
}

public enum ClaudeStreamEvent: Sendable, Equatable {
    /// The model that is answering (may change if a fallback model takes over).
    case started(model: String)
    /// The model is thinking; no visible text yet.
    case thinking
    case textDelta(String)
    case completed(stopReason: String?, usage: ClaudeUsage)
}

public enum ClaudeError: Error, Sendable, Equatable, LocalizedError {
    case missingAPIKey
    case http(status: Int, type: String?, message: String)
    case api(type: String, message: String)
    case refusal(category: String?, explanation: String?)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Anthropic API key in Settings to generate summaries."
        case let .http(status, type, message):
            switch status {
            case 401: return "The Anthropic API key was rejected (401). Check it in Settings."
            case 429: return "Rate limited by the Anthropic API (429). Try again shortly."
            case 529: return "The Anthropic API is overloaded (529). Try again shortly."
            default: return "Anthropic API error \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
            }
        case let .api(type, message):
            return "Anthropic API error (\(type)): \(message)"
        case let .refusal(category, explanation):
            var text = "Claude declined to process this request"
            if let category { text += " (\(category))" }
            if let explanation, !explanation.isEmpty { text += ": \(explanation)" }
            return text + "."
        case let .invalidResponse(detail):
            return "Unexpected response from the Anthropic API: \(detail)"
        }
    }

    /// Whether retrying the same request later may succeed.
    public var isRetryable: Bool {
        switch self {
        case let .http(status, _, _): return status == 408 || status == 429 || status >= 500
        case let .api(type, _): return type == "overloaded_error" || type == "api_error" || type == "rate_limit_error"
        default: return false
        }
    }
}
