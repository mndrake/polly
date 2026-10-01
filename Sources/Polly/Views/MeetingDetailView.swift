import PollyCore
import SwiftUI

struct MeetingDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case ask = "Ask"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    let meetingID: UUID
    @State private var tab: Tab = .summary
    @State private var title = ""
    @AppStorage(SettingsKey.myName) private var myName = ""

    var body: some View {
        if let meeting = model.meeting(id: meetingID) {
            VStack(alignment: .leading, spacing: 0) {
                header(meeting)
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 12)
                Divider()
                switch tab {
                case .summary: SummaryTab(meeting: meeting)
                case .transcript:
                    TranscriptView(segments: meeting.segments, labels: SpeakerLabels.display(for: meeting, myName: myName))
                case .ask: AskTab(meeting: meeting)
                }
            }
            .onAppear {
                title = meeting.title
                if meeting.summary == nil && !model.isSummarizing(meetingID) { tab = .transcript }
            }
            .onChange(of: meeting.title) { _, newValue in title = newValue }
            .onChange(of: model.isSummarizing(meetingID)) { _, summarizing in if summarizing { tab = .summary } }
            .toolbar {
                ToolbarItemGroup {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Menu {
                        Button("Copy Summary") { model.copySummary(meetingID) }
                            .disabled(meeting.summary == nil)
                        Button("Copy Notes + Transcript as Markdown") { model.copyMarkdown(meetingID) }
                        Button("Export Markdown…") { model.exportMarkdown(meetingID) }
                        Divider()
                        Button("Delete Meeting", role: .destructive) { model.delete(meetingID) }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title.bold())
                .onSubmit { model.rename(meetingID, to: title) }
            HStack(spacing: 8) {
                PlatformIcon(platform: meeting.platform)
                Text(meeting.startedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                Text("·")
                Text(TranscriptFormatter.timestamp(meeting.duration))
                Text("·")
                Text("\(meeting.segments.count) segments")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let progress = model.speakerProgress[meetingID] {
                HStack(spacing: 8) {
                    ProgressView(value: progress).frame(width: 120)
                    Text("Identifying speakers on this Mac…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else if !meeting.speakerIDs.isEmpty {
                SpeakersBar(meeting: meeting)
                    .padding(.top, 4)
            }
            if let error = model.speakerErrors[meetingID] {
                ErrorBanner(message: error, retry: nil)
            }
        }
    }
}

/// One chip per separated voice; click to name it.
private struct SpeakersBar: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.wave.2").foregroundStyle(.secondary)
                ForEach(meeting.speakerIDs, id: \.self) { id in
                    SpeakerChip(meeting: meeting, speakerID: id)
                }
                if meeting.summary != nil, namesChangedSinceSummary {
                    Button("Update notes with these names") { model.summarize(meeting.id) }
                        .controlSize(.small)
                        .disabled(model.isSummarizing(meeting.id))
                }
            }
        }
    }

    /// The user named someone after the notes were written.
    private var namesChangedSinceSummary: Bool {
        guard let summary = meeting.summary else { return false }
        return meeting.speakerNames.values.contains { !summary.contains($0) }
    }
}

private struct SpeakerChip: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let speakerID: String
    @State private var editing = false
    @State private var draft = ""

    private var confirmed: String? { meeting.speakerNames[speakerID] }
    private var suggested: String? { meeting.suggestedSpeakerNames[speakerID] }

    var body: some View {
        Button {
            draft = confirmed ?? suggested ?? ""
            editing = true
        } label: {
            HStack(spacing: 4) {
                Circle().fill(SpeakerColor.color(for: .others, speakerID: speakerID)).frame(width: 8, height: 8)
                Text(meeting.displayName(forSpeakerID: speakerID))
                if confirmed == nil, suggested != nil {
                    Text("?").foregroundStyle(.secondary).help("Suggested by Claude — click to confirm or change")
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Who is \(SpeakerLabels.defaultLabel(for: speakerID))?").font(.headline)
                if let quote = firstLine {
                    Text("“\(quote)”").font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if !choices.isEmpty {
                    Text("From the calendar invite").font(.caption).foregroundStyle(.secondary)
                    FlowButtons(items: choices) { name in
                        draft = name
                        save()
                    }
                }
                HStack {
                    if confirmed != nil || suggested != nil {
                        Button("Clear") {
                            draft = ""
                            save()
                        }
                    }
                    Spacer()
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }

    /// Something this voice said, to help the user recognise it.
    private var firstLine: String? {
        meeting.segments.first { $0.speakerID == speakerID && $0.text.count > 20 }?.text
            ?? meeting.segments.first { $0.speakerID == speakerID }?.text
    }

    /// Attendees not already assigned to another voice.
    private var choices: [String] {
        let taken = Set(meeting.speakerNames.filter { $0.key != speakerID }.values)
        return meeting.attendees.filter { !taken.contains($0) }
    }

    private func save() {
        model.renameSpeaker(speakerID, in: meeting.id, to: draft)
        editing = false
    }
}

private struct FlowButtons: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Button(item) { action(item) }
                    .buttonStyle(.link)
            }
        }
    }
}

private struct SummaryTab: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    @State private var canSummarize = AppSettings.canSummarize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = model.summaryErrors[meeting.id] {
                    ErrorBanner(message: error) { model.summarize(meeting.id) }
                }

                if let streaming = model.streamingSummary[meeting.id] {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.isIdentifyingSpeakers(meeting.id) ? "Identifying speakers…"
                             : streaming.isEmpty ? "Claude is reading the transcript…" : "Writing notes…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancelClaude(meeting.id) }
                            .controlSize(.small)
                    }
                    let visible = SpeakerNameParser.stripForDisplay(streaming)
                    if !visible.isEmpty { MarkdownView(markdown: visible) }
                } else if let summary = meeting.summary {
                    MarkdownView(markdown: summary)
                    HStack {
                        if let modelName = meeting.summaryModel, let date = meeting.summarizedAt {
                            Text("Generated by \(modelName) · \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Regenerate") { model.summarize(meeting.id) }
                            .controlSize(.small)
                    }
                    .padding(.top, 8)
                } else {
                    emptyState
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .onAppear { canSummarize = AppSettings.canSummarize }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No summary yet")
                .font(.title3.bold())
            if canSummarize {
                Text("Claude will write a title, summary, key points, decisions, action items and open questions from the transcript.")
                    .foregroundStyle(.secondary)
                Button {
                    model.summarize(meeting.id)
                } label: {
                    Label("Summarize with Claude", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(meeting.isEmpty || model.isIdentifyingSpeakers(meeting.id))
            } else {
                Text(AppSettings.summaryProvider == .claudeCode
                     ? "Polly couldn't find Claude Code. Install it and sign in with your Claude account, or choose an API key in Settings. Only the transcript text is sent — never audio."
                     : "Add your Anthropic API key in Settings to generate meeting notes with Claude. Only the transcript text is sent — never audio.")
                    .foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings…") }
            }
        }
    }
}

private struct AskTab: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    @State private var question = ""

    private let suggestions = [
        "What did I commit to?",
        "Draft a follow-up email to the attendees",
        "What were the main disagreements?",
        "List every date and deadline mentioned",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if meeting.questions.isEmpty && model.pendingQuestion[meeting.id] == nil {
                            Text("Ask Claude anything about this meeting.")
                                .foregroundStyle(.secondary)
                            FlowSuggestions(suggestions: suggestions) { ask($0) }
                        }
                        ForEach(meeting.questions) { qa in
                            QAView(question: qa.question, answer: qa.answer, isStreaming: false)
                        }
                        if let pending = model.pendingQuestion[meeting.id] {
                            QAView(question: pending.question, answer: pending.answer, isStreaming: true)
                        }
                        if let error = model.questionErrors[meeting.id] {
                            ErrorBanner(message: error, retry: nil)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                }
                .onChange(of: model.pendingQuestion[meeting.id]?.answer) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            HStack {
                TextField("Ask about this meeting…", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { ask(question) }
                Button {
                    ask(question)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || model.pendingQuestion[meeting.id] != nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
    }

    private func ask(_ text: String) {
        model.ask(text, about: meeting.id)
        question = ""
    }
}

private struct QAView: View {
    let question: String
    let answer: String
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(.headline)
                .padding(10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            if answer.isEmpty && isStreaming {
                ProgressView().controlSize(.small)
            } else {
                MarkdownView(markdown: answer)
            }
        }
    }
}

private struct FlowSuggestions: View {
    let suggestions: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button(suggestion) { action(suggestion) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let retry {
                Button("Retry", action: retry).controlSize(.small)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
