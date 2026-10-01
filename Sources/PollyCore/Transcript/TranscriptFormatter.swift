import Foundation

public enum TranscriptFormatter {
    /// "00:04" / "1:02:03"
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    public static func label(for speaker: Speaker, myName: String?) -> String {
        switch speaker {
        case .me:
            if let name = myName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
            return "Me"
        case .others:
            return "Others"
        }
    }

    /// Consecutive segments from the same speaker separated by less than
    /// `maxGap` seconds are merged into one turn for readability.
    public static func turns(_ segments: [TranscriptSegment], maxGap: TimeInterval = 2.5) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, last.speaker == segment.speaker, segment.start - last.end <= maxGap {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }

    /// Plain-text transcript, one turn per line: "[00:12] Me: Hello there."
    public static func plainText(_ segments: [TranscriptSegment], myName: String? = nil) -> String {
        turns(segments)
            .map { "[\(timestamp($0.start))] \(label(for: $0.speaker, myName: myName)): \($0.text)" }
            .joined(separator: "\n")
    }
}
