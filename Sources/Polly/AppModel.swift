import AppKit
import Combine
import Foundation
import PollyCore
import UniformTypeIdentifiers

/// App-wide state: the meeting library, the active recording, meeting
/// detection, and Claude requests.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published var selection: UUID?
    @Published private(set) var recording: RecordingSession?
    @Published var alert: String?

    /// Summary text while it streams in, keyed by meeting.
    @Published private(set) var streamingSummary: [UUID: String] = [:]
    @Published private(set) var summaryErrors: [UUID: String] = [:]
    /// The question being answered and its streaming answer, keyed by meeting.
    @Published private(set) var pendingQuestion: [UUID: QAExchange] = [:]
    @Published private(set) var questionErrors: [UUID: String] = [:]

    let monitor = MeetingMonitor()
    private let captionPanel = LiveCaptionPanelController()
    private let notifier = MeetingNotifier()
    private let store: MeetingStore
    private var claudeTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init() {
        AppSettings.registerDefaults()
        do {
            store = try MeetingStore(directory: MeetingStore.defaultDirectory())
        } catch {
            fatalError("Polly can't create its data folder: \(error)")
        }
        meetings = store.loadAll()
        selection = meetings.first?.id

        notifier.setUp()
        notifier.onStartRequested = { [weak self] bundleID in
            guard let self else { return }
            let match = self.monitor.detected.first { $0.bundleID == bundleID }
            Task { await self.startRecording(detected: match ?? self.fallbackDetection(bundleID: bundleID)) }
            NSApp.activate(ignoringOtherApps: true)
        }

        monitor.onNewMeeting = { [weak self] meeting in self?.meetingDetected(meeting) }
        monitor.onMeetingEnded = { [weak self] meeting in self?.meetingEnded(meeting) }
        // Re-publish monitor changes so views observing AppModel update.
        monitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        applyDetectionSetting()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyDetectionSetting() }
            .store(in: &cancellables)
    }

    // MARK: - Library

    var isRecording: Bool { recording?.isActive ?? false }

    func meeting(id: UUID) -> Meeting? {
        if let recording, recording.meeting.id == id { return recording.meeting }
        return meetings.first { $0.id == id }
    }

    private func upsert(_ meeting: Meeting, save: Bool = true) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        if save {
            do { try store.save(meeting) } catch { alert = "Couldn't save “\(meeting.title)”: \(error.localizedDescription)" }
        }
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let recording, recording.meeting.id == id {
            recording.rename(trimmed)
            return
        }
        guard var meeting = meeting(id: id), meeting.title != trimmed else { return }
        meeting.title = trimmed
        meeting.hasDefaultTitle = false
        upsert(meeting)
    }

    func delete(_ id: UUID) {
        guard recording?.meeting.id != id || !isRecording else { return }
        claudeTasks[id]?.cancel()
        meetings.removeAll { $0.id == id }
        try? store.delete(id: id)
        if selection == id { selection = meetings.first?.id }
    }

    // MARK: - Recording

    /// Starts a recording of `detected` (or the first detected meeting). With
    /// `allSystemAudio`, or when no meeting app is known, all system audio is captured.
    func startRecording(detected: DetectedMeeting? = nil, allSystemAudio: Bool = false) async {
        guard !isRecording else { return }
        let detected = allSystemAudio ? nil : detected
        let target: CaptureTarget
        if allSystemAudio || AppSettings.captureMode == .allSystemAudio {
            target = .allSystemAudio
        } else if let bundleID = detected?.bundleID ?? monitor.detected.first?.bundleID {
            target = .application(bundleID: bundleID)
        } else {
            target = .allSystemAudio
        }
        let platform: MeetingPlatform = allSystemAudio ? .other : (detected?.platform ?? monitor.detected.first?.platform ?? .other)

        let meeting = Meeting(title: detected?.suggestedTitle, platform: platform)
        let session = RecordingSession(
            meeting: meeting,
            configuration: .init(
                target: target,
                locale: AppSettings.locale,
                engine: AppSettings.engine,
                captureMicrophone: AppSettings.captureMicrophone,
                echoSuppression: AppSettings.echoSuppression
            ),
            detectedMeeting: detected,
            store: store
        )
        recording = session
        selection = meeting.id
        monitor.isRecording = true
        notifier.clear()
        if AppSettings.showCaptionPanel {
            captionPanel.show(session: session, model: self)
        }

        await session.start()
        if case let .failed(message) = session.state {
            captionPanel.close()
            recording = nil
            monitor.isRecording = false
            selection = meetings.first?.id
            alert = "Couldn't start recording: \(message)"
        }
    }

    func stopRecording() async {
        guard let session = recording, session.isActive else { return }
        let meeting = await session.stop()
        captionPanel.close()
        monitor.isRecording = false
        recording = nil

        if meeting.isEmpty {
            try? store.delete(id: meeting.id)
            selection = meetings.first?.id
            alert = "Nothing was transcribed, so the recording was discarded."
            return
        }
        upsert(meeting, save: false) // already saved by the session
        selection = meeting.id
        if AppSettings.autoSummarize, KeychainStore.apiKey != nil {
            summarize(meeting.id)
        }
    }

    var isCaptionPanelVisible: Bool { captionPanel.isVisible }

    /// Shows or hides the floating live-caption window for the current recording.
    func toggleCaptionPanel() {
        guard let session = recording, session.isActive else { return }
        captionPanel.toggle(session: session, model: self)
        objectWillChange.send()
    }

    func toggleRecording() {
        Task {
            if isRecording { await stopRecording() } else { await startRecording() }
        }
    }

    // MARK: - Detection

    private func applyDetectionSetting() {
        if AppSettings.detectMeetings { monitor.start() } else { monitor.stop() }
    }

    private func meetingDetected(_ meeting: DetectedMeeting) {
        guard !isRecording else { return }
        if AppSettings.autoStart, meeting.confidence == .high {
            Task { await startRecording(detected: meeting) }
        } else if AppSettings.notifyOnDetection {
            notifier.notify(meeting)
        }
    }

    private func meetingEnded(_ meeting: DetectedMeeting) {
        guard AppSettings.autoStop, let session = recording, session.isActive,
              session.detectedMeeting?.bundleID == meeting.bundleID
        else { return }
        Task { await stopRecording() }
    }

    private func fallbackDetection(bundleID: String) -> DetectedMeeting {
        let platform = MeetingPlatform.platform(forNativeBundleID: bundleID) ?? .other
        return DetectedMeeting(platform: platform, bundleID: bundleID, windowTitle: nil, confidence: .medium)
    }

    // MARK: - Claude

    private func makeClient() throws -> ClaudeClient {
        guard let key = KeychainStore.apiKey else { throw ClaudeError.missingAPIKey }
        return ClaudeClient(apiKey: key, transport: URLSessionLineTransport())
    }

    func isSummarizing(_ id: UUID) -> Bool { streamingSummary[id] != nil }

    func summarize(_ id: UUID) {
        guard let meeting = meeting(id: id), !isSummarizing(id), !(recording?.meeting.id == id && isRecording) else { return }
        summaryErrors[id] = nil
        streamingSummary[id] = ""

        let request = MeetingPrompts.summaryRequest(
            for: meeting,
            myName: AppSettings.myName,
            model: AppSettings.claudeModel,
            effort: AppSettings.claudeEffort,
            customInstructions: AppSettings.customInstructions
        )
        claudeTasks[id] = Task {
            defer {
                streamingSummary[id] = nil
                claudeTasks[id] = nil
            }
            do {
                let client = try makeClient()
                var text = ""
                var model: String?
                var completed = false
                for try await event in client.stream(request) {
                    switch event {
                    case let .started(name): model = name
                    case .thinking: break
                    case let .textDelta(delta):
                        text += delta
                        streamingSummary[id] = text
                    case .completed: completed = true
                    }
                }
                // A cancelled stream ends quietly; never save a partial summary.
                guard completed, !Task.isCancelled, var latest = self.meeting(id: id) else { return }
                latest.summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
                latest.summaryModel = model
                latest.summarizedAt = Date()
                if latest.hasDefaultTitle, let title = MeetingPrompts.extractTitle(fromSummary: text) {
                    latest.title = title
                    latest.hasDefaultTitle = false
                }
                upsert(latest)
            } catch {
                // Cancelled by the user, or the meeting was deleted.
                if !Task.isCancelled { summaryErrors[id] = error.localizedDescription }
            }
        }
    }

    func cancelClaude(_ id: UUID) {
        claudeTasks[id]?.cancel()
    }

    func ask(_ question: String, about id: UUID) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pendingQuestion[id] == nil, let meeting = meeting(id: id),
              !(recording?.meeting.id == id && isRecording)
        else { return }
        questionErrors[id] = nil
        pendingQuestion[id] = QAExchange(question: trimmed, answer: "")

        let request = MeetingPrompts.questionRequest(
            for: meeting,
            question: trimmed,
            myName: AppSettings.myName,
            model: AppSettings.claudeModel,
            effort: AppSettings.claudeEffort
        )
        Task {
            defer { pendingQuestion[id] = nil }
            do {
                let client = try makeClient()
                var answer = ""
                var completed = false
                for try await event in client.stream(request) {
                    if case let .textDelta(delta) = event {
                        answer += delta
                        pendingQuestion[id]?.answer = answer
                    } else if case .completed = event {
                        completed = true
                    }
                }
                guard completed, var latest = self.meeting(id: id) else { return }
                latest.questions.append(QAExchange(question: trimmed, answer: answer.trimmingCharacters(in: .whitespacesAndNewlines)))
                upsert(latest)
            } catch {
                questionErrors[id] = error.localizedDescription
            }
        }
    }

    // MARK: - Export

    func markdown(for id: UUID) -> String? {
        meeting(id: id).map { MarkdownExporter.markdown(for: $0, myName: AppSettings.myName) }
    }

    func copyMarkdown(_ id: UUID) {
        guard let text = markdown(for: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copySummary(_ id: UUID) {
        guard let summary = meeting(id: id)?.summary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    func exportMarkdown(_ id: UUID) {
        guard let meeting = meeting(id: id), let text = markdown(for: id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MarkdownExporter.fileName(for: meeting)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert = "Export failed: \(error.localizedDescription)"
        }
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }
}
