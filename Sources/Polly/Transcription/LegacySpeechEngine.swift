import AVFoundation
import Speech

/// On-device transcription with SFSpeechRecognizer, for macOS 14/15 and as a
/// fallback when SpeechAnalyzer can't start.
///
/// SFSpeechRecognizer is designed for short utterances, so the audio is split
/// into consecutive recognition requests: a new request starts whenever the
/// speaker pauses (the partial result stops changing) or after `maxRequestDuration`.
///
/// All state lives on one serial queue. Nothing here ever blocks while calling
/// into Speech: the framework may deliver results synchronously from inside
/// `endAudio()`/`recognitionTask(...)`, so holding a lock across those calls
/// can deadlock (and then stall the capture threads that feed `append`).
final class LegacySpeechEngine: SpeechTranscriptionEngine {
    let name = "SFSpeechRecognizer"
    let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// Partial results don't carry reliable word timings.
    let reportsAccurateTiming = false
    var onFailure: ((String) -> Void)?

    private static let pauseToRotate: TimeInterval = 1.2
    private static let maxRequestDuration: TimeInterval = 45

    private struct Partial {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    private let queue = DispatchQueue(label: "app.polly.sfspeech")
    // Everything below is only touched on `queue`.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [Int: SFSpeechRecognitionTask] = [:]
    private var generation = 0
    private var framesFed: Int64 = 0
    private var requestStartedAt = Date()
    private var lastPartialChange = Date()
    /// Latest partial per request, emitted as final if a request ends without a final result.
    private var partials: [Int: Partial] = [:]
    private var onResult: EngineResultHandler?
    private var timer: DispatchSourceTimer?
    private var finished = false

    func prepare(locale: Locale) async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.speechPermissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw TranscriptionError.unsupportedLocale(locale) }
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.onDeviceUnavailable(locale) }
        queue.sync { self.recognizer = recognizer }
    }

    func start(onResult: @escaping EngineResultHandler) async throws {
        try queue.sync {
            guard recognizer != nil else { throw TranscriptionError.notPrepared }
            self.onResult = onResult
            beginRequest()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.rotateIfNeeded() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Called from capture threads; never blocks.
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async {
            guard !self.finished else { return }
            self.request?.append(buffer)
            self.framesFed += Int64(buffer.frameLength)
        }
    }

    func finish() async {
        let hasPending: Bool = await onQueue {
            self.timer?.cancel()
            self.timer = nil
            self.finished = true
            self.request?.endAudio()
            self.request = nil
            return !self.tasks.isEmpty
        }
        // Give outstanding requests a moment to deliver their final results.
        if hasPending {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if await onQueue({ self.tasks.isEmpty }) { break }
            }
        }
        await onQueue {
            let leftovers = self.partials.values.sorted { $0.start < $1.start }
            self.partials.removeAll()
            self.tasks.values.forEach { $0.cancel() }
            self.tasks.removeAll()
            for partial in leftovers where !partial.text.isEmpty {
                self.onResult?(partial.text, true, partial.start, partial.end)
            }
        }
    }

    // MARK: - Private (on `queue`)

    private func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func beginRequest() {
        guard let recognizer, !finished else { return }
        generation += 1
        let id = generation
        let offset = Double(framesFed) / audioFormat.sampleRate

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        self.request = request
        requestStartedAt = Date()
        lastPartialChange = Date()

        tasks[id] = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Hop to our queue; never handle inline (may be called re-entrantly).
            self?.queue.async { self?.handle(result: result, error: error, requestID: id, offset: offset) }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, requestID: Int, offset: TimeInterval) {
        let isCurrent = requestID == generation && request != nil
        // Partial results have no word timings; use the audio fed so far.
        let audioNow = Double(framesFed) / audioFormat.sampleRate

        if let result {
            let text = result.bestTranscription.formattedString
            let segments = result.bestTranscription.segments
            let start = offset + (segments.first?.timestamp ?? 0)
            let timedEnd = offset + (segments.last.map { $0.timestamp + $0.duration } ?? 0)

            if result.isFinal {
                partials[requestID] = nil
                tasks[requestID] = nil
                onResult?(text, true, start, max(start, timedEnd))
                return
            }
            let end = max(start, audioNow)
            if partials[requestID]?.text != text {
                partials[requestID] = Partial(text: text, start: start, end: end)
                if isCurrent { lastPartialChange = Date() }
            }
            if isCurrent { onResult?(text, false, start, end) }
            return
        }

        // Ended without a final result: commit whatever partial text the request produced.
        if let error {
            tasks[requestID] = nil
            let code = (error as NSError).code
            // 1110 = no speech detected, 301/216 = request cancelled: expected when rotating.
            if ![1110, 301, 216].contains(code) {
                onFailure?("SFSpeechRecognizer error \(code): \(error.localizedDescription)")
            }
        }
        if let leftover = partials.removeValue(forKey: requestID), !leftover.text.isEmpty {
            onResult?(leftover.text, true, leftover.start, leftover.end)
        }
    }

    private func rotateIfNeeded() {
        guard let request, !finished else { return }
        let hasSpeech = !(partials[generation]?.text.isEmpty ?? true)
        let paused = hasSpeech && Date().timeIntervalSince(lastPartialChange) > Self.pauseToRotate
        let tooLong = Date().timeIntervalSince(requestStartedAt) > Self.maxRequestDuration
        guard paused || tooLong else { return }

        request.endAudio() // the old task delivers its final result asynchronously
        beginRequest()
    }
}
