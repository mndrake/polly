import Foundation

/// Who said something. Polly records the microphone and the meeting app's
/// audio as separate channels, which gives a reliable two-way split.
public enum Speaker: String, Codable, Sendable, CaseIterable {
    /// The local user (microphone channel).
    case me
    /// Everyone else on the call (meeting app / system audio channel).
    case others
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var speaker: Speaker
    /// Seconds from the start of the recording.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// For `.others` segments after voice separation: which remote voice
    /// ("S1", "S2", …). `nil` when the channel wasn't separated.
    public var speakerID: String?

    public init(id: UUID = UUID(), speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String, speakerID: String? = nil) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.speakerID = speakerID
    }
}

/// A follow-up question asked about a meeting, and Claude's answer.
public struct QAExchange: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var question: String
    public var answer: String
    public var askedAt: Date

    public init(id: UUID = UUID(), question: String, answer: String, askedAt: Date = Date()) {
        self.id = id
        self.question = question
        self.answer = answer
        self.askedAt = askedAt
    }
}

public struct Meeting: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    /// True until the user renames the meeting or Claude proposes a title.
    public var hasDefaultTitle: Bool
    public var platform: MeetingPlatform
    public var startedAt: Date
    public var endedAt: Date?
    public var segments: [TranscriptSegment]
    public var summary: String?
    public var summaryModel: String?
    public var summarizedAt: Date?
    public var questions: [QAExchange]
    /// Names the user assigned to separated voices, keyed by speaker ID ("S1").
    public var speakerNames: [String: String]
    /// Names Claude inferred from the conversation, used until the user confirms or changes them.
    public var suggestedSpeakerNames: [String: String]
    /// Invitees of the matching calendar event, if any.
    public var attendees: [String]

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        platform: MeetingPlatform = .other,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        segments: [TranscriptSegment] = [],
        summary: String? = nil,
        summaryModel: String? = nil,
        summarizedAt: Date? = nil,
        questions: [QAExchange] = [],
        speakerNames: [String: String] = [:],
        suggestedSpeakerNames: [String: String] = [:],
        attendees: [String] = []
    ) {
        self.id = id
        self.title = title ?? Meeting.defaultTitle(platform: platform, startedAt: startedAt)
        self.hasDefaultTitle = title == nil
        self.platform = platform
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
        self.summary = summary
        self.summaryModel = summaryModel
        self.summarizedAt = summarizedAt
        self.questions = questions
        self.speakerNames = speakerNames
        self.suggestedSpeakerNames = suggestedSpeakerNames
        self.attendees = attendees
    }

    // Meetings saved by earlier versions lack the newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        hasDefaultTitle = try c.decodeIfPresent(Bool.self, forKey: .hasDefaultTitle) ?? false
        platform = try c.decodeIfPresent(MeetingPlatform.self, forKey: .platform) ?? .other
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryModel = try c.decodeIfPresent(String.self, forKey: .summaryModel)
        summarizedAt = try c.decodeIfPresent(Date.self, forKey: .summarizedAt)
        questions = try c.decodeIfPresent([QAExchange].self, forKey: .questions) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        suggestedSpeakerNames = try c.decodeIfPresent([String: String].self, forKey: .suggestedSpeakerNames) ?? [:]
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
    }

    /// Separated remote voices in order of first appearance.
    public var speakerIDs: [String] {
        var seen: [String] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if let id = segment.speakerID, !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    /// The display name for a separated voice: the user's choice, then
    /// Claude's suggestion, then "Speaker N".
    public func displayName(forSpeakerID id: String) -> String {
        speakerNames[id] ?? suggestedSpeakerNames[id] ?? SpeakerLabels.defaultLabel(for: id)
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public var isEmpty: Bool {
        segments.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func defaultTitle(platform: MeetingPlatform, startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let when = formatter.string(from: startedAt)
        return platform == .other ? "Meeting – \(when)" : "\(platform.displayName) – \(when)"
    }
}
