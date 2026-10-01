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
    /// Creates and prepares an engine, falling back to SFSpeechRecognizer if
    /// SpeechAnalyzer is unavailable or doesn't support the locale.
    static func makePreparedEngine(preference: EnginePreference, locale: Locale) async throws -> SpeechTranscriptionEngine {
        #if compiler(>=6.2)
        if preference == .automatic, #available(macOS 26.0, *) {
            let engine = SpeechAnalyzerEngine()
            do {
                try await engine.prepare(locale: locale)
                return engine
            } catch {
                NSLog("Polly: SpeechAnalyzer unavailable (\(error.localizedDescription)); falling back to SFSpeechRecognizer")
            }
        }
        #endif
        let engine = LegacySpeechEngine()
        try await engine.prepare(locale: locale)
        return engine
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

    /// Latest input level (0…1), read from the main thread for meters.
    private(set) var level: Float = 0
    private(set) var peakLevelSinceStart: Float = 0

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
            }
            engine.append(converted)
            aligner.didFeed(frames: Int(converted.frameLength))
        } catch {
            NSLog("Polly: dropping \(speaker) audio buffer: \(error.localizedDescription)")
        }
    }

    func finish() async {
        lock.withLock { stopped = true }
        await engine.finish()
    }
}
