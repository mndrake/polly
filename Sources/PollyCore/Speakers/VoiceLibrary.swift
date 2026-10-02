import Foundation

/// A separated voice's fingerprint within one meeting.
public struct SpeakerVoice: Codable, Sendable, Equatable {
    /// Speaker embedding (e.g. 256-d WeSpeaker), L2-normalized.
    public var embedding: [Float]
    /// Seconds of speech the embedding was computed from.
    public var seconds: Double

    public init(embedding: [Float], seconds: Double) {
        self.embedding = VectorMath.normalized(embedding)
        self.seconds = seconds
    }
}

/// One example of a person's voice, from a meeting where the user named them.
public struct VoiceSample: Codable, Sendable, Equatable {
    public var meetingID: UUID
    public var speakerID: String
    public var voice: SpeakerVoice
    public var recordedAt: Date

    public init(meetingID: UUID, speakerID: String, voice: SpeakerVoice, recordedAt: Date = Date()) {
        self.meetingID = meetingID
        self.speakerID = speakerID
        self.voice = voice
        self.recordedAt = recordedAt
    }
}

/// A person Polly can recognize by voice.
public struct VoiceProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var samples: [VoiceSample]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, samples: [VoiceSample] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.samples = samples
        self.createdAt = createdAt
    }

    /// Duration-weighted mean of the samples, normalized.
    public var centroid: [Float] {
        guard let dimension = samples.first?.voice.embedding.count else { return [] }
        var sum = [Float](repeating: 0, count: dimension)
        for sample in samples where sample.voice.embedding.count == dimension {
            let weight = Float(max(sample.voice.seconds, 1))
            for i in 0..<dimension { sum[i] += sample.voice.embedding[i] * weight }
        }
        return VectorMath.normalized(sum)
    }

    public var meetingCount: Int { Set(samples.map(\.meetingID)).count }
    public var lastHeard: Date? { samples.map(\.recordedAt).max() }
}

/// A voice in a meeting recognized as a known person.
public struct VoiceMatch: Codable, Sendable, Equatable {
    public var profileID: UUID
    public var name: String
    /// Cosine similarity, -1…1.
    public var similarity: Float

    public init(profileID: UUID, name: String, similarity: Float) {
        self.profileID = profileID
        self.name = name
        self.similarity = similarity
    }
}

/// The people Polly has learned to recognize, and the matching rules.
///
/// Profiles only learn from voices the user explicitly named or confirmed, so
/// a wrong guess by Claude never teaches Polly the wrong voice. Samples are
/// keyed by (meeting, speaker), so renaming a speaker moves its sample to the
/// right person instead of polluting the old one.
public struct VoiceLibrary: Codable, Sendable, Equatable {
    /// Minimum cosine similarity to recognize someone. WeSpeaker embeddings of
    /// the same person across calls typically score well above this; different
    /// people rarely do. Tuned conservatively: a missed match just means the
    /// user names the person once more.
    public static let matchThreshold: Float = 0.55
    /// The best match must beat the runner-up by this much.
    public static let matchMargin: Float = 0.06
    /// Voices with less speech than this are too unreliable to learn or match.
    public static let minimumSeconds: Double = 6
    /// Most recent samples kept per person.
    public static let maxSamplesPerProfile = 20

    public private(set) var profiles: [VoiceProfile]

    public init(profiles: [VoiceProfile] = []) {
        self.profiles = profiles
    }

    /// Recognizes the meeting's voices. Each person matches at most one voice
    /// and each voice at most one person (best similarities first).
    public func match(_ voices: [String: SpeakerVoice]) -> [String: VoiceMatch] {
        let centroids = profiles.map { ($0, $0.centroid) }.filter { !$0.1.isEmpty }
        guard !centroids.isEmpty else { return [:] }

        struct Candidate { let speakerID: String; let profile: VoiceProfile; let similarity: Float }
        var candidates: [Candidate] = []
        for (speakerID, voice) in voices where voice.seconds >= Self.minimumSeconds {
            let scored = centroids
                .filter { $0.1.count == voice.embedding.count }
                .map { (profile: $0.0, similarity: VectorMath.cosine(voice.embedding, $0.1)) }
                .sorted { $0.similarity > $1.similarity }
            guard let best = scored.first, best.similarity >= Self.matchThreshold else { continue }
            if scored.count > 1, best.similarity - scored[1].similarity < Self.matchMargin { continue }
            candidates.append(Candidate(speakerID: speakerID, profile: best.profile, similarity: best.similarity))
        }

        var result: [String: VoiceMatch] = [:]
        var usedProfiles: Set<UUID> = []
        for candidate in candidates.sorted(by: { $0.similarity > $1.similarity })
        where !usedProfiles.contains(candidate.profile.id) {
            usedProfiles.insert(candidate.profile.id)
            result[candidate.speakerID] = VoiceMatch(profileID: candidate.profile.id, name: candidate.profile.name, similarity: candidate.similarity)
        }
        return result
    }

    /// Records that `speakerID` in `meetingID` is `name`. Returns false if the
    /// voice has too little speech to learn from.
    @discardableResult
    public mutating func learn(name: String, meetingID: UUID, speakerID: String, voice: SpeakerVoice, at date: Date = Date()) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        forget(meetingID: meetingID, speakerID: speakerID)
        guard !trimmed.isEmpty, voice.seconds >= Self.minimumSeconds, !voice.embedding.isEmpty else { return false }

        let sample = VoiceSample(meetingID: meetingID, speakerID: speakerID, voice: voice, recordedAt: date)
        if let index = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            profiles[index].samples.append(sample)
            profiles[index].samples.sort { $0.recordedAt < $1.recordedAt }
            if profiles[index].samples.count > Self.maxSamplesPerProfile {
                profiles[index].samples.removeFirst(profiles[index].samples.count - Self.maxSamplesPerProfile)
            }
        } else {
            profiles.append(VoiceProfile(name: trimmed, samples: [sample], createdAt: date))
        }
        return true
    }

    /// Removes what was learned from one voice in one meeting.
    public mutating func forget(meetingID: UUID, speakerID: String) {
        for index in profiles.indices {
            profiles[index].samples.removeAll { $0.meetingID == meetingID && $0.speakerID == speakerID }
        }
        profiles.removeAll { $0.samples.isEmpty }
    }

    /// Removes everything learned from a meeting (e.g. when it's deleted).
    public mutating func forget(meetingID: UUID) {
        for index in profiles.indices {
            profiles[index].samples.removeAll { $0.meetingID == meetingID }
        }
        profiles.removeAll { $0.samples.isEmpty }
    }

    public mutating func remove(profileID: UUID) {
        profiles.removeAll { $0.id == profileID }
    }

    /// Renames a person; merges into an existing person with that name.
    public mutating func rename(profileID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        if let other = profiles.firstIndex(where: { $0.id != profileID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            profiles[other].samples += profiles[index].samples
            profiles[other].samples.sort { $0.recordedAt < $1.recordedAt }
            profiles[other].samples = Array(profiles[other].samples.suffix(Self.maxSamplesPerProfile))
            profiles.remove(at: index)
        } else {
            profiles[index].name = trimmed
        }
    }

    public mutating func removeAll() {
        profiles = []
    }
}

/// Persists the voice library as JSON.
public final class VoiceLibraryStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        MeetingStore.defaultDirectory().deletingLastPathComponent().appendingPathComponent("Voices.json")
    }

    public func load() -> VoiceLibrary {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return VoiceLibrary() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(VoiceLibrary.self, from: data)) ?? VoiceLibrary()
    }

    public func save(_ library: VoiceLibrary) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(library)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func delete() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

enum VectorMath {
    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
