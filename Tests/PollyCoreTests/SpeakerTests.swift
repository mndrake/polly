import XCTest
@testable import PollyCore

final class SpeakerAssignmentTests: XCTestCase {
    private func others(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: .others, start: start, end: end, text: text)
    }

    func testAssignsByLargestOverlapAndRenumbersByFirstAppearance() {
        let segments = [
            TranscriptSegment(speaker: .me, start: 0, end: 2, text: "Hi all"),
            others(3, 6, "Morning, Dana here"),
            others(7, 10, "Hey, it's Raj"),
            others(11, 14, "Dana again"),
        ]
        // Diarizer labels are arbitrary; "7" speaks first, so it becomes S1.
        let turns = [
            DiarizedTurn(speakerID: "7", start: 2.8, end: 6.2),
            DiarizedTurn(speakerID: "2", start: 6.9, end: 10.1),
            DiarizedTurn(speakerID: "2", start: 10.5, end: 11.4), // small overlap with segment 4
            DiarizedTurn(speakerID: "7", start: 11.2, end: 14.0),
        ]
        let result = SpeakerAssignment.assign(turns, to: segments)
        XCTAssertNil(result[0].speakerID, "the user's own lines are never reassigned")
        XCTAssertEqual(result.map(\.speakerID), [nil, "S1", "S2", "S1"])
    }

    func testNearestVoiceWithinToleranceWhenNoOverlap() {
        let segments = [others(10, 12, "short reply")]
        let result = SpeakerAssignment.assign([DiarizedTurn(speakerID: "a", start: 12.8, end: 15)], to: segments)
        XCTAssertEqual(result[0].speakerID, "S1")

        let far = SpeakerAssignment.assign([DiarizedTurn(speakerID: "a", start: 20, end: 25)], to: segments)
        XCTAssertNil(far[0].speakerID)
    }

    func testVoicesThatNeverMatchTextDoNotConsumeNumbers() {
        let segments = [others(10, 12, "only speech")]
        let turns = [
            DiarizedTurn(speakerID: "noise", start: 0, end: 2),
            DiarizedTurn(speakerID: "talker", start: 10, end: 12),
        ]
        XCTAssertEqual(SpeakerAssignment.assign(turns, to: segments)[0].speakerID, "S1")
    }

    func testNoTurnsLeavesSegmentsUntouched() {
        let segments = [others(0, 1, "x")]
        XCTAssertEqual(SpeakerAssignment.assign([], to: segments), segments)
    }
}

final class SpeakerLabelTests: XCTestCase {
    func testLabelsAndTurns() {
        let segments = [
            TranscriptSegment(speaker: .me, start: 0, end: 1, text: "Hi."),
            TranscriptSegment(speaker: .others, start: 1.5, end: 2, text: "Hello.", speakerID: "S1"),
            TranscriptSegment(speaker: .others, start: 2.2, end: 3, text: "Hey there.", speakerID: "S2"),
            TranscriptSegment(speaker: .others, start: 3.1, end: 4, text: "Same person.", speakerID: "S2"),
        ]
        let labels = SpeakerLabels(myName: "Ana", names: ["S1": "Dana"])
        XCTAssertEqual(TranscriptFormatter.plainText(segments, labels: labels), """
        [00:00] Ana: Hi.
        [00:01] Dana: Hello.
        [00:02] Speaker 2: Hey there. Same person.
        """)
    }

    func testDisplayPrefersUserNamesOverSuggestions() {
        var meeting = Meeting()
        meeting.suggestedSpeakerNames = ["S1": "Dana?", "S2": "Raj"]
        meeting.speakerNames = ["S1": "Dana Lee"]
        let labels = SpeakerLabels.display(for: meeting, myName: nil)
        XCTAssertEqual(labels.names, ["S1": "Dana Lee", "S2": "Raj"])
        XCTAssertEqual(SpeakerLabels.prompt(for: meeting, myName: nil).names, ["S1": "Dana Lee"])
        XCTAssertEqual(meeting.displayName(forSpeakerID: "S3"), "Speaker 3")
    }

    func testDefaultLabelRoundTrip() {
        XCTAssertEqual(SpeakerLabels.defaultLabel(for: "S4"), "Speaker 4")
        XCTAssertEqual(SpeakerLabels.speakerID(fromDefaultLabel: "Speaker 4"), "S4")
        XCTAssertNil(SpeakerLabels.speakerID(fromDefaultLabel: "Dana"))
    }

    func testSpeakerIDsInOrderOfAppearance() {
        let meeting = Meeting(segments: [
            TranscriptSegment(speaker: .others, start: 5, end: 6, text: "b", speakerID: "S2"),
            TranscriptSegment(speaker: .others, start: 1, end: 2, text: "a", speakerID: "S1"),
            TranscriptSegment(speaker: .me, start: 3, end: 4, text: "me"),
            TranscriptSegment(speaker: .others, start: 7, end: 8, text: "c", speakerID: "S1"),
        ])
        XCTAssertEqual(meeting.speakerIDs, ["S1", "S2"])
    }
}

final class SpeakerNameParserTests: XCTestCase {
    func testExtractsAndStripsBlock() {
        let text = """
        # Budget review

        ## Summary
        Dana presented.

        ```speakers
        {"Speaker 1": "Dana Lee", "Speaker 2": null, "Speaker 3": "Speaker 3", "Speaker 4": "  "}
        ```
        """
        let result = SpeakerNameParser.extract(from: text)
        XCTAssertEqual(result.names, ["S1": "Dana Lee"])
        XCTAssertEqual(result.summary, "# Budget review\n\n## Summary\nDana presented.")
    }

    func testNoBlock() {
        XCTAssertEqual(SpeakerNameParser.extract(from: "# T\n").summary, "# T")
        XCTAssertEqual(SpeakerNameParser.extract(from: "# T\n").names, [:])
    }

    func testMalformedJSONIsIgnored() {
        let result = SpeakerNameParser.extract(from: "# T\n```speakers\n{oops\n```")
        XCTAssertEqual(result.summary, "# T")
        XCTAssertEqual(result.names, [:])
    }

    func testStripForDisplayWhileStreaming() {
        XCTAssertEqual(SpeakerNameParser.stripForDisplay("# T\n\nBody\n```spe"), "# T\n\nBody\n")
        XCTAssertEqual(SpeakerNameParser.stripForDisplay("# T\n\nBody\n```speakers\n{\"Speaker 1\": \"Da"), "# T\n\nBody")
        XCTAssertEqual(SpeakerNameParser.stripForDisplay("Some `code` and ```swift"), "Some `code` and ```swift")
    }
}

final class SpeakerPromptTests: XCTestCase {
    private func meeting() -> Meeting {
        var meeting = Meeting(segments: [
            TranscriptSegment(speaker: .others, start: 0, end: 2, text: "I'm Dana", speakerID: "S1"),
            TranscriptSegment(speaker: .others, start: 3, end: 4, text: "Raj here", speakerID: "S2"),
        ])
        meeting.attendees = ["Dana Lee", "Raj Patel"]
        meeting.speakerNames = ["S2": "Raj Patel"]
        meeting.suggestedSpeakerNames = ["S1": "Dana Lee"]
        return meeting
    }

    func testSummaryAsksOnlyAboutUnconfirmedSpeakers() {
        let request = MeetingPrompts.summaryRequest(for: meeting(), myName: nil, model: .opus, effort: .medium)
        let transcript = request.messages[0].content[0].text
        let instructions = request.messages[0].content[1].text
        XCTAssertTrue(transcript.contains("Calendar invitees (not all may have joined or spoken): Dana Lee, Raj Patel."))
        XCTAssertTrue(transcript.contains("Speaker 1: I'm Dana"), "unconfirmed suggestions are not fed back to Claude")
        XCTAssertTrue(transcript.contains("Raj Patel: Raj here"))
        XCTAssertTrue(instructions.contains("```speakers"))
        XCTAssertTrue(instructions.contains("or null when you can't: \"Speaker 1\". For example"),
                      "only the unconfirmed voice is listed")
    }

    func testNoSpeakersBlockRequestedWithoutSeparation() {
        let plain = Meeting(segments: [TranscriptSegment(speaker: .others, start: 0, end: 1, text: "hi")])
        let request = MeetingPrompts.summaryRequest(for: plain, myName: nil, model: .opus, effort: .medium)
        XCTAssertFalse(request.messages[0].content[1].text.contains("```speakers"))
    }

    func testQuestionsUseSuggestedNames() {
        let request = MeetingPrompts.questionRequest(for: meeting(), question: "Who?", myName: nil, model: .opus, effort: .low)
        XCTAssertTrue(request.messages[0].content[0].text.contains("Dana Lee: I'm Dana"))
    }

    func testOldMeetingFilesStillDecode() throws {
        let legacy = """
        {"id":"7C9E0E7A-2B0B-4B7B-9C55-6C1E1B5C0A11","title":"Old","hasDefaultTitle":false,"platform":"zoom",
         "startedAt":"2026-09-01T10:00:00Z","segments":[{"id":"1C9E0E7A-2B0B-4B7B-9C55-6C1E1B5C0A11","speaker":"others","start":0,"end":1,"text":"hi"}],
         "questions":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(legacy.utf8))
        XCTAssertEqual(meeting.title, "Old")
        XCTAssertNil(meeting.segments[0].speakerID)
        XCTAssertEqual(meeting.speakerNames, [:])
        XCTAssertEqual(meeting.attendees, [])
    }
}
