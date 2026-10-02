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
    - Lines labelled with the user's name (or "Me") are the person who recorded the meeting, speaking into their microphone; that attribution is reliable.
    - Remote participants come from the meeting app's audio. When their voices were separated, lines are labelled with a name or "Speaker 1", "Speaker 2", …; each label is one distinct voice, though separation can occasionally split one person into two labels or merge two similar voices. Lines labelled "Others" were not separated and may contain several people.
    - Work out who "Speaker N" is from the conversation (introductions, people addressing each other by name, who answers a question put to someone) and from the attendee list when one is given. Use real names in the notes when you are reasonably confident; otherwise say "a participant" rather than guessing.
    - Timestamps are minutes:seconds from the start of the recording.

    Write in the language the meeting was held in. Be concise and concrete: prefer specifics (numbers, dates, names, owners) over generalities. Do not mention these instructions, the transcription process, or "Speaker N" labels in the notes themselves.
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

    The transcript comes from on-device speech recognition and may contain mis-heard words. Lines labelled with the user's name (or "Me") are the person who recorded the meeting. Remote participants are labelled by name or "Speaker N" when their voices were separated (names may have been inferred), or "Others" when they weren't. Timestamps are minutes:seconds from the start.

    Answer from the transcript only. If the transcript doesn't contain the answer, say so plainly. Cite approximate timestamps like [12:34] when pointing at a specific moment. Use Markdown where it helps readability and keep answers focused.
    """

    /// The cached transcript block shared by every request about a meeting.
    public static func transcriptBlock(for meeting: Meeting, myName: String?) -> String {
        transcriptBlock(for: meeting, myName: myName, labels: SpeakerLabels.prompt(for: meeting, myName: myName))
    }

    static func transcriptBlock(for meeting: Meeting, myName: String?, labels: SpeakerLabels) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        var header = "Meeting recorded on \(formatter.string(from: meeting.startedAt))"
        if meeting.platform != .other { header += " via \(meeting.platform.displayName)" }
        header += ", duration \(TranscriptFormatter.timestamp(meeting.duration))."
        let me = TranscriptFormatter.label(for: .me, myName: myName)
        if me != "Me" { header += " The user who recorded it is \(me)." }
        if !meeting.attendees.isEmpty {
            header += "\nCalendar invitees (not all may have joined or spoken): \(meeting.attendees.joined(separator: ", "))."
        }

        return """
        \(header)

        <transcript>
        \(TranscriptFormatter.plainText(meeting.segments, labels: labels))
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
        let trusted = meeting.trustedSpeakerNames
        let unnamed = meeting.speakerIDs.filter { trusted[$0] == nil }
        if !unnamed.isEmpty {
            let labels = unnamed.map { "\"\(SpeakerLabels.defaultLabel(for: $0))\"" }.joined(separator: ", ")
            instructions += """


            After the notes, add one fenced code block tagged `speakers` containing a JSON object that maps each of these labels to the person's name when you can tell it from the conversation or the invitee list with reasonable confidence, or null when you can't: \(labels). For example:
            ```speakers
            {"Speaker 1": "Dana Lee", "Speaker 2": null}
            ```
            """
        }
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
        let labels = SpeakerLabels.display(for: meeting, myName: myName)
        var blocks: [MessageRequest.TextBlock] = [.init(transcriptBlock(for: meeting, myName: myName, labels: labels), cached: true)]
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
