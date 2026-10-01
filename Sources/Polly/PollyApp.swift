import AppKit
import SwiftUI

@main
struct PollyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Polly", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                    model.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run Polly`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running in the menu bar to detect meetings
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRecording else { return .terminateNow }
        // Finish and save the transcript before quitting.
        Task {
            await model.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
