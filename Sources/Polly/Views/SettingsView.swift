import PollyCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ClaudeSettings()
                .tabItem { Label("Claude", systemImage: "sparkles") }
            TranscriptionSettings()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            DetectionSettings()
                .tabItem { Label("Meetings", systemImage: "video") }
        }
        .frame(width: 560)
        .padding(20)
    }
}

private struct ClaudeSettings: View {
    @AppStorage(SettingsKey.claudeModel) private var modelID = ClaudeModel.default.rawValue
    @AppStorage(SettingsKey.claudeEffort) private var effort = ClaudeEffort.medium.rawValue
    @AppStorage(SettingsKey.autoSummarize) private var autoSummarize = true
    @AppStorage(SettingsKey.customInstructions) private var customInstructions = ""
    @AppStorage(SettingsKey.myName) private var myName = ""
    @State private var apiKey = ""
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section {
                SecureField("Anthropic API key", text: $apiKey, prompt: Text("sk-ant-…"))
                HStack {
                    Button("Save Key") {
                        savedMessage = KeychainStore.save(apiKey) ? (apiKey.isEmpty ? "Key removed." : "Saved to your Keychain.") : "Couldn't save to the Keychain."
                    }
                    if let savedMessage {
                        Text(savedMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Get an API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("Only transcript text is sent to Anthropic, and only when you summarize or ask a question.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Summaries") {
                Picker("Model", selection: $modelID) {
                    ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Effort", selection: $effort) {
                    ForEach(ClaudeEffort.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .disabled(!(ClaudeModel(rawValue: modelID)?.supportsEffort ?? true))
                Toggle("Summarize automatically when a recording stops", isOn: $autoSummarize)
                TextField("Your name", text: $myName, prompt: Text("Used to label your lines in transcripts"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra instructions for summaries")
                    TextEditor(text: $customInstructions)
                        .font(.body)
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    Text("e.g. \"Write action items in German\" or \"Our team is Acme Payments; flag anything about the Q3 launch.\"")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = KeychainStore.read() ?? "" }
    }
}

private struct TranscriptionSettings: View {
    @AppStorage(SettingsKey.transcriptionLocale) private var localeID = Locale.current.identifier
    @AppStorage(SettingsKey.engine) private var engine = EnginePreference.automatic.rawValue
    @AppStorage(SettingsKey.captureMode) private var captureMode = CaptureMode.meetingApp.rawValue
    @AppStorage(SettingsKey.captureMicrophone) private var captureMicrophone = true
    @AppStorage(SettingsKey.echoSuppression) private var echoSuppression = true
    @AppStorage(SettingsKey.showCaptionPanel) private var showCaptionPanel = true
    @EnvironmentObject private var model: AppModel

    private let locales = AppSettings.transcriptionLocales

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("Language", selection: $localeID) {
                    if !locales.contains(where: { $0.identifier == localeID }) {
                        Text(Locale.current.localizedString(forIdentifier: localeID) ?? localeID).tag(localeID)
                    }
                    ForEach(locales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                Picker("Engine", selection: $engine) {
                    ForEach(EnginePreference.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Text("Transcription always runs on this Mac. The first recording in a new language may download a speech model.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Other participants", selection: $captureMode) {
                    ForEach(CaptureMode.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Toggle("Transcribe my microphone", isOn: $captureMicrophone)
                Toggle("Remove speaker echo from my channel", isOn: $echoSuppression)
                Toggle("Show floating live captions while recording", isOn: $showCaptionPanel)
                Text("If you're not wearing headphones, your microphone also hears other participants. Echo removal drops those duplicate lines. Headphones give the cleanest transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Label("Screen & System Audio Recording", systemImage: Permissions.hasScreenRecording ? "checkmark.circle.fill" : "exclamationmark.circle")
                    Spacer()
                    Button("Open Settings") { Permissions.openScreenRecordingSettings() }
                }
                HStack {
                    Label("Microphone", systemImage: "mic")
                    Spacer()
                    Button("Open Settings") { Permissions.openMicrophoneSettings() }
                }
                Button("Show Transcripts Folder") { model.revealDataFolder() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DetectionSettings: View {
    @AppStorage(SettingsKey.detectMeetings) private var detectMeetings = true
    @AppStorage(SettingsKey.notifyOnDetection) private var notify = true
    @AppStorage(SettingsKey.autoStart) private var autoStart = false
    @AppStorage(SettingsKey.autoStop) private var autoStop = true

    var body: some View {
        Form {
            Section {
                Toggle("Detect Zoom, Teams, Google Meet and Webex meetings", isOn: $detectMeetings)
                Toggle("Notify me when a meeting starts", isOn: $notify)
                    .disabled(!detectMeetings)
                Toggle("Start transcribing automatically", isOn: $autoStart)
                    .disabled(!detectMeetings)
                Toggle("Stop when the meeting window closes", isOn: $autoStop)
                    .disabled(!detectMeetings)
            } header: {
                Text("Meeting detection")
            } footer: {
                Text("Detection looks at meeting app windows (e.g. “Zoom Meeting”, “Meet – abc-defg-hij”) and whether a meeting app is using the microphone. Always make sure everyone in the meeting agrees to being transcribed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
