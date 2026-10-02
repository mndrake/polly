import AppKit
import PollyCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Polly").font(.headline)
                Spacer()
                if model.isRecording {
                    Label("Recording", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if model.isRecording {
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Stop & Summarize", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button {
                    model.toggleCaptionPanel()
                } label: {
                    Label(model.isCaptionPanelVisible ? "Hide Floating Captions" : "Show Floating Captions",
                          systemImage: "captions.bubble").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                if model.monitor.detected.isEmpty {
                    Text("No meeting detected").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.monitor.detected, id: \.bundleID) { meeting in
                    Button {
                        Task { await model.startRecording(detected: meeting) }
                    } label: {
                        HStack {
                            PlatformIcon(platform: meeting.platform)
                            Text("Transcribe \(meeting.platform.displayName)")
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    Task { await model.startRecording(allSystemAudio: true) }
                } label: {
                    Label("Record All System Audio", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            if let recent = model.meetings.first {
                Button {
                    model.selection = recent.id
                    showMainWindow()
                } label: {
                    VStack(alignment: .leading) {
                        Text("Latest: \(recent.title)").lineLimit(1)
                        Text(recent.startedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            HStack {
                Button("Open Polly") { showMainWindow() }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Log") { PollyLog.reveal() }
                    .help("Show the diagnostics log")
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
