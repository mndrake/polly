#if compiler(>=6.2)
import AVFoundation
import CoreMedia
import Speech

/// Long-form, on-device transcription with Apple's SpeechAnalyzer (macOS 26+).
@available(macOS 26.0, *)
final class SpeechAnalyzerEngine: SpeechTranscriptionEngine {
    let name = "SpeechAnalyzer"

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private(set) var audioFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    func prepare(locale: Locale) async throws {
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale)
        }
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        // Downloads the language model the first time (managed by the OS).
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.modelUnavailable
        }
        audioFormat = format
        self.transcriber = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func start(onResult: @escaping EngineResultHandler) async throws {
        guard let transcriber, let analyzer else { throw TranscriptionError.notPrepared }

        let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let range = result.range
                    let start = range.start.isNumeric ? range.start.seconds : 0
                    let end = range.end.isNumeric ? range.end.seconds : start
                    onResult(text, result.isFinal, start, end)
                }
            } catch {
                NSLog("Polly: SpeechTranscriber results ended with error: \(error.localizedDescription)")
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            NSLog("Polly: SpeechAnalyzer finalize failed: \(error.localizedDescription)")
        }
        await resultsTask?.value
        resultsTask = nil
    }
}
#endif
