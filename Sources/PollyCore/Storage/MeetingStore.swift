import Foundation

/// Persists meetings as one JSON file each.
public final class MeetingStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// `~/Library/Application Support/Polly/Meetings` on macOS.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".polly")
        return base.appendingPathComponent("Polly", isDirectory: true).appendingPathComponent("Meetings", isDirectory: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ meeting: Meeting) throws {
        let data = try encoder.encode(meeting)
        lock.lock(); defer { lock.unlock() }
        try data.write(to: url(for: meeting.id), options: .atomic)
    }

    public func load(id: UUID) throws -> Meeting {
        lock.lock(); defer { lock.unlock() }
        return try decoder.decode(Meeting.self, from: Data(contentsOf: url(for: id)))
    }

    /// All readable meetings, newest first. Unreadable files are skipped.
    public func loadAll() -> [Meeting] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let target = url(for: id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}
