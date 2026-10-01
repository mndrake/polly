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

    public init(id: UUID = UUID(), speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
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
        questions: [QAExchange] = []
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
