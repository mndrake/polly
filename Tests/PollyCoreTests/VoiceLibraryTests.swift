import XCTest
@testable import PollyCore

/// Deterministic pseudo-random voices: each "person" is a base direction in
/// 256-d space; each meeting adds noise, like real embeddings drifting with
/// microphones and codecs.
private struct VoiceFactory {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
    }

    mutating func person() -> [Float] {
        VectorMath.normalized((0..<256).map { _ in next() })
    }

    mutating func heard(_ person: [Float], noise: Float = 0.35, seconds: Double = 60) -> SpeakerVoice {
        let noisy = person.map { $0 + noise * next() / 8 }
        return SpeakerVoice(embedding: noisy, seconds: seconds)
    }
}

final class VoiceLibraryTests: XCTestCase {
    func testRecognizesPeopleAcrossMeetings() {
        var factory = VoiceFactory(seed: 42)
        let dana = factory.person(), raj = factory.person(), stranger = factory.person()
        var library = VoiceLibrary()

        let firstMeeting = UUID()
        XCTAssertTrue(library.learn(name: "Dana Lee", meetingID: firstMeeting, speakerID: "S1", voice: factory.heard(dana)))
        XCTAssertTrue(library.learn(name: "Raj Patel", meetingID: firstMeeting, speakerID: "S2", voice: factory.heard(raj)))

        // Next week: different speaker numbers, plus someone new.
        let matches = library.match([
            "S1": factory.heard(raj),
            "S2": factory.heard(stranger),
            "S3": factory.heard(dana),
        ])
        XCTAssertEqual(matches["S1"]?.name, "Raj Patel")
        XCTAssertEqual(matches["S3"]?.name, "Dana Lee")
        XCTAssertNil(matches["S2"], "unknown voices stay unnamed")
        XCTAssertGreaterThan(matches["S1"]?.similarity ?? 0, VoiceLibrary.matchThreshold)
    }

    func testOnePersonMatchesOnlyOneVoice() {
        var factory = VoiceFactory(seed: 7)
        let dana = factory.person()
        var library = VoiceLibrary()
        library.learn(name: "Dana", meetingID: UUID(), speakerID: "S1", voice: factory.heard(dana))

        // The diarizer split Dana into two voices; only the closer one gets her name.
        let matches = library.match(["S1": factory.heard(dana, noise: 0.2), "S2": factory.heard(dana, noise: 0.8)])
        XCTAssertEqual(matches.count, 1)
    }

    func testAmbiguousMatchIsRejected() {
        var factory = VoiceFactory(seed: 9)
        let twin = factory.person()
        var library = VoiceLibrary()
        library.learn(name: "Twin A", meetingID: UUID(), speakerID: "S1", voice: SpeakerVoice(embedding: twin, seconds: 60))
        library.learn(name: "Twin B", meetingID: UUID(), speakerID: "S1", voice: factory.heard(twin, noise: 0.05))
        XCTAssertTrue(library.match(["S1": factory.heard(twin, noise: 0.1)]).isEmpty, "too close to call between two people")
    }

    func testShortVoicesAreNotLearnedOrMatched() {
        var factory = VoiceFactory(seed: 3)
        let dana = factory.person()
        var library = VoiceLibrary()
        XCTAssertFalse(library.learn(name: "Dana", meetingID: UUID(), speakerID: "S1", voice: factory.heard(dana, seconds: 2)))
        XCTAssertTrue(library.profiles.isEmpty)

        library.learn(name: "Dana", meetingID: UUID(), speakerID: "S1", voice: factory.heard(dana))
        XCTAssertTrue(library.match(["S1": factory.heard(dana, seconds: 3)]).isEmpty)
    }

    func testRenamingASpeakerMovesTheSample() {
        var factory = VoiceFactory(seed: 11)
        let voice = factory.heard(factory.person())
        let meeting = UUID()
        var library = VoiceLibrary()

        library.learn(name: "Dana", meetingID: meeting, speakerID: "S2", voice: voice)
        library.learn(name: "Priya", meetingID: meeting, speakerID: "S2", voice: voice) // user corrected it
        XCTAssertEqual(library.profiles.map(\.name), ["Priya"], "the wrong person is dropped once empty")

        library.forget(meetingID: meeting, speakerID: "S2")
        XCTAssertTrue(library.profiles.isEmpty)
    }

    func testSameNameAccumulatesAndIsCapped() {
        var factory = VoiceFactory(seed: 5)
        let dana = factory.person()
        var library = VoiceLibrary()
        for day in 0..<25 {
            library.learn(name: day.isMultiple(of: 2) ? "Dana" : "dana", meetingID: UUID(), speakerID: "S1",
                          voice: factory.heard(dana), at: Date(timeIntervalSince1970: Double(day) * 86_400))
        }
        XCTAssertEqual(library.profiles.count, 1, "names match case-insensitively")
        XCTAssertEqual(library.profiles[0].samples.count, VoiceLibrary.maxSamplesPerProfile)
        XCTAssertEqual(library.profiles[0].lastHeard, Date(timeIntervalSince1970: 24 * 86_400), "oldest samples are dropped")
    }

    func testRenameMergesAndRemove() {
        var factory = VoiceFactory(seed: 13)
        var library = VoiceLibrary()
        library.learn(name: "Dan", meetingID: UUID(), speakerID: "S1", voice: factory.heard(factory.person()))
        library.learn(name: "Dana Lee", meetingID: UUID(), speakerID: "S1", voice: factory.heard(factory.person()))
        let dan = library.profiles.first { $0.name == "Dan" }!.id
        library.rename(profileID: dan, to: "dana lee")
        XCTAssertEqual(library.profiles.count, 1)
        XCTAssertEqual(library.profiles[0].samples.count, 2)
        library.remove(profileID: library.profiles[0].id)
        XCTAssertTrue(library.profiles.isEmpty)
    }

    func testForgetMeeting() {
        var factory = VoiceFactory(seed: 17)
        let meeting = UUID()
        var library = VoiceLibrary()
        library.learn(name: "A", meetingID: meeting, speakerID: "S1", voice: factory.heard(factory.person()))
        library.learn(name: "B", meetingID: meeting, speakerID: "S2", voice: factory.heard(factory.person()))
        library.learn(name: "B", meetingID: UUID(), speakerID: "S1", voice: factory.heard(factory.person()))
        library.forget(meetingID: meeting)
        XCTAssertEqual(library.profiles.map(\.name), ["B"])
        XCTAssertEqual(library.profiles[0].samples.count, 1)
    }

    func testStoreRoundTrip() throws {
        var factory = VoiceFactory(seed: 21)
        var library = VoiceLibrary()
        library.learn(name: "Dana", meetingID: UUID(), speakerID: "S1", voice: factory.heard(factory.person()),
                      at: Date(timeIntervalSince1970: 1_000))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoiceLibraryStore(url: url)
        try store.save(library)
        XCTAssertEqual(store.load(), library)
        store.delete()
        XCTAssertEqual(store.load(), VoiceLibrary())
    }
}

final class VoiceAssignmentTests: XCTestCase {
    func testAssignmentReportsMappingSecondsAndVoices() {
        let segments = [
            TranscriptSegment(speaker: .others, start: 0, end: 4, text: "first"),
            TranscriptSegment(speaker: .others, start: 5, end: 9, text: "second"),
        ]
        let turns = [
            DiarizedTurn(speakerID: "spk_b", start: 0, end: 4),
            DiarizedTurn(speakerID: "spk_a", start: 5, end: 9),
            DiarizedTurn(speakerID: "spk_b", start: 10, end: 16),
        ]
        let result = SpeakerAssignment.assignment(turns, to: segments)
        XCTAssertEqual(result.speakerIDs, ["spk_b": "S1", "spk_a": "S2"])
        XCTAssertEqual(result.seconds["S1"], 10)
        XCTAssertEqual(result.seconds["S2"], 4)

        let voices = result.voices(from: ["spk_a": [3, 4], "spk_b": [1, 0], "unused": [1, 1]])
        XCTAssertEqual(voices["S2"]?.embedding, [0.6, 0.8], "embeddings are normalized")
        XCTAssertEqual(voices["S1"]?.seconds, 10)
        XCTAssertEqual(voices.count, 2)
    }

    func testRecognizedNamesRankBetweenUserAndClaude() {
        var meeting = Meeting(segments: [
            TranscriptSegment(speaker: .others, start: 0, end: 1, text: "a", speakerID: "S1"),
            TranscriptSegment(speaker: .others, start: 2, end: 3, text: "b", speakerID: "S2"),
            TranscriptSegment(speaker: .others, start: 4, end: 5, text: "c", speakerID: "S3"),
        ])
        meeting.suggestedSpeakerNames = ["S1": "Claude guess", "S2": "Claude guess 2", "S3": "Claude guess 3"]
        meeting.recognizedSpeakers = ["S1": VoiceMatch(profileID: UUID(), name: "Dana", similarity: 0.8),
                                      "S2": VoiceMatch(profileID: UUID(), name: "Raj", similarity: 0.7)]
        meeting.speakerNames = ["S2": "Raj Patel"]
        XCTAssertEqual(meeting.displayName(forSpeakerID: "S1"), "Dana")
        XCTAssertEqual(meeting.displayName(forSpeakerID: "S2"), "Raj Patel")
        XCTAssertEqual(meeting.displayName(forSpeakerID: "S3"), "Claude guess 3")

        let request = MeetingPrompts.summaryRequest(for: meeting, myName: nil, model: .opus, effort: .medium)
        let transcript = request.messages[0].content[0].text
        XCTAssertTrue(transcript.contains("Dana: a"), "voice matches are given to Claude as names")
        XCTAssertTrue(transcript.contains("Speaker 3: c"))
        XCTAssertTrue(request.messages[0].content[1].text.contains("or null when you can't: \"Speaker 3\". For example"))
    }
}
