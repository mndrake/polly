import Foundation

public enum MarkdownExporter {
    public static func markdown(for meeting: Meeting, myName: String? = nil, includeTranscript: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        var lines: [String] = []
        let summary = meeting.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summaryHasTitle = MeetingPrompts.extractTitle(fromSummary: summary) != nil
        if !summaryHasTitle { lines.append("# \(meeting.title)") }

        var meta = "_\(formatter.string(from: meeting.startedAt)) · \(TranscriptFormatter.timestamp(meeting.duration))"
        if meeting.platform != .other { meta += " · \(meeting.platform.displayName)" }
        meta += "_"

        if summary.isEmpty {
            lines += ["", meta]
        } else if summaryHasTitle {
            // Insert the metadata line right after Claude's title.
            var summaryLines = summary.components(separatedBy: "\n")
            if let titleIndex = summaryLines.firstIndex(where: { $0.hasPrefix("# ") }) {
                summaryLines.insert(contentsOf: ["", meta], at: titleIndex + 1)
            }
            lines.append(summaryLines.joined(separator: "\n"))
        } else {
            lines += ["", meta, "", summary]
        }

        if !meeting.questions.isEmpty {
            lines += ["", "## Q&A"]
            for qa in meeting.questions {
                lines += ["", "**Q: \(qa.question)**", "", qa.answer]
            }
        }

        if includeTranscript {
            lines += ["", "## Transcript", ""]
            let labels = SpeakerLabels.display(for: meeting, myName: myName)
            for turn in TranscriptFormatter.turns(meeting.segments) {
                let who = labels.label(for: turn)
                lines.append("**[\(TranscriptFormatter.timestamp(turn.start))] \(who):** \(turn.text)  ")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A filesystem-safe file name for exporting.
    public static func fileName(for meeting: Meeting) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines)
        let base = meeting.title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "Meeting" : String(base.prefix(80))) + ".md"
    }
}
