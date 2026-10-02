import Foundation

/// Anything that can stream a Claude response for a `MessageRequest`.
public protocol ClaudeStreaming: Sendable {
    func stream(_ request: MessageRequest) -> AsyncThrowingStream<ClaudeStreamEvent, Error>
}

extension ClaudeClient: ClaudeStreaming {}

public enum ClaudeCodeError: Error, Sendable, Equatable, LocalizedError {
    case notInstalled
    case notSignedIn(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code isn't installed. Install it from https://claude.com/claude-code, or set its location in Settings."
        case let .notSignedIn(detail):
            return "Claude Code isn't signed in. Open Terminal, run `claude`, and sign in with your Claude account (/login). (\(detail))"
        case let .failed(detail):
            return "Claude Code failed: \(detail)"
        }
    }
}

/// Generates summaries through the user's own Claude Code installation
/// (`claude -p`), so usage counts against their Claude plan (Pro, Max, Team,
/// Enterprise) instead of a pay-per-token API key.
///
/// Claude Code runs headless with no tools, no MCP servers, no project
/// settings and no saved session, in an empty temporary directory, and its
/// `stream-json` output is translated into `ClaudeStreamEvent`s.
public struct ClaudeCodeClient: ClaudeStreaming {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public func arguments(for request: MessageRequest) -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", request.model,
            // Text only: no tools, MCP servers, slash commands or project settings.
            "--tools", "",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--setting-sources", "user",
            "--disable-slash-commands",
            "--no-session-persistence",
        ]
        if let system = request.system?.map(\.text).joined(separator: "\n\n"), !system.isEmpty {
            args += ["--system-prompt", system]
        }
        return args
    }

    /// The user turn's text blocks, sent on stdin.
    public func prompt(for request: MessageRequest) -> String {
        request.messages
            .filter { $0.role == "user" }
            .flatMap(\.content)
            .map(\.text)
            .joined(separator: "\n\n")
    }

    /// Environment for the child process: never pass an API key (that would
    /// bill the API instead of the plan), and make sure a Node-based install
    /// can find `node` even though GUI apps get a minimal PATH.
    public func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["ANTHROPIC_API_KEY"] = nil
        env["ANTHROPIC_AUTH_TOKEN"] = nil
        let home = env["HOME"] ?? NSHomeDirectory()
        let extra = [
            executable.deletingLastPathComponent().path,
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extra + existing).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        return env
    }

    public func stream(_ request: MessageRequest) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        let executable = self.executable
        let arguments = arguments(for: request)
        let input = prompt(for: request)
        let environment = environment()

        return AsyncThrowingStream { continuation in
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                continuation.finish(throwing: ClaudeCodeError.notInstalled)
                return
            }

            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("polly-claude-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = workDir
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let state = CLIStreamState()
            let lines = LineBuffer()
            let errors = ErrorBuffer()

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: workDir)
                continuation.finish(throwing: ClaudeCodeError.failed(error.localizedDescription))
                return
            }

            // Write the (possibly large) prompt on its own thread so neither
            // side blocks on a full pipe.
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = stdin.fileHandleForWriting
                handle.write(Data(input.utf8))
                try? handle.close()
            }
            // Drain stderr concurrently for the same reason.
            let stderrDone = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                errors.append(stderr.fileHandleForReading.readDataToEndOfFile())
                stderrDone.signal()
            }

            // Read stdout with blocking reads on a dedicated thread. An empty
            // read means end of output, which (unlike readability callbacks)
            // is always observed, so the final `result` line is processed
            // before we decide how the run ended.
            Thread.detachNewThread {
                let handle = stdout.fileHandleForReading
                while true {
                    let data = handle.availableData
                    var pending = lines.append(data)
                    let atEOF = data.isEmpty
                    if atEOF, let last = lines.flush() { pending.append(last) }
                    if !state.hasFailed {
                        do {
                            for line in pending {
                                for event in try state.handle(line: line) { continuation.yield(event) }
                            }
                        } catch {
                            state.markFailed()
                            continuation.finish(throwing: error)
                        }
                    }
                    if atEOF { break }
                }

                process.waitUntilExit()
                stderrDone.wait()
                try? FileManager.default.removeItem(at: workDir)
                guard !state.hasFailed else { return }
                do {
                    for event in try state.finish(exitCode: process.terminationStatus, stderr: errors.text) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Common install locations for the `claude` CLI, most specific first.
    public static func candidateLocations(home: String = NSHomeDirectory()) -> [URL] {
        [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ].map { URL(fileURLWithPath: $0) }
    }

    /// Finds an installed `claude` executable, preferring an explicit path.
    public static func locate(explicitPath: String? = nil, home: String = NSHomeDirectory()) -> URL? {
        if let explicitPath = explicitPath?.trimmingCharacters(in: .whitespaces), !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return candidateLocations(home: home).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - stream-json parsing

/// Translates Claude Code `--output-format stream-json` lines into stream events.
final class CLIStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var emittedText = false
    private var announcedThinking = false
    private var completed = false
    private var failed = false
    private var usage = ClaudeUsage()

    var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    func handle(line rawLine: String) throws -> [ClaudeStreamEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String
        else { return [] } // tolerate non-JSON noise

        lock.lock()
        defer { lock.unlock() }

        switch type {
        case "system":
            if json["subtype"] as? String == "init", let model = json["model"] as? String {
                return [.started(model: model)]
            }
            return []

        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return [] }
            switch event["type"] as? String {
            case "content_block_start":
                let block = event["content_block"] as? [String: Any]
                if let kind = block?["type"] as? String, kind == "thinking" || kind == "redacted_thinking", !announcedThinking {
                    announcedThinking = true
                    return [.thinking]
                }
                if block?["type"] as? String == "text", let text = block?["text"] as? String, !text.isEmpty {
                    emittedText = true
                    return [.textDelta(text)]
                }
                return []
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String {
                    emittedText = true
                    return [.textDelta(text)]
                }
                return []
            default:
                return []
            }

        case "result":
            completed = true
            if let u = json["usage"] as? [String: Any] {
                usage.inputTokens = u["input_tokens"] as? Int ?? 0
                usage.outputTokens = u["output_tokens"] as? Int ?? 0
                usage.cacheReadInputTokens = u["cache_read_input_tokens"] as? Int ?? 0
                usage.cacheCreationInputTokens = u["cache_creation_input_tokens"] as? Int ?? 0
            }
            let resultText = json["result"] as? String ?? ""
            let isError = (json["is_error"] as? Bool ?? false) || (json["subtype"] as? String).map { $0 != "success" } ?? false
            if isError {
                throw Self.classify(resultText.isEmpty ? (json["subtype"] as? String ?? "unknown error") : resultText)
            }
            var events: [ClaudeStreamEvent] = []
            // Without partial messages, the full text only arrives here.
            if !emittedText && !resultText.isEmpty {
                emittedText = true
                events.append(.textDelta(resultText))
            }
            events.append(.completed(stopReason: "end_turn", usage: usage))
            return events

        default: // "assistant", "user", "rate_limit_event", future types
            return []
        }
    }

    func finish(exitCode: Int32, stderr: String) throws -> [ClaudeStreamEvent] {
        lock.lock()
        let done = completed
        lock.unlock()
        guard !done else { return [] }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw Self.classify(detail.isEmpty ? "exited with status \(exitCode) without a result" : detail)
    }

    static func classify(_ message: String) -> ClaudeCodeError {
        let lower = message.lowercased()
        let authHints = ["/login", "not logged in", "log in", "login", "authentication", "invalid api key", "oauth", "unauthorized"]
        if authHints.contains(where: { lower.contains($0) }) {
            return .notSignedIn(message)
        }
        return .failed(message)
    }
}

/// Splits incoming bytes into UTF-8 lines.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return line
    }
}

final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ more: Data) {
        lock.lock()
        if data.count < 64_000 { data.append(more) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
