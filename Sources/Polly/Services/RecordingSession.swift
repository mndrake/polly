import AVFoundation
import Foundation
import PollyCore

/// One live recording: two capture sources → two speech engines → one transcript.
@MainActor
final class RecordingSession: ObservableObject {
    enum State: Equatable {
        case preparing(String)
        case recording
        case stopping
        case finished
        case failed(String)
    }

    struct Configuration {
        var target: CaptureTarget
        var locale: Locale
        var engine: EnginePreference
        var captureMicrophone: Bool
        var echoSuppression: Bool
        /// Keep the remote audio in a temporary file for speaker separation afterwards.
        var separateSpeakers: Bool
    }

    @Published private(set) var state: State = .preparing("Starting…")
    @Published private(set) var meeting: Meeting
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var liveText: [Speaker: String] = [:]
    @Published private(set) var levels: [Speaker: Float] = [:]
    @Published private(set) var warnings: [String] = []
    @Published private(set) var engineName: String?
    /// How far live text lags behind the audio, per channel.
    @Published private(set) var latency = LatencyMeter()

    let configuration: Configuration
    /// Set when the recording was started from a detected meeting (used for auto-stop).
    let detectedMeeting: DetectedMeeting?

    private let store: MeetingStore
    private var builder: TranscriptBuilder
    private var pipelines: [Speaker: ChannelPipeline] = [:]
    private var microphone: MicrophoneCapture?
    private var systemAudio: SystemAudioCapture?
    private var timers: [Task<Void, Never>] = []
    private var lastSavedSegmentCount = 0
    private var othersRecorder: AudioFileRecorder?
    private var resultCounts: [Speaker: Int] = [:]
    private var lastResultAt: [Speaker: Date] = [:]
    private var warnedSilentEngine: Set<Speaker> = []
    /// After `stop()`: the remote channel's audio, for speaker separation. The caller deletes it.
    private(set) var othersAudioURL: URL?

    init(meeting: Meeting, configuration: Configuration, detectedMeeting: DetectedMeeting?, store: MeetingStore) {
        self.meeting = meeting
        self.configuration = configuration
        self.detectedMeeting = detectedMeeting
        self.store = store
        builder = TranscriptBuilder(echoSuppression: configuration.echoSuppression)
    }

    var isActive: Bool {
        switch state {
        case .preparing, .recording: return true
        default: return false
        }
    }

    // MARK: - Start

    func start() async {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        PollyLog.info("Starting recording: Polly \(appVersion), macOS \(version), target \(configuration.target), locale \(configuration.locale.identifier), engine preference \(configuration.engine.rawValue), mic \(configuration.captureMicrophone), screen recording allowed \(Permissions.hasScreenRecording)")
        do {
            try await startChannels()
            state = .recording
            startTimers()
        } catch {
            PollyLog.info("Recording failed to start: \(error.localizedDescription)")
            await tearDown()
            state = .failed(error.localizedDescription)
        }
    }

    private func startChannels() async throws {
        state = .preparing("Checking permissions…")
        var micAllowed = false
        if configuration.captureMicrophone {
            micAllowed = await Permissions.requestMicrophone()
            if !micAllowed {
                warnings.append("Microphone access is off, so your own voice won't be transcribed. Enable it in System Settings → Privacy & Security → Microphone.")
            }
        }
        if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
        }

        state = .preparing("Loading on-device speech model…")
        let startDate = Date()
        meeting.startedAt = startDate

        // Remote participants (meeting app audio).
        do {
            let prepared = try await TranscriptionEngineFactory.makePreparedEngine(preference: configuration.engine, locale: configuration.locale)
            let engine = prepared.engine
            engineName = engine.name
            noteFallback(prepared.fallbackNote)
            watchFailures(of: engine, speaker: .others)
            let pipeline = ChannelPipeline(speaker: .others, engine: engine, startDate: startDate)
            if configuration.separateSpeakers {
                let url = AudioFileRecorder.directory.appendingPathComponent("\(meeting.id.uuidString).caf")
                do {
                    let recorder = try AudioFileRecorder(url: url, format: engine.audioFormat)
                    pipeline.tap = { [recorder] buffer in recorder.write(buffer) }
                    othersRecorder = recorder
                } catch {
                    warnings.append("Speaker separation is off for this meeting: \(error.localizedDescription)")
                }
            }
            try await pipeline.start(onUpdate: makeUpdateHandler())

            let capture = SystemAudioCapture()
            capture.onBuffer = { @Sendable [weak pipeline] buffer in pipeline?.ingest(buffer) }
            capture.onStop = { @Sendable [weak self] error in
                Task { @MainActor in self?.systemAudioStopped(error) }
            }
            do {
                try await capture.start(target: configuration.target)
            } catch SystemAudioCapture.CaptureError.applicationNotRunning(let bundleID) {
                warnings.append("\(bundleID) isn't running, so Polly is capturing all system audio instead.")
                try await capture.start(target: .allSystemAudio)
            }
            systemAudio = capture
            pipelines[.others] = pipeline
            PollyLog.info("Meeting audio capture started (target: \(configuration.target))")
        } catch {
            PollyLog.info("Meeting audio channel failed: \(error.localizedDescription) (screen recording allowed: \(Permissions.hasScreenRecording))")
            if !Permissions.hasScreenRecording {
                warnings.append("Screen Recording permission is needed to hear other participants. Enable Polly in System Settings → Privacy & Security → Screen & System Audio Recording, then restart Polly.")
            } else {
                warnings.append("Couldn't capture meeting audio: \(error.localizedDescription)")
            }
        }

        // The local user (microphone).
        if micAllowed {
            do {
                let prepared = try await TranscriptionEngineFactory.makePreparedEngine(preference: configuration.engine, locale: configuration.locale)
                let engine = prepared.engine
                engineName = engineName ?? engine.name
                noteFallback(prepared.fallbackNote)
                watchFailures(of: engine, speaker: .me)
                let pipeline = ChannelPipeline(speaker: .me, engine: engine, startDate: startDate)
                try await pipeline.start(onUpdate: makeUpdateHandler())

                let capture = MicrophoneCapture()
                capture.onBuffer = { @Sendable [weak pipeline] buffer in pipeline?.ingest(buffer) }
                try capture.start()
                microphone = capture
                pipelines[.me] = pipeline
                PollyLog.info("Microphone capture started")
            } catch {
                PollyLog.info("Microphone channel failed: \(error.localizedDescription)")
                warnings.append("Couldn't capture the microphone: \(error.localizedDescription)")
            }
        }

        if pipelines.isEmpty {
            throw NSError(domain: "Polly", code: 1, userInfo: [
                NSLocalizedDescriptionKey: warnings.last ?? "No audio source could be started.",
            ])
        }
    }

    private func noteFallback(_ note: String?) {
        guard let note, !warnings.contains(note) else { return }
        warnings.append(note)
    }

    private func watchFailures(of engine: SpeechTranscriptionEngine, speaker: Speaker) {
        engine.onFailure = { [weak self] message in
            PollyLog.info("Engine failure (\(speaker.rawValue)): \(message)")
            Task { @MainActor in
                guard let self, self.isActive else { return }
                let warning = "\(speaker == .me ? "Your microphone" : "Meeting audio"): \(message)"
                if !self.warnings.contains(warning) { self.warnings.append(warning) }
            }
        }
    }

    private func makeUpdateHandler() -> @Sendable (TranscriptionUpdate) -> Void {
        { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
    }

    private func apply(_ update: TranscriptionUpdate) {
        guard isActive || state == .stopping else { return }
        resultCounts[update.speaker, default: 0] += 1
        lastResultAt[update.speaker] = Date()
        // Measure on in-progress results (what you see first), and only for
        // engines whose results carry real audio timings.
        if !update.isFinal, !update.text.isEmpty, state == .recording,
           pipelines[update.speaker]?.engine.reportsAccurateTiming == true {
            latency.record(speaker: update.speaker, resultEnd: update.end,
                           now: Date().timeIntervalSince(meeting.startedAt))
        }
        builder.apply(update)
        segments = builder.displaySegments
        liveText = builder.liveText
    }

    private func systemAudioStopped(_ error: Error) {
        guard state == .recording else { return }
        // The microphone channel keeps going; the user can stop and restart if needed.
        warnings.append("Meeting audio capture stopped: \(error.localizedDescription)")
    }

    private func startTimers() {
        // Level meters.
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                var levels: [Speaker: Float] = [:]
                for (speaker, pipeline) in self.pipelines { levels[speaker] = pipeline.level }
                self.levels = levels
            }
        })
        // Diagnostics every 15 s, and a watchdog for a channel that hears
        // audio but produces no text.
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.checkHealth()
            }
        })
        // Autosave so a crash never loses a meeting.
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.autosave()
            }
        })
        // Warn if the meeting app has been completely silent for a while.
        timers.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self, self.state == .recording,
                  let others = self.pipelines[.others], others.peakLevelSinceStart < 0.0005,
                  self.configuration.target != .allSystemAudio
            else { return }
            self.warnings.append("No audio has been heard from the meeting app yet. If others are talking, switch Capture to \"All system audio\" in Settings.")
        })
    }

    private func checkHealth() {
        guard state == .recording else { return }
        let elapsed = Date().timeIntervalSince(meeting.startedAt)
        for (speaker, pipeline) in pipelines {
            let lag = latency.smoothed[speaker].map { String(format: "%.2fs", $0) } ?? "n/a"
            PollyLog.info("Channel \(speaker.rawValue): engine=\(pipeline.engine.name) buffers=\(pipeline.buffersReceived) audioFed=\(String(format: "%.1f", pipeline.secondsFed))s of \(String(format: "%.1f", elapsed))s results=\(resultCounts[speaker] ?? 0) peakLevel=\(String(format: "%.4f", pipeline.peakLevelSinceStart)) lag=\(lag)")

            // Sound has been heard but nothing transcribed for 30 s.
            let lastText = lastResultAt[speaker] ?? meeting.startedAt
            if pipeline.peakLevelSinceStart > 0.01, Date().timeIntervalSince(lastText) > 30,
               elapsed > 30, !warnedSilentEngine.contains(speaker) {
                warnedSilentEngine.insert(speaker)
                let channel = speaker == .me ? "your microphone" : "the meeting audio"
                warnings.append("Polly hears \(channel) but \(pipeline.engine.name) hasn't produced any text for 30 seconds. Try stopping and starting again; if it keeps happening, use Settings → Transcription → Show Diagnostics Log and send the log.")
                PollyLog.info("Watchdog: no results from \(speaker.rawValue) for 30s despite audio")
            }
            if pipeline.buffersReceived == 0, elapsed > 20, !warnedSilentEngine.contains(speaker) {
                warnedSilentEngine.insert(speaker)
                warnings.append(speaker == .me
                    ? "No audio is arriving from your microphone. Check System Settings → Privacy & Security → Microphone."
                    : "No audio is arriving from the meeting app. Check Screen & System Audio Recording permission, then restart Polly.")
                PollyLog.info("Watchdog: no buffers from \(speaker.rawValue) after 20s")
            }
        }
    }

    private func autosave() {
        guard state == .recording, segments.count != lastSavedSegmentCount else { return }
        lastSavedSegmentCount = segments.count
        var snapshot = meeting
        snapshot.segments = builder.displaySegments
        try? store.save(snapshot)
    }

    // MARK: - Stop

    /// Stops capture, waits for final results and returns the saved meeting.
    func stop() async -> Meeting {
        guard isActive else { return meeting }
        state = .stopping
        PollyLog.info("Stopping recording after \(String(format: "%.0f", Date().timeIntervalSince(meeting.startedAt)))s; results: \(resultCounts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))")
        await tearDown()

        builder.flush()
        meeting.segments = builder.segments
        meeting.endedAt = Date()
        segments = meeting.segments
        liveText = [:]
        do {
            try store.save(meeting)
        } catch {
            warnings.append("Couldn't save the transcript: \(error.localizedDescription)")
        }
        state = .finished
        return meeting
    }

    private func tearDown() async {
        timers.forEach { $0.cancel() }
        timers.removeAll()
        microphone?.stop()
        microphone = nil
        await systemAudio?.stop()
        systemAudio = nil
        for pipeline in pipelines.values { await pipeline.finish() }
        // Let the final results hop to the main actor before we flush.
        try? await Task.sleep(nanoseconds: 200_000_000)
        pipelines.removeAll()
        levels = [:]
        othersAudioURL = othersRecorder?.finish()
        othersRecorder = nil
    }

    /// Applies the matching calendar event: invitees, and its title unless
    /// the meeting already has a better one.
    func setCalendarEvent(_ event: CalendarEvent) {
        meeting.attendees = event.participantNames
        if meeting.hasDefaultTitle, let title = event.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            meeting.title = title
            meeting.hasDefaultTitle = false
        }
    }

    func rename(_ title: String) {
        meeting.title = title
        meeting.hasDefaultTitle = false
    }
}
