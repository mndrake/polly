import AppKit
import Foundation

/// A small diagnostics log at ~/Library/Logs/Polly/Polly.log (also sent to
/// the system log). Records what the capture and transcription pipeline is
/// doing — never transcript text — so problems on a user's Mac can be diagnosed.
enum PollyLog {
    private static let queue = DispatchQueue(label: "app.polly.log")
    private static let maxBytes = 2_000_000

    static var fileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Polly/Polly.log")
    }

    static func info(_ message: String) {
        NSLog("Polly: %@", message)
        let line = "\(timestamp()) \(message)\n"
        queue.async {
            let url = fileURL
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep one previous file when rotating.
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    static func reveal() {
        info("Diagnostics log opened from Polly")
        queue.async {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
