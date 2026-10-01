import Foundation

/// A result coming out of a speech engine for one audio channel.
public struct TranscriptionUpdate: Sendable, Equatable {
    public var speaker: Speaker
    public var text: String
    /// Final results are committed; volatile ones replace the speaker's live line.
    public var isFinal: Bool
    /// Seconds from the start of the recording.
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: Speaker, text: String, isFinal: Bool, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
    }
}

/// Assembles a live, ordered transcript from two independent channels.
///
/// * Final results become `segments`, kept sorted by start time.
/// * The latest volatile result per speaker is exposed in `liveText`.
/// * Optional echo suppression drops "Me" segments that are just the
///   microphone picking up the remote participants through the speakers.
public struct TranscriptBuilder: Sendable {
    public private(set) var segments: [TranscriptSegment]
    public private(set) var liveText: [Speaker: String] = [:]
    public var echoSuppression: Bool
    /// Number of "Me" segments dropped as echo (for diagnostics/UI).
    public private(set) var suppressedEchoCount = 0
    /// "Me" finals waiting for the matching "Others" final to arrive before being judged.
    private var pendingMine: [TranscriptSegment] = []

    /// How far apart (seconds) two segments may be and still count as echo of each other.
    static let echoWindow: TimeInterval = 4
    /// Minimum token overlap to treat a "Me" segment as echo.
    static let echoSimilarity = 0.6
    /// How long to hold a "Me" segment while waiting for the remote side to catch up.
    static let echoHold: TimeInterval = 6

    public init(segments: [TranscriptSegment] = [], echoSuppression: Bool = true) {
        self.segments = segments.sorted { $0.start < $1.start }
        self.echoSuppression = echoSuppression
    }

    public mutating func apply(_ update: TranscriptionUpdate) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard update.isFinal else {
            liveText[update.speaker] = text.isEmpty ? nil : text
            return
        }
        liveText[update.speaker] = nil
        guard !text.isEmpty else { return }

        let segment = TranscriptSegment(speaker: update.speaker, start: update.start, end: max(update.end, update.start), text: text)

        if echoSuppression && segment.speaker == .me {
            pendingMine.append(segment)
        } else {
            insert(segment)
        }
        if echoSuppression { resolvePending(now: update.end) }
    }

    /// Commits anything still pending (call when the recording stops).
    public mutating func flush() {
        resolvePending(now: .infinity)
        for (speaker, text) in liveText where !text.isEmpty {
            let lastEnd = segments.last?.end ?? 0
            insert(TranscriptSegment(speaker: speaker, start: lastEnd, end: lastEnd, text: text))
        }
        liveText = [:]
    }

    /// All committed segments plus pending ones (for display while recording).
    public var displaySegments: [TranscriptSegment] {
        guard !pendingMine.isEmpty else { return segments }
        return (segments + pendingMine).sorted { $0.start < $1.start }
    }

    private mutating func resolvePending(now: TimeInterval) {
        var stillPending: [TranscriptSegment] = []
        for mine in pendingMine {
            if isEcho(mine) {
                suppressedEchoCount += 1
            } else if now - mine.end < Self.echoHold {
                stillPending.append(mine)
            } else {
                insert(mine)
            }
        }
        pendingMine = stillPending
    }

    private func isEcho(_ mine: TranscriptSegment) -> Bool {
        let mineTokens = Self.tokens(mine.text)
        guard mineTokens.count >= 3 else { return false }
        for other in segments where other.speaker == .others {
            guard other.end >= mine.start - Self.echoWindow, other.start <= mine.end + Self.echoWindow else { continue }
            let otherTokens = Self.tokens(other.text)
            let overlap = Double(mineTokens.intersection(otherTokens).count) / Double(mineTokens.count)
            if overlap >= Self.echoSimilarity { return true }
        }
        return false
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    private mutating func insert(_ segment: TranscriptSegment) {
        let index = segments.lastIndex { $0.start <= segment.start }.map { $0 + 1 } ?? 0
        segments.insert(segment, at: index)
    }
}
