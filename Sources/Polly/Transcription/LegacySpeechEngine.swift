import AVFoundation
import Speech

/// On-device transcription with SFSpeechRecognizer, for macOS 14/15.
///
/// SFSpeechRecognizer is designed for short utterances, so the audio is split
/// into consecutive recognition requests: a new request starts whenever the
/// speaker pauses (the partial result stops changing) or after `maxRequestDuration`.
/// Each request's timestamps are offset by the audio already fed.
final class LegacySpeechEngine: SpeechTranscriptionEngine {
    let name = "SFSpeechRecognizer"
    let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private static let pauseToRotate: TimeInterval = 1.2
    private static let maxRequestDuration: TimeInterval = 45

    private struct Partial {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    private let lock = NSLock()
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

    func prepare(locale: Locale) async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.speechPermissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw TranscriptionError.unsupportedLocale(locale) }
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.onDeviceUnavailable(locale) }
        self.recognizer = recognizer
    }

    func start(onResult: @escaping EngineResultHandler) async throws {
        guard recognizer != nil else { throw TranscriptionError.notPrepared }
        lock.lock()
        self.onResult = onResult
        beginRequestLocked()
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.rotateIfNeeded() }
        timer.resume()
        self.timer = timer
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        framesFed += Int64(buffer.frameLength)
        lock.unlock()
    }

    func finish() async {
        timer?.cancel()
        timer = nil
        lock.lock()
        request?.endAudio()
        request = nil
        let hasPending = !tasks.isEmpty
        lock.unlock()

        // Give outstanding requests a moment to deliver their final results.
        if hasPending {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                lock.lock()
                let done = tasks.isEmpty
                lock.unlock()
                if done { break }
            }
        }
        lock.lock()
        let leftovers = partials.values.sorted { $0.start < $1.start }
        partials.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        let handler = onResult
        lock.unlock()
        for partial in leftovers where !partial.text.isEmpty {
            handler?(partial.text, true, partial.start, partial.end)
        }
    }

    // MARK: - Private

    /// Must be called with `lock` held.
    private func beginRequestLocked() {
        guard let recognizer else { return }
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
            self?.handle(result: result, error: error, requestID: id, offset: offset)
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, requestID: Int, offset: TimeInterval) {
        lock.lock()
        let handler = onResult
        let isCurrent = requestID == generation && request != nil

        if let result {
            let text = result.bestTranscription.formattedString
            let segments = result.bestTranscription.segments
            let start = offset + (segments.first?.timestamp ?? 0)
            let end = offset + (segments.last.map { $0.timestamp + $0.duration } ?? 0)

            if result.isFinal {
                partials[requestID] = nil
                tasks[requestID] = nil
                lock.unlock()
                handler?(text, true, start, max(start, end))
                return
            }
            if partials[requestID]?.text != text {
                partials[requestID] = Partial(text: text, start: start, end: max(start, end))
                if isCurrent { lastPartialChange = Date() }
            }
            lock.unlock()
            if isCurrent { handler?(text, false, start, max(start, end)) }
            return
        }

        // Ended without a final result (e.g. "no speech detected" or cancellation):
        // commit whatever partial text the request produced.
        let leftover = partials.removeValue(forKey: requestID)
        if error != nil { tasks[requestID] = nil }
        lock.unlock()
        if let leftover, !leftover.text.isEmpty {
            handler?(leftover.text, true, leftover.start, leftover.end)
        }
    }

    private func rotateIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard let request else { return }
        let hasSpeech = !(partials[generation]?.text.isEmpty ?? true)
        let paused = hasSpeech && Date().timeIntervalSince(lastPartialChange) > Self.pauseToRotate
        let tooLong = Date().timeIntervalSince(requestStartedAt) > Self.maxRequestDuration
        guard paused || tooLong else { return }

        request.endAudio() // the old task will deliver its final result asynchronously
        beginRequestLocked()
    }
}
