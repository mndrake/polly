import AVFoundation
import PollyCore

enum TranscriptionError: LocalizedError {
    case unsupportedLocale(Locale)
    case onDeviceUnavailable(Locale)
    case speechPermissionDenied
    case modelUnavailable
    case audioFormat(String)
    case notPrepared

    var errorDescription: String? {
        switch self {
        case let .unsupportedLocale(locale):
            return "On-device transcription doesn't support \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)."
        case let .onDeviceUnavailable(locale):
            return "On-device speech recognition for \(locale.identifier) isn't installed. Download it in System Settings → Keyboard → Dictation, or pick another language."
        case .speechPermissionDenied:
            return "Speech recognition permission is required. Enable Polly in System Settings → Privacy & Security → Speech Recognition."
        case .modelUnavailable:
            return "The speech model couldn't be loaded."
        case let .audioFormat(detail):
            return detail
        case .notPrepared:
            return "The transcription engine wasn't prepared."
        }
    }
}

/// Text, finality and the time range (seconds from when audio feeding began).
typealias EngineResultHandler = @Sendable (_ text: String, _ isFinal: Bool, _ start: TimeInterval, _ end: TimeInterval) -> Void

/// A streaming, on-device speech-to-text engine for a single audio channel.
protocol SpeechTranscriptionEngine: AnyObject {
    var name: String { get }
    /// Whether in-progress results carry real audio time ranges (used for the lag readout).
    var reportsAccurateTiming: Bool { get }
    /// Called (on any thread) if the engine stops working mid-recording.
    var onFailure: ((String) -> Void)? { get set }
    /// Format buffers must be in when passed to `append`. Valid after `prepare`.
    var audioFormat: AVAudioFormat { get }
    /// Loads models / checks permissions. May download assets.
    func prepare(locale: Locale) async throws
    func start(onResult: @escaping EngineResultHandler) async throws
    /// Thread-safe. Buffers must be contiguous in time (pad gaps with silence).
    func append(_ buffer: AVAudioPCMBuffer)
    /// Flushes pending audio and delivers final results.
    func finish() async
}

enum EnginePreference: String, CaseIterable, Identifiable {
    case automatic
    case legacy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic (SpeechAnalyzer on macOS 26+)"
        case .legacy: return "SFSpeechRecognizer (on-device)"
        }
    }
}

enum TranscriptionEngineFactory {
    struct Prepared {
        let engine: SpeechTranscriptionEngine
        /// Set when Polly had to fall back from its preferred engine, with the reason.
        let fallbackNote: String?
    }

    /// Creates and prepares an engine: SpeechAnalyzer with low-latency results,
    /// then SpeechAnalyzer without them, then SFSpeechRecognizer.
    static func makePreparedEngine(preference: EnginePreference, locale: Locale) async throws -> Prepared {
        var failures: [String] = []
        #if compiler(>=6.2)
        if preference == .automatic, #available(macOS 26.0, *) {
            for lowLatency in [true, false] {
                let engine = SpeechAnalyzerEngine(lowLatency: lowLatency)
                do {
                    try await engine.prepare(locale: locale)
                    PollyLog.info("Using SpeechAnalyzer (lowLatency: \(lowLatency), format: \(engine.audioFormat))")
                    let note = failures.isEmpty ? nil : "Low-latency mode is unavailable; using standard SpeechAnalyzer."
                    return Prepared(engine: engine, fallbackNote: note)
                } catch {
                    PollyLog.info("SpeechAnalyzer (lowLatency: \(lowLatency)) failed to prepare: \(error.localizedDescription)")
                    failures.append(error.localizedDescription)
                }
            }
        }
        #endif
        let engine = LegacySpeechEngine()
        try await engine.prepare(locale: locale)
        PollyLog.info("Using SFSpeechRecognizer")
        let note = failures.isEmpty ? nil
            : "Apple's SpeechAnalyzer couldn't start (\(failures.last ?? "unknown error")), so Polly is using the older recognizer."
        return Prepared(engine: engine, fallbackNote: note)
    }
}

/// Glues one capture source to one engine: converts formats, keeps the
/// engine's clock aligned with wall-clock time, and tags results with a speaker.
final class ChannelPipeline {
    let speaker: Speaker
    let engine: SpeechTranscriptionEngine
    private let converter: AudioFormatConverter
    private var aligner: TimelineAligner
    private let startDate: Date
    private let lock = NSLock()
    private var stopped = false

    /// Receives exactly the audio fed to the engine (including silence
    /// padding), so a recording of it shares the transcript's timeline.
    var tap: ((AVAudioPCMBuffer) -> Void)?

    /// Latest input level (0…1), read from the main thread for meters.
    private(set) var level: Float = 0
    private(set) var peakLevelSinceStart: Float = 0
    /// Diagnostics: buffers received from capture and audio seconds fed to the engine.
    private(set) var buffersReceived = 0
    private(set) var secondsFed: Double = 0

    init(speaker: Speaker, engine: SpeechTranscriptionEngine, startDate: Date) {
        self.speaker = speaker
        self.engine = engine
        self.startDate = startDate
        converter = AudioFormatConverter(outputFormat: engine.audioFormat)
        aligner = TimelineAligner(sampleRate: engine.audioFormat.sampleRate)
    }

    func start(onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws {
        let speaker = self.speaker
        try await engine.start { text, isFinal, start, end in
            onUpdate(TranscriptionUpdate(speaker: speaker, text: text, isFinal: isFinal, start: start, end: end))
        }
    }

    /// Called from the capture source's thread.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }

        buffersReceived += 1
        let rms = buffer.rmsLevel
        level = rms
        peakLevelSinceStart = max(peakLevelSinceStart, rms)

        do {
            guard let converted = try converter.convert(buffer) else { return }
            // The buffer just captured ends "now"; it started `duration` ago.
            let bufferStart = Date().timeIntervalSince(startDate) - buffer.duration
            let padding = aligner.silenceFrames(beforeBufferAt: bufferStart)
            if padding > 0, let silence = AVAudioPCMBuffer.silence(format: engine.audioFormat, frames: AVAudioFrameCount(padding)) {
                engine.append(silence)
                tap?(silence)
            }
            engine.append(converted)
            tap?(converted)
            aligner.didFeed(frames: Int(converted.frameLength))
            secondsFed = aligner.fedDuration
        } catch {
            PollyLog.info("Dropping \(speaker) audio buffer: \(error.localizedDescription)")
        }
    }

    /// Stops feeding audio and waits (at most `timeout`) for final results,
    /// so a stuck recognizer can never hang Stop.
    func finish(timeout: TimeInterval = 10) async {
        lock.withLock { stopped = true }
        let engine = self.engine
        let speaker = self.speaker
        let once = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await engine.finish()
                if once.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.claim() {
                    PollyLog.info("\(engine.name) (\(speaker.rawValue)) didn't finish within \(Int(timeout))s; continuing without its last results")
                    continuation.resume()
                }
            }
        }
    }
}

/// Lets exactly one of several racing callers proceed.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
