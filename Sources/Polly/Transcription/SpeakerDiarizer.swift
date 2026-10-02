import FluidAudio
import Foundation
import PollyCore

/// Separates the remote participants' voices after a meeting, on device,
/// with FluidAudio's offline pyannote pipeline (segmentation + WeSpeaker
/// embeddings + VBx clustering). Models (~tens of MB) are downloaded from
/// Hugging Face on first use and cached.
enum SpeakerDiarization {
    /// macOS 14 has an Apple Core ML (BNNS) bug that can crash this pipeline
    /// (FluidAudio issue #878, fixed in macOS 15), so it is only offered on 15+.
    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    struct Output: Sendable {
        var turns: [DiarizedTurn]
        /// Mean voice embedding per diarizer speaker label.
        var embeddings: [String: [Float]]
    }

    /// Returns voice turns and per-voice embeddings for the audio file. `progress` reports 0…1.
    static func diarize(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        guard #available(macOS 15.0, *) else { return Output(turns: [], embeddings: [:]) }
        return try await DiarizerHolder.shared.diarize(fileURL: fileURL, progress: progress)
    }
}

@available(macOS 15.0, *)
private actor DiarizerHolder {
    static let shared = DiarizerHolder()
    private var manager: OfflineDiarizerManager?

    func diarize(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerDiarization.Output {
        let manager: OfflineDiarizerManager
        if let existing = self.manager {
            manager = existing
        } else {
            manager = OfflineDiarizerManager(config: .default)
            try await manager.prepareModels() // downloads + compiles Core ML models on first use
            self.manager = manager
        }
        let result = try await manager.process(fileURL) { done, total in
            progress(total > 0 ? Double(done) / Double(total) : 0)
        }
        let turns = result.segments.map {
            DiarizedTurn(
                speakerID: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
        // The offline pipeline provides a mean embedding per speaker; fall
        // back to averaging segment embeddings if it doesn't.
        var embeddings = result.speakerDatabase ?? [:]
        if embeddings.isEmpty {
            var sums: [String: [Float]] = [:]
            for segment in result.segments where !segment.embedding.isEmpty {
                if var sum = sums[segment.speakerId], sum.count == segment.embedding.count {
                    for i in sum.indices { sum[i] += segment.embedding[i] }
                    sums[segment.speakerId] = sum
                } else if sums[segment.speakerId] == nil {
                    sums[segment.speakerId] = segment.embedding
                }
            }
            embeddings = sums
        }
        return SpeakerDiarization.Output(turns: turns, embeddings: embeddings)
    }
}
