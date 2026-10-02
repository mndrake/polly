import PollyCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ClaudeSettings()
                .tabItem { Label("Claude", systemImage: "sparkles") }
            TranscriptionSettings()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            DetectionSettings()
                .tabItem { Label("Meetings", systemImage: "video") }
            CalendarSettings(google: model.google)
                .tabItem { Label("Calendar", systemImage: "calendar") }
            VoiceSettings()
                .tabItem { Label("Voices", systemImage: "person.wave.2") }
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
    @AppStorage(SettingsKey.summaryProvider) private var provider = SummaryProvider.claudeCode.rawValue
    @AppStorage(SettingsKey.claudeCodePath) private var claudeCodePath = ""
    @State private var apiKey = ""
    @State private var savedMessage: String?
    @State private var claudeCodeLocation: URL?

    private func refreshLocation() {
        ClaudeCodeLocator.reset()
        claudeCodeLocation = ClaudeCodeLocator.find(explicitPath: claudeCodePath)
    }

    var body: some View {
        Form {
            Section {
                Picker("Generate summaries with", selection: $provider) {
                    ForEach(SummaryProvider.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                if provider == SummaryProvider.claudeCode.rawValue {
                    HStack {
                        if let found = claudeCodeLocation {
                            Label(found.path, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Label("Claude Code not found", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Check Again") { refreshLocation() }
                    }
                    TextField("Custom location (optional)", text: $claudeCodePath, prompt: Text("~/.local/bin/claude"))
                        .onSubmit { refreshLocation() }
                    Link("Install Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
                        .font(.caption)
                } else {
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
                }
            } header: {
                Text("Claude")
            } footer: {
                Text(provider == SummaryProvider.claudeCode.rawValue
                     ? "Uses your installed Claude Code, signed in with your Claude account (Pro, Max, Team or Enterprise). Usage counts toward your plan's limits instead of API billing. Run `claude` in Terminal once to sign in. Only transcript text is sent."
                     : "Billed per token to your Anthropic Console account. Only transcript text is sent, and only when you summarize or ask a question.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Summaries") {
                Picker("Model", selection: $modelID) {
                    ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Effort", selection: $effort) {
                    ForEach(ClaudeEffort.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .disabled(provider == SummaryProvider.claudeCode.rawValue || !(ClaudeModel(rawValue: modelID)?.supportsEffort ?? true))
                .help(provider == SummaryProvider.claudeCode.rawValue ? "Claude Code chooses the effort level itself." : "")
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
        .onAppear {
            apiKey = KeychainStore.read() ?? ""
            refreshLocation()
        }
    }
}

private struct TranscriptionSettings: View {
    @AppStorage(SettingsKey.transcriptionLocale) private var localeID = Locale.current.identifier
    @AppStorage(SettingsKey.engine) private var engine = EnginePreference.automatic.rawValue
    @AppStorage(SettingsKey.captureMode) private var captureMode = CaptureMode.meetingApp.rawValue
    @AppStorage(SettingsKey.captureMicrophone) private var captureMicrophone = true
    @AppStorage(SettingsKey.echoSuppression) private var echoSuppression = true
    @AppStorage(SettingsKey.showCaptionPanel) private var showCaptionPanel = true
    @AppStorage(SettingsKey.separateSpeakers) private var separateSpeakers = true
    @AppStorage(SettingsKey.useCalendarAttendees) private var useCalendarAttendees = true
    @AppStorage(SettingsKey.rememberVoices) private var rememberVoices = true
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
            }

            Section {
                Toggle("Tell other participants' voices apart", isOn: $separateSpeakers)
                    .disabled(!SpeakerDiarization.isSupported)
                Toggle("Use calendar invitees to name speakers", isOn: $useCalendarAttendees)
                Toggle("Remember voices across meetings", isOn: $rememberVoices)
                    .disabled(!SpeakerDiarization.isSupported)
            } header: {
                Text("Speakers")
            } footer: {
                Text(SpeakerDiarization.isSupported
                     ? "After a meeting, Polly separates the other participants' voices on this Mac (Speaker 1, Speaker 2, …) and Claude suggests who is who from the conversation and the calendar invite. Click a speaker to set their name. While recording, the meeting audio is kept in a temporary file until this finishes, then deleted. The first run downloads the voice models."
                     : "Telling voices apart needs macOS 15 or later. Claude still names people when it can tell from the conversation.")
                    .font(.caption).foregroundStyle(.secondary)
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

/// People Polly recognizes by voice.
private struct VoiceSettings: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.rememberVoices) private var rememberVoices = true
    @State private var confirmForgetAll = false

    var body: some View {
        Form {
            Section {
                Toggle("Remember voices across meetings", isOn: $rememberVoices)
                    .disabled(!SpeakerDiarization.isSupported)
            } footer: {
                Text("When you name or confirm a speaker, Polly saves a voice fingerprint (a list of numbers, not a recording) on this Mac and uses it to recognize that person in later meetings. Only voices you named are learned. Deleting a meeting removes what was learned from it. Recording laws in some places require consent before storing someone's voice characteristics; tell participants.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Known voices") {
                if model.voiceLibrary.profiles.isEmpty {
                    Text("No voices yet. Name a speaker in a meeting to start.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.voiceLibrary.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { profile in
                        VoiceRow(profile: profile)
                    }
                }
            }

            if !model.voiceLibrary.profiles.isEmpty {
                Section {
                    Button("Forget All Voices…", role: .destructive) { confirmForgetAll = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget all voices?", isPresented: $confirmForgetAll) {
            Button("Forget All", role: .destructive) { model.forgetAllVoices() }
        } message: {
            Text("Polly will stop recognizing everyone until you name them again. Meetings and their transcripts are kept.")
        }
    }
}

private struct VoiceRow: View {
    @EnvironmentObject private var model: AppModel
    let profile: VoiceProfile
    @State private var name = ""

    var body: some View {
        HStack {
            Image(systemName: "person.wave.2").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .onSubmit { model.renameVoice(profile.id, to: name) }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                model.removeVoice(profile.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget \(profile.name)'s voice")
        }
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { _, newValue in name = newValue }
    }

    private var detail: String {
        let meetings = profile.meetingCount == 1 ? "1 meeting" : "\(profile.meetingCount) meetings"
        guard let last = profile.lastHeard else { return meetings }
        return "Learned from \(meetings) · last \(last.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// Google Calendar connection, plus a note on macOS Calendar accounts.
private struct CalendarSettings: View {
    @ObservedObject var google: GoogleCalendarService
    @AppStorage(SettingsKey.useCalendarAttendees) private var useCalendar = true
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var showClientFields = false

    private static let guideURL = URL(string: "https://github.com/mndrake/polly/blob/main/docs/GOOGLE_CALENDAR.md")!

    var body: some View {
        Form {
            Section {
                Toggle("Look up the meeting in my calendar", isOn: $useCalendar)
            } footer: {
                Text("When recording starts, Polly finds the event happening now and uses its title and invitees, so Claude can put names to voices. Only invitee names are included when the transcript is sent to Claude.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Google Calendar") {
                if let email = google.connectedEmail {
                    HStack {
                        Label("Connected: \(email)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect") { google.disconnect() }
                    }
                } else if google.isConnecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…")
                        Spacer()
                        Button("Cancel") { google.cancelConnect() }
                    }
                } else {
                    HStack {
                        Button("Connect Google Calendar…") {
                            Task { await google.connect() }
                        }
                        .disabled(!google.client.isConfigured)
                        Spacer()
                        Link("Setup guide", destination: Self.guideURL).font(.caption)
                    }
                }
                if let error = google.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                DisclosureGroup("OAuth client", isExpanded: $showClientFields) {
                    TextField("Client ID", text: $clientID, prompt: Text("1234-abc.apps.googleusercontent.com"))
                    SecureField("Client secret", text: $clientSecret, prompt: Text("GOCSPX-…"))
                    HStack {
                        Button("Save") { google.saveClient(id: clientID, secret: clientSecret) }
                            .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || clientSecret.isEmpty)
                        Spacer()
                        Link("How to create one", destination: Self.guideURL).font(.caption)
                    }
                    Text("Google requires each app to have its own OAuth client. Create a free \"Desktop app\" client in your Google Cloud project (an \"Internal\" app if you use Google Workspace) with the Google Calendar API enabled. Polly only asks for read-only access to events.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Other calendars") {
                Text("Polly also reads macOS Calendar, which includes accounts added in System Settings → Internet Accounts (Google, Microsoft Exchange/Outlook, iCloud). If your organization allows it, adding your Google account there works without setting up an OAuth client.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            clientID = google.client.clientID
            clientSecret = google.client.clientSecret
            showClientFields = !google.client.isConfigured && !google.isConnected
        }
    }
}
