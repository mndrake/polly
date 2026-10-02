import PollyCore
import SwiftUI

struct LiveRecordingView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: RecordingSession
    @AppStorage(SettingsKey.myName) private var myName = ""
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            if !session.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.warnings, id: \.self) { warning in
                        ErrorBanner(message: warning, retry: nil)
                    }
                    if !Permissions.hasScreenRecording {
                        Button("Open Screen Recording Settings") { Permissions.openScreenRecordingSettings() }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            Divider()
            TranscriptView(segments: session.segments, liveText: session.liveText, isLive: true, labels: SpeakerLabels(myName: myName))
        }
        .onAppear { title = session.meeting.title }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title.bold())
                    .onSubmit { model.rename(session.meeting.id, to: title) }
                HStack(spacing: 10) {
                    statusLabel
                    if let engine = session.engineName {
                        Text("· \(engine), on device").foregroundStyle(.secondary)
                    }
                    LagBadge(latency: session.latency)
                }
                .font(.callout)
                HStack(spacing: 18) {
                    LevelMeter(label: TranscriptFormatter.label(for: .me, myName: myName), level: session.levels[.me])
                    LevelMeter(label: targetLabel, level: session.levels[.others])
                }
            }
            Spacer()
            Button {
                model.toggleCaptionPanel()
            } label: {
                Label("Floating Captions", systemImage: "captions.bubble")
            }
            .controlSize(.large)
            .help("Show live captions in a small window that stays on top of your meeting")
            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(session.state == .stopping)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.state {
        case let .preparing(message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message)
            }
        case .recording:
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Recording · \(TranscriptFormatter.timestamp(Date().timeIntervalSince(session.meeting.startedAt)))")
                        .monospacedDigit()
                }
            }
        case .stopping:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finishing transcript…")
            }
        case .finished:
            Text("Finished")
        case let .failed(message):
            Text(message).foregroundStyle(.red)
        }
    }

    private var targetLabel: String {
        switch session.configuration.target {
        case .allSystemAudio: return "System audio"
        case let .application(bundleID):
            if let detected = session.detectedMeeting, detected.bundleID == bundleID {
                return detected.platform == .googleMeet ? "Google Meet (browser)" : detected.platform.displayName
            }
            return MeetingPlatform.platform(forNativeBundleID: bundleID)?.displayName ?? "Meeting app"
        }
    }
}

private struct LevelMeter: View {
    let label: String
    let level: Float?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: level == nil ? "speaker.slash" : "waveform")
                .foregroundStyle(level == nil ? Color.secondary : Color.green)
            Text(label).font(.caption).foregroundStyle(.secondary)
            LevelBar(level: level)
                .frame(width: 80, height: 5)
        }
        .help(level == nil ? "Not capturing" : "Input level")
    }
}

/// A horizontal input-level bar.
struct LevelBar: View {
    let level: Float?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green)
                    .frame(width: geo.size.width * CGFloat(normalized))
            }
        }
    }

    /// Maps RMS to a perceptual 0…1 range (-50 dB … 0 dB).
    private var normalized: Float {
        guard let level, level > 0 else { return 0 }
        let db = 20 * log10(level)
        return min(1, max(0, (db + 50) / 50))
    }
}

/// Shows how far live text lags behind speech (e.g. "0.8 s behind").
struct LagBadge: View {
    let latency: LatencyMeter

    var body: some View {
        if let lag = latency.overall {
            Label(LatencyMeter.describe(lag), systemImage: "timer")
                .foregroundStyle(lag < 1.5 ? Color.green : lag < 3 ? Color.orange : Color.red)
                .help(help)
        }
    }

    private var help: String {
        let parts = Speaker.allCases.compactMap { speaker -> String? in
            guard let lag = latency.smoothed[speaker] else { return nil }
            return "\(speaker == .me ? "Your mic" : "Meeting audio"): \(LatencyMeter.describe(lag))"
        }
        return "How long after someone speaks their words appear.\n" + parts.joined(separator: "\n")
    }
}
