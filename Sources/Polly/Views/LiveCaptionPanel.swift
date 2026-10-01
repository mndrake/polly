import AppKit
import PollyCore
import SwiftUI

/// A small always-on-top window with live captions, so you can see Polly is
/// capturing both sides of the conversation while the meeting app is in front
/// (including full-screen meetings). It is excluded from screen sharing.
@MainActor
final class LiveCaptionPanelController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(session: RecordingSession, model: AppModel) {
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(
            rootView: LiveCaptionView(session: session).environmentObject(model)
        )
        if !panel.setFrameUsingName(Self.autosaveName) {
            positionAtBottomCenter(panel)
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    func toggle(session: RecordingSession, model: AppModel) {
        if isVisible { close() } else { show(session: session, model: model) }
    }

    private static let autosaveName = "PollyLiveCaptions"

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 190),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Polly Live Captions"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        // Show over full-screen meeting windows and on every Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 120)
        // Keep captions out of screen shares and recordings of the screen.
        panel.sharingType = .none
        panel.setFrameAutosaveName(Self.autosaveName)
        return panel
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 40))
    }
}

/// Last few transcript turns plus per-channel capture status.
struct LiveCaptionView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: RecordingSession
    @AppStorage(SettingsKey.myName) private var myName = ""

    private static let visibleTurns = 4

    private var recentTurns: [TranscriptSegment] {
        Array(TranscriptFormatter.turns(session.segments).suffix(Self.visibleTurns))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                status
                Spacer()
                ChannelStatus(label: TranscriptFormatter.label(for: .me, myName: myName),
                              level: session.levels[.me],
                              hasText: hasText(.me))
                ChannelStatus(label: "Others", level: session.levels[.others], hasText: hasText(.others))
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop recording")
            }
            .font(.caption)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if recentTurns.isEmpty && session.liveText.isEmpty {
                            Text(waitingMessage)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(recentTurns) { turn in
                            line(turn.speaker, turn.text, live: false)
                        }
                        ForEach(Speaker.allCases, id: \.self) { speaker in
                            if let text = session.liveText[speaker], !text.isEmpty {
                                line(speaker, text, live: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.segments.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: session.liveText) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }

            if let warning = session.warnings.last {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 22) // clear the transparent title bar
        .padding(.bottom, 12)
        .frame(minWidth: 320, minHeight: 120)
    }

    @ViewBuilder
    private var status: some View {
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
                    Text(TranscriptFormatter.timestamp(Date().timeIntervalSince(session.meeting.startedAt)))
                        .monospacedDigit()
                }
            }
        case .stopping:
            Text("Finishing…")
        case .finished:
            Text("Stopped")
        case let .failed(message):
            Text(message).foregroundStyle(.red)
        }
    }

    private var waitingMessage: String {
        if case .preparing = session.state { return "Getting ready…" }
        return "Listening… captions appear here as people speak."
    }

    private func hasText(_ speaker: Speaker) -> Bool {
        session.segments.contains { $0.speaker == speaker } || !(session.liveText[speaker] ?? "").isEmpty
    }

    private func line(_ speaker: Speaker, _ text: String, live: Bool) -> some View {
        (Text(TranscriptFormatter.label(for: speaker, myName: myName) + ": ")
            .bold()
            .foregroundColor(speaker == .me ? .accentColor : .orange)
         + Text(text).foregroundColor(live ? .secondary : .primary))
            .font(.system(size: 15))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shows whether a channel is capturing audio and has produced text yet.
private struct ChannelStatus: View {
    let label: String
    let level: Float?
    let hasText: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
            LevelBar(level: level)
                .frame(width: 36, height: 4)
        }
        .help(help)
    }

    private var color: Color {
        guard level != nil else { return .gray }
        return hasText ? .green : .yellow
    }

    private var help: String {
        guard level != nil else { return "\(label): not capturing" }
        return hasText ? "\(label): capturing and transcribing" : "\(label): capturing, no speech transcribed yet"
    }
}
