import XCTest
@testable import PollyCore

final class ClaudeCodeClientTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("polly-cc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Writes a fake `claude` that records its args/stdin/env and prints `output`.
    private func fakeClaude(output: [String], exitCode: Int = 0, stderr: String = "") throws -> URL {
        let outFile = tempDir.appendingPathComponent("out.jsonl")
        try (output.joined(separator: "\n") + "\n").write(to: outFile, atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(tempDir.path)/args.txt"
        cat > "\(tempDir.path)/stdin.txt"
        echo "${ANTHROPIC_API_KEY:-unset}" > "\(tempDir.path)/apikey.txt"
        pwd > "\(tempDir.path)/cwd.txt"
        cat "\(outFile.path)"
        printf '%s' '\(stderr)' >&2
        exit \(exitCode)
        """
        let url = tempDir.appendingPathComponent("claude")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func request() -> MessageRequest {
        let meeting = Meeting(segments: [TranscriptSegment(speaker: .others, start: 0, end: 2, text: "Ship it Friday")])
        return MeetingPrompts.summaryRequest(for: meeting, myName: nil, model: .opus, effort: .medium)
    }

    private let happyOutput = [
        #"{"type":"system","subtype":"init","model":"claude-opus-5-5","session_id":"s1","tools":[]}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-opus-5-5"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}"#,
        ##"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"# Launch "}}}"##,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"plan"}}}"#,
        ##"{"type":"assistant","message":{"content":[{"type":"text","text":"# Launch plan"}]}}"##,
        ##"{"type":"result","subtype":"success","is_error":false,"result":"# Launch plan","session_id":"s1","usage":{"input_tokens":900,"output_tokens":12}}"##,
    ]

    func testStreamsTextFromSubscriptionCLI() async throws {
        let client = ClaudeCodeClient(executable: try fakeClaude(output: happyOutput))
        var events: [ClaudeStreamEvent] = []
        for try await event in client.stream(request()) { events.append(event) }

        XCTAssertEqual(events.first, .started(model: "claude-opus-5-5"))
        XCTAssertTrue(events.contains(.thinking))
        let text = events.compactMap { if case let .textDelta(t) = $0 { return t } else { return nil } }.joined()
        XCTAssertEqual(text, "# Launch plan", "text comes from deltas only, not repeated from the result")
        guard case let .completed(_, usage) = events.last else { return XCTFail("no completion") }
        XCTAssertEqual(usage.inputTokens, 900)
        XCTAssertEqual(usage.outputTokens, 12)

        // The transcript goes in on stdin, the API key is stripped, and it runs outside any project.
        let stdin = try String(contentsOf: tempDir.appendingPathComponent("stdin.txt"), encoding: .utf8)
        XCTAssertTrue(stdin.contains("Ship it Friday"))
        XCTAssertTrue(stdin.contains("## Action Items"))
        XCTAssertEqual(try String(contentsOf: tempDir.appendingPathComponent("apikey.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "unset")
        let cwd = try String(contentsOf: tempDir.appendingPathComponent("cwd.txt"), encoding: .utf8)
        XCTAssertTrue(cwd.contains("polly-claude-"))

        let args = try String(contentsOf: tempDir.appendingPathComponent("args.txt"), encoding: .utf8)
            .components(separatedBy: "\n")
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("stream-json"))
        XCTAssertTrue(args.contains("--include-partial-messages"))
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertFalse(args.contains("--bare"), "bare mode can't use the subscription login")
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "claude-opus-5-5")
        XCTAssertTrue(args[args.firstIndex(of: "--system-prompt")! + 1].hasPrefix("You are Polly"))
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
    }

    func testResultTextUsedWhenNoPartialMessages() async throws {
        let output = [
            #"{"type":"system","subtype":"init","model":"claude-sonnet-5-5"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Short summary"}"#,
        ]
        let client = ClaudeCodeClient(executable: try fakeClaude(output: output))
        let result = try await collect(client)
        XCTAssertEqual(result, "Short summary")
    }

    func testNotSignedIn() async throws {
        let output = [#"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#]
        let client = ClaudeCodeClient(executable: try fakeClaude(output: output, exitCode: 1))
        do {
            _ = try await collect(client)
            XCTFail("expected error")
        } catch let error as ClaudeCodeError {
            guard case .notSignedIn = error else { return XCTFail("got \(error)") }
        }
    }

    func testCrashWithoutResultReportsStderr() async throws {
        let client = ClaudeCodeClient(executable: try fakeClaude(output: ["not json"], exitCode: 2, stderr: "boom"))
        do {
            _ = try await collect(client)
            XCTFail("expected error")
        } catch let error as ClaudeCodeError {
            XCTAssertEqual(error, .failed("boom"))
        }
    }

    func testMissingExecutable() async {
        let client = ClaudeCodeClient(executable: tempDir.appendingPathComponent("nope"))
        do {
            _ = try await collect(client)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeError, .notInstalled)
        }
    }

    func testLargePromptDoesNotDeadlock() async throws {
        var meeting = Meeting()
        meeting.segments = (0..<4000).map {
            TranscriptSegment(speaker: $0 % 2 == 0 ? .me : .others, start: Double($0 * 5), end: Double($0 * 5 + 4),
                              text: "This is sentence number \($0) of a very long meeting transcript.")
        }
        let request = MeetingPrompts.summaryRequest(for: meeting, myName: nil, model: .opus, effort: .medium)
        let client = ClaudeCodeClient(executable: try fakeClaude(output: happyOutput))
        var text = ""
        for try await event in client.stream(request) {
            if case let .textDelta(t) = event { text += t }
        }
        XCTAssertEqual(text, "# Launch plan")
        let stdinSize = try FileManager.default.attributesOfItem(atPath: tempDir.appendingPathComponent("stdin.txt").path)[.size] as? Int
        XCTAssertGreaterThan(stdinSize ?? 0, 200_000)
    }

    func testLocatePrefersExplicitPath() throws {
        let fake = try fakeClaude(output: [])
        XCTAssertEqual(ClaudeCodeClient.locate(explicitPath: fake.path)?.path, fake.path)
        XCTAssertNil(ClaudeCodeClient.locate(explicitPath: tempDir.appendingPathComponent("missing").path))
        XCTAssertNil(ClaudeCodeClient.locate(home: tempDir.path).flatMap { $0.path.hasPrefix(tempDir.path) ? $0 : nil })
    }

    func testEnvironmentStripsKeysAndExtendsPath() {
        let client = ClaudeCodeClient(executable: URL(fileURLWithPath: "/Users/me/.local/bin/claude"))
        let env = client.environment(base: ["ANTHROPIC_API_KEY": "sk", "ANTHROPIC_AUTH_TOKEN": "t", "PATH": "/usr/bin:/bin", "HOME": "/Users/me"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        let path = env["PATH"]!.components(separatedBy: ":")
        XCTAssertEqual(path.first, "/Users/me/.local/bin")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/bin"))
        XCTAssertEqual(path.count, Set(path).count, "no duplicates")
    }

    private func collect(_ client: ClaudeCodeClient) async throws -> String {
        var text = ""
        for try await event in client.stream(request()) {
            if case let .textDelta(t) = event { text += t }
        }
        return text
    }
}
