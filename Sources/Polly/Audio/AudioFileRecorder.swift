import AVFoundation

/// Writes one channel's audio to a temporary file for speaker separation
/// after the meeting. The file is deleted once it has been processed.
final class AudioFileRecorder {
    let url: URL
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var failed = false

    init(url: URL, format: AVAudioFormat) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    /// Called from the capture thread.
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, !failed else { return }
        do {
            try file.write(from: buffer)
        } catch {
            failed = true
            NSLog("Polly: stopped writing speaker-separation audio: \(error.localizedDescription)")
        }
    }

    /// Closes the file. Returns its URL if it contains usable audio.
    func finish() -> URL? {
        lock.lock()
        let length = file?.length ?? 0
        file = nil // AVAudioFile closes on deinit
        let ok = !failed && length > 0
        lock.unlock()
        if !ok { Self.delete(url) }
        return ok ? url : nil
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Folder for in-progress recordings; anything left here after a crash is removed at launch.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Polly/PendingAudio", isDirectory: true)
    }

    static func removeLeftovers(except keep: Set<URL> = []) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file) { delete(file) }
    }
}
