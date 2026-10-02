import Foundation

/// A stretch of audio attributed to one voice by a diarization model.
public struct DiarizedTurn: Sendable, Equatable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// Builds the label shown for each transcript line.
public struct SpeakerLabels: Sendable {
    public var myName: String?
    /// Names for separated voices, keyed by speaker ID.
    public var names: [String: String]

    public init(myName: String?, names: [String: String] = [:]) {
        self.myName = myName
        self.names = names
    }

    /// Labels for display: the user's names, then Claude's suggestions.
    public static func display(for meeting: Meeting, myName: String?) -> SpeakerLabels {
        SpeakerLabels(myName: myName, names: meeting.suggestedSpeakerNames.merging(meeting.trustedSpeakerNames) { _, trusted in trusted })
    }

    /// Labels for prompts: names the user gave and voice matches, so Claude
    /// re-infers the rest instead of being anchored on its own earlier guesses.
    public static func prompt(for meeting: Meeting, myName: String?) -> SpeakerLabels {
        SpeakerLabels(myName: myName, names: meeting.trustedSpeakerNames)
    }

    public func label(for segment: TranscriptSegment) -> String {
        if segment.speaker == .others, let id = segment.speakerID {
            if let name = names[id]?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
            return Self.defaultLabel(for: id)
        }
        return TranscriptFormatter.label(for: segment.speaker, myName: myName)
    }

    /// "S3" → "Speaker 3".
    public static func defaultLabel(for speakerID: String) -> String {
        let number = speakerID.hasPrefix("S") ? String(speakerID.dropFirst()) : speakerID
        return "Speaker \(number)"
    }

    /// "Speaker 3" → "S3"; nil if the text isn't a default label.
    public static func speakerID(fromDefaultLabel label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Speaker "), let number = Int(trimmed.dropFirst("Speaker ".count)) else { return nil }
        return "S\(number)"
    }
}

public enum SpeakerAssignment {
    /// Gives each remote ("others") transcript segment the voice that
    /// overlaps it most. Diarizer IDs are renumbered S1, S2, … in order of
    /// first appearance so labels read naturally. Segments with no voice
    /// within `maxDistance` seconds are left unassigned.
    public static func assign(
        _ turns: [DiarizedTurn],
        to segments: [TranscriptSegment],
        maxDistance: TimeInterval = 1.5
    ) -> [TranscriptSegment] {
        assignment(turns, to: segments, maxDistance: maxDistance).segments
    }

    public struct Result: Sendable, Equatable {
        public var segments: [TranscriptSegment]
        /// Diarizer label → "S<n>".
        public var speakerIDs: [String: String]
        /// "S<n>" → seconds of speech attributed to that voice by the diarizer.
        public var seconds: [String: Double]

        /// Per-voice fingerprints from diarizer embeddings keyed by diarizer label.
        public func voices(from embeddings: [String: [Float]]) -> [String: SpeakerVoice] {
            var voices: [String: SpeakerVoice] = [:]
            for (raw, id) in speakerIDs {
                guard let embedding = embeddings[raw], !embedding.isEmpty else { continue }
                voices[id] = SpeakerVoice(embedding: embedding, seconds: seconds[id] ?? 0)
            }
            return voices
        }
    }

    public static func assignment(
        _ turns: [DiarizedTurn],
        to segments: [TranscriptSegment],
        maxDistance: TimeInterval = 1.5
    ) -> Result {
        let sortedTurns = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sortedTurns.isEmpty else { return Result(segments: segments, speakerIDs: [:], seconds: [:]) }

        // Raw diarizer label → "S<n>" by first appearance among turns that
        // actually cover transcribed speech (ignore voices that never spoke text).
        var bestRaw: [UUID: String] = [:]
        for segment in segments where segment.speaker == .others {
            if let raw = bestVoice(for: segment, in: sortedTurns, maxDistance: maxDistance) {
                bestRaw[segment.id] = raw
            }
        }
        var renumber: [String: String] = [:]
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if let raw = bestRaw[segment.id], renumber[raw] == nil {
                renumber[raw] = "S\(renumber.count + 1)"
            }
        }

        let assigned = segments.map { segment -> TranscriptSegment in
            guard segment.speaker == .others else { return segment }
            var copy = segment
            copy.speakerID = bestRaw[segment.id].flatMap { renumber[$0] }
            return copy
        }
        var seconds: [String: Double] = [:]
        for turn in sortedTurns {
            if let id = renumber[turn.speakerID] { seconds[id, default: 0] += turn.end - turn.start }
        }
        return Result(segments: assigned, speakerIDs: renumber, seconds: seconds)
    }

    static func bestVoice(for segment: TranscriptSegment, in turns: [DiarizedTurn], maxDistance: TimeInterval) -> String? {
        var overlapBySpeaker: [String: TimeInterval] = [:]
        var nearest: (id: String, distance: TimeInterval)?
        for turn in turns {
            let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
            if overlap > 0 {
                overlapBySpeaker[turn.speakerID, default: 0] += overlap
            } else {
                let distance = max(turn.start - segment.end, segment.start - turn.end)
                if distance <= maxDistance, distance < (nearest?.distance ?? .infinity) {
                    nearest = (turn.speakerID, distance)
                }
            }
        }
        if let best = overlapBySpeaker.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            return best.key
        }
        return nearest?.id
    }
}

/// Claude appends a ```speakers JSON block mapping "Speaker N" labels to
/// names it could infer. This extracts it and removes it from the notes.
public enum SpeakerNameParser {
    static let fence = "```speakers"

    public struct Result: Equatable, Sendable {
        /// The notes without the speakers block.
        public var summary: String
        /// Speaker ID ("S1") → name, only for speakers Claude named.
        public var names: [String: String]
    }

    public static func extract(from text: String) -> Result {
        guard let start = text.range(of: fence) else {
            return Result(summary: text.trimmingCharacters(in: .whitespacesAndNewlines), names: [:])
        }
        let afterFence = text[start.upperBound...]
        let end = afterFence.range(of: "```")
        let json = end.map { String(afterFence[..<$0.lowerBound]) } ?? String(afterFence)
        var tail = end.map { String(afterFence[$0.upperBound...]) } ?? ""
        tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)

        var summary = String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { summary += "\n\n" + tail }

        var names: [String: String] = [:]
        if let data = json.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (label, value) in object {
                guard let id = SpeakerLabels.speakerID(fromDefaultLabel: label) ?? (label.hasPrefix("S") && Int(label.dropFirst()) != nil ? label : nil),
                      let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, SpeakerLabels.speakerID(fromDefaultLabel: name) == nil
                else { continue }
                names[id] = name
            }
        }
        return Result(summary: summary, names: names)
    }

    /// Hides a (possibly incomplete) speakers block while the notes stream in.
    public static func stripForDisplay(_ text: String) -> String {
        guard let start = text.range(of: fence) else {
            // Also hide a fence that is still being typed ("```spea").
            if let partial = text.range(of: "```", options: .backwards),
               fence.hasPrefix(String(text[partial.lowerBound...])) {
                return String(text[..<partial.lowerBound])
            }
            return text
        }
        return extract(from: text).summary
    }
}
