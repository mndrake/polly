import PollyCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            if let recording = model.recording, model.selection == recording.meeting.id {
                LiveRecordingView(session: recording)
            } else if let id = model.selection, model.meeting(id: id) != nil {
                MeetingDetailView(meetingID: id)
                    .id(id)
            } else {
                EmptyStateView()
            }
        }
        .alert("Polly", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            RecordControl()
                .padding(12)
            if !model.isRecording, !model.monitor.detected.isEmpty {
                DetectedMeetingsBanner()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            List(selection: $model.selection) {
                if let recording = model.recording, recording.isActive {
                    Section("Now") {
                        LiveMeetingRow(session: recording)
                            .tag(recording.meeting.id)
                    }
                }
                Section("Meetings") {
                    ForEach(model.meetings) { meeting in
                        MeetingRow(meeting: meeting, isSummarizing: model.isSummarizing(meeting.id))
                            .tag(meeting.id)
                            .contextMenu {
                                Button("Copy as Markdown") { model.copyMarkdown(meeting.id) }
                                Button("Export Markdown…") { model.exportMarkdown(meeting.id) }
                                Divider()
                                Button("Delete", role: .destructive) { model.delete(meeting.id) }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.meetings.isEmpty && model.recording == nil {
                    Text("No meetings yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RecordControl: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isRecording {
            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            Button {
                Task { await model.startRecording(detected: model.monitor.detected.first) }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help("Transcribe your microphone and the meeting app's audio. Make sure everyone consents to being transcribed.")
        }
    }
}

struct DetectedMeetingsBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.monitor.detected, id: \.bundleID) { meeting in
                HStack {
                    PlatformIcon(platform: meeting.platform)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(meeting.platform.displayName) meeting")
                            .font(.callout.weight(.medium))
                        if let title = meeting.suggestedTitle {
                            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Transcribe") {
                        Task { await model.startRecording(detected: meeting) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PlatformIcon: View {
    let platform: MeetingPlatform

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .frame(width: 18)
    }

    private var symbol: String {
        switch platform {
        case .zoom: return "video.fill"
        case .teams: return "person.3.fill"
        case .googleMeet: return "video.bubble.fill"
        case .webex: return "globe"
        case .other: return "waveform"
        }
    }

    private var color: Color {
        switch platform {
        case .zoom: return .blue
        case .teams: return .indigo
        case .googleMeet: return .green
        case .webex: return .teal
        case .other: return .secondary
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let isSummarizing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PlatformIcon(platform: meeting.platform)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Text("·")
                    Text(TranscriptFormatter.timestamp(meeting.duration))
                    if isSummarizing {
                        ProgressView().controlSize(.mini)
                    } else if meeting.summary != nil {
                        Image(systemName: "sparkles").help("Summarized")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct LiveMeetingRow: View {
    @ObservedObject var session: RecordingSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.meeting.title).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(TranscriptFormatter.timestamp(Date().timeIntervalSince(session.meeting.startedAt)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Transcribe your next call")
                .font(.title2.bold())
            Text("Polly listens to your microphone and your meeting app — Zoom, Teams, Google Meet or anything else — transcribes on this Mac, and writes notes with Claude.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Start Recording") {
                Task { await model.startRecording(detected: model.monitor.detected.first) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if !AppSettings.canSummarize {
                SettingsLink {
                    Text("Set up Claude (Claude Code or an API key) to enable summaries")
                }
                .buttonStyle(.link)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
