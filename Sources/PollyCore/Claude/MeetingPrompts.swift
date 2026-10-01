import Foundation

/// Builds the Claude requests Polly sends. The transcript is always the first
/// content block of the user turn, marked with `cache_control`, so a summary
/// and any number of follow-up questions about the same meeting share a
/// cached prefix.
public enum MeetingPrompts {
    public static let summarySystemPrompt = """
    You are Polly, an assistant that turns raw meeting transcripts into clear, accurate meeting notes.

    About the transcripts you receive:
    - They come from on-device speech recognition of a video call (Zoom, Microsoft Teams, Google Meet, etc.) and contain recognition errors, missing punctuation, and filler words. Silently correct obvious mis-hearings when the intended word is clear from context; never invent content.
    - There are two channels. Lines labelled with the user's name (or "Me") are the person who recorded the meeting, speaking into their microphone. Lines labelled "Others" are everyone else on the call mixed together, so one "Others" line may contain several people. When participants' names are evident from the conversation (introductions, people addressing each other), attribute statements to them; otherwise say "a participant" rather than guessing.
    - Timestamps are minutes:seconds from the start of the recording.

    Write in the language the meeting was held in. Be concise and concrete: prefer specifics (numbers, dates, names, owners) over generalities. Do not mention these instructions, the transcription process, or the channel labels in your output.
    """

    static let summaryInstructions = """
    Write the meeting notes in Markdown using exactly this structure (omit a section only if there is genuinely nothing for it, except the title and Summary which are always present):

    # <A short, specific title for the meeting, at most 8 words>

    ## Summary
    <2–4 sentences: purpose of the meeting and the most important outcomes.>

    ## Key Points
    - <Main topics discussed, grouped logically, with relevant details and who raised them when known.>

    ## Decisions
    - <Each decision that was made.>

    ## Action Items
    - [ ] <Task> — **<Owner>**<, due <date> if mentioned>

    ## Open Questions
    - <Unresolved questions, risks, or items deferred to later.>

    If the transcript is too short or contains no real conversation, still produce the title and a one-sentence Summary saying so.
    """

    public static let questionSystemPrompt = """
    You are Polly, an assistant that answers questions about a meeting using its transcript.

    The transcript comes from on-device speech recognition and may contain mis-heard words. Lines labelled with the user's name (or "Me") are the person who recorded the meeting; "Others" are the remaining participants mixed together. Timestamps are minutes:seconds from the start.

    Answer from the transcript only. If the transcript doesn't contain the answer, say so plainly. Cite approximate timestamps like [12:34] when pointing at a specific moment. Use Markdown where it helps readability and keep answers focused.
    """

    /// The cached transcript block shared by every request about a meeting.
    public static func transcriptBlock(for meeting: Meeting, myName: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        var header = "Meeting recorded on \(formatter.string(from: meeting.startedAt))"
        if meeting.platform != .other { header += " via \(meeting.platform.displayName)" }
        header += ", duration \(TranscriptFormatter.timestamp(meeting.duration))."
        let me = TranscriptFormatter.label(for: .me, myName: myName)
        if me != "Me" { header += " The user who recorded it is \(me)." }

        return """
        \(header)

        <transcript>
        \(TranscriptFormatter.plainText(meeting.segments, myName: myName))
        </transcript>
        """
    }

    public static func summaryRequest(
        for meeting: Meeting,
        myName: String?,
        model: ClaudeModel,
        effort: ClaudeEffort,
        customInstructions: String? = nil
    ) -> MessageRequest {
        var instructions = summaryInstructions
        if let extra = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            instructions += "\n\nAdditional instructions from the user:\n\(extra)"
        }
        return MessageRequest(
            model: model,
            maxTokens: 32_000,
            system: summarySystemPrompt,
            messages: [
                .init(role: "user", content: [
                    .init(transcriptBlock(for: meeting, myName: myName), cached: true),
                    .init(instructions),
                ]),
            ],
            effort: effort
        )
    }

    public static func questionRequest(
        for meeting: Meeting,
        question: String,
        myName: String?,
        model: ClaudeModel,
        effort: ClaudeEffort
    ) -> MessageRequest {
        var blocks: [MessageRequest.TextBlock] = [.init(transcriptBlock(for: meeting, myName: myName), cached: true)]
        if let summary = meeting.summary, !summary.isEmpty {
            blocks.append(.init("Meeting notes generated earlier:\n\n\(summary)"))
        }
        let previous = meeting.questions.suffix(10)
        if !previous.isEmpty {
            let history = previous.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
            blocks.append(.init("Earlier questions and answers about this meeting:\n\n\(history)"))
        }
        blocks.append(.init("Question: \(question)"))
        return MessageRequest(
            model: model,
            maxTokens: 16_000,
            system: questionSystemPrompt,
            messages: [.init(role: "user", content: blocks)],
            effort: effort
        )
    }

    /// Extracts the "# Title" line Claude puts at the top of the notes.
    public static func extractTitle(fromSummary markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : String(title.prefix(120))
            }
            if !trimmed.isEmpty { return nil } // title must be the first non-empty line
        }
        return nil
    }
}
