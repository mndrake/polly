import XCTest
@testable import PollyCore

final class TranscriptBuilderTests: XCTestCase {
    func testVolatileThenFinal() {
        var builder = TranscriptBuilder(echoSuppression: false)
        builder.apply(.init(speaker: .others, text: "hello", isFinal: false, start: 0, end: 1))
        XCTAssertEqual(builder.liveText[.others], "hello")
        builder.apply(.init(speaker: .others, text: "Hello everyone.", isFinal: true, start: 0, end: 1.5))
        XCTAssertNil(builder.liveText[.others])
        XCTAssertEqual(builder.segments.map(\.text), ["Hello everyone."])
    }

    func testOrderedByStartAcrossChannels() {
        var builder = TranscriptBuilder(echoSuppression: false)
        builder.apply(.init(speaker: .others, text: "second", isFinal: true, start: 5, end: 6))
        builder.apply(.init(speaker: .me, text: "first", isFinal: true, start: 1, end: 2))
        builder.apply(.init(speaker: .me, text: "third", isFinal: true, start: 7, end: 8))
        XCTAssertEqual(builder.segments.map(\.text), ["first", "second", "third"])
    }

    func testEmptyFinalsAreDropped() {
        var builder = TranscriptBuilder(echoSuppression: false)
        builder.apply(.init(speaker: .me, text: "  ", isFinal: true, start: 0, end: 1))
        XCTAssertTrue(builder.segments.isEmpty)
    }

    func testEchoOfRemoteSpeechIsSuppressed() {
        var builder = TranscriptBuilder(echoSuppression: true)
        builder.apply(.init(speaker: .others, text: "Can everyone see my screen now?", isFinal: true, start: 10, end: 12))
        builder.apply(.init(speaker: .me, text: "can everyone see my screen", isFinal: true, start: 10.3, end: 12.2))
        builder.flush()
        XCTAssertEqual(builder.segments.map(\.speaker), [.others])
        XCTAssertEqual(builder.suppressedEchoCount, 1)
    }

    func testEchoArrivingBeforeRemoteFinalIsStillSuppressed() {
        var builder = TranscriptBuilder(echoSuppression: true)
        builder.apply(.init(speaker: .me, text: "let's move on to the budget", isFinal: true, start: 20, end: 22))
        XCTAssertEqual(builder.displaySegments.count, 1, "pending segments are still shown while recording")
        builder.apply(.init(speaker: .others, text: "Let's move on to the budget.", isFinal: true, start: 20.1, end: 22.3))
        builder.flush()
        XCTAssertEqual(builder.segments.map(\.speaker), [.others])
    }

    func testGenuineReplyIsKept() {
        var builder = TranscriptBuilder(echoSuppression: true)
        builder.apply(.init(speaker: .others, text: "Can everyone see my screen now?", isFinal: true, start: 10, end: 12))
        builder.apply(.init(speaker: .me, text: "Yes, looks good from here", isFinal: true, start: 12.5, end: 14))
        builder.apply(.init(speaker: .others, text: "Great, let's start", isFinal: true, start: 30, end: 31))
        XCTAssertEqual(builder.segments.map(\.speaker), [.others, .me, .others])
    }

    func testFlushCommitsLiveText() {
        var builder = TranscriptBuilder(echoSuppression: false)
        builder.apply(.init(speaker: .me, text: "Done", isFinal: true, start: 0, end: 1))
        builder.apply(.init(speaker: .others, text: "trailing words", isFinal: false, start: 2, end: 3))
        builder.flush()
        XCTAssertEqual(builder.segments.map(\.text), ["Done", "trailing words"])
        XCTAssertTrue(builder.liveText.isEmpty)
    }
}

final class TranscriptFormatterTests: XCTestCase {
    func testTimestamps() {
        XCTAssertEqual(TranscriptFormatter.timestamp(0), "00:00")
        XCTAssertEqual(TranscriptFormatter.timestamp(75.9), "01:15")
        XCTAssertEqual(TranscriptFormatter.timestamp(3723), "1:02:03")
    }

    func testTurnsMergeSameSpeaker() {
        let segments = [
            TranscriptSegment(speaker: .me, start: 0, end: 2, text: "Hi."),
            TranscriptSegment(speaker: .me, start: 3, end: 4, text: "Can you hear me?"),
            TranscriptSegment(speaker: .others, start: 5, end: 6, text: "Yes."),
            TranscriptSegment(speaker: .others, start: 20, end: 21, text: "Later point."),
        ]
        let text = TranscriptFormatter.plainText(segments, myName: "Dana")
        XCTAssertEqual(text, """
        [00:00] Dana: Hi. Can you hear me?
        [00:05] Others: Yes.
        [00:20] Others: Later point.
        """)
    }
}

final class TimelineAlignerTests: XCTestCase {
    func testNoPaddingWhenContinuous() {
        var aligner = TimelineAligner(sampleRate: 16_000)
        XCTAssertEqual(aligner.silenceFrames(beforeBufferAt: 0), 0)
        aligner.didFeed(frames: 16_000)
        XCTAssertEqual(aligner.silenceFrames(beforeBufferAt: 1.1), 0)
    }

    func testPadsGaps() {
        var aligner = TimelineAligner(sampleRate: 16_000)
        aligner.didFeed(frames: 16_000)
        XCTAssertEqual(aligner.silenceFrames(beforeBufferAt: 3), 32_000)
        XCTAssertEqual(aligner.fedDuration, 3, accuracy: 0.0001)
    }

    func testFirstBufferArrivingLatePadsFromStart() {
        var aligner = TimelineAligner(sampleRate: 48_000)
        XCTAssertEqual(aligner.silenceFrames(beforeBufferAt: 0.5), 24_000)
    }
}

final class PromptAndExportTests: XCTestCase {
    func testExtractTitle() {
        XCTAssertEqual(MeetingPrompts.extractTitle(fromSummary: "\n# Q3 Roadmap Review\n\n## Summary\n..."), "Q3 Roadmap Review")
        XCTAssertNil(MeetingPrompts.extractTitle(fromSummary: "## Summary\n# Late title"))
        XCTAssertNil(MeetingPrompts.extractTitle(fromSummary: ""))
    }

    func testQuestionRequestIncludesHistoryAfterCachedTranscript() {
        var meeting = Meeting(segments: [TranscriptSegment(speaker: .others, start: 0, end: 1, text: "Budget is 10k")])
        meeting.summary = "# Budget\n\n## Summary\nTalked budget."
        meeting.questions = [QAExchange(question: "What budget?", answer: "10k")]
        let request = MeetingPrompts.questionRequest(for: meeting, question: "Who owns it?", myName: nil, model: .sonnet, effort: .low)
        let blocks = request.messages[0].content
        XCTAssertNotNil(blocks[0].cache_control)
        XCTAssertTrue(blocks[0].text.contains("Budget is 10k"))
        XCTAssertTrue(blocks.contains { $0.text.contains("Q: What budget?") })
        XCTAssertEqual(blocks.last?.text, "Question: Who owns it?")
        XCTAssertEqual(request.model, "claude-sonnet-5-5")
        XCTAssertEqual(request.output_config?.effort, "low")
    }

    func testMarkdownExportPutsMetadataUnderClaudeTitle() {
        var meeting = Meeting(platform: .zoom, startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 90))
        meeting.segments = [TranscriptSegment(speaker: .me, start: 0, end: 1, text: "Hi")]
        meeting.summary = "# Kickoff\n\n## Summary\nWe kicked off."
        let md = MarkdownExporter.markdown(for: meeting)
        let lines = md.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "# Kickoff")
        XCTAssertTrue(lines[2].contains("Zoom"))
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("**[00:00] Me:** Hi"))
    }

    func testMarkdownExportWithoutSummary() {
        let meeting = Meeting(title: "Standup", segments: [TranscriptSegment(speaker: .others, start: 0, end: 1, text: "Yo")])
        let md = MarkdownExporter.markdown(for: meeting)
        XCTAssertTrue(md.hasPrefix("# Standup\n"))
    }

    func testFileName() {
        XCTAssertEqual(MarkdownExporter.fileName(for: Meeting(title: "A/B: test?")), "A-B- test-.md")
    }
}

final class MeetingStoreTests: XCTestCase {
    func testRoundTripAndOrdering() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir)

        let older = Meeting(title: "Older", startedAt: Date(timeIntervalSince1970: 1_000))
        var newer = Meeting(title: "Newer", platform: .googleMeet, startedAt: Date(timeIntervalSince1970: 2_000))
        newer.segments = [TranscriptSegment(speaker: .me, start: 0, end: 1, text: "Hi")]
        newer.questions = [QAExchange(question: "q", answer: "a", askedAt: Date(timeIntervalSince1970: 2_100))] // ISO 8601 storage has 1s precision
        try store.save(older)
        try store.save(newer)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("junk.json"))

        let all = store.loadAll()
        XCTAssertEqual(all.map(\.title), ["Newer", "Older"])
        XCTAssertEqual(all.first, newer)

        try store.delete(id: newer.id)
        XCTAssertEqual(store.loadAll().map(\.title), ["Older"])
    }
}
