import AppKit
import CoreGraphics
import PollyCore

/// Polls running apps, window titles and microphone use, and runs them
/// through `MeetingDetector` to find meetings in progress.
@MainActor
final class MeetingMonitor: ObservableObject {
    @Published private(set) var detected: [DetectedMeeting] = []

    /// A meeting that wasn't detected on the previous poll.
    var onNewMeeting: ((DetectedMeeting) -> Void)?
    /// A high-confidence meeting that has disappeared (window closed) for `endGracePeriod`.
    var onMeetingEnded: ((DetectedMeeting) -> Void)?

    /// True while Polly itself is recording; the mic-in-use signal is then ours, not the meeting's.
    var isRecording = false

    private static let pollInterval: UInt64 = 3_000_000_000
    private static let endGracePeriod: TimeInterval = 20

    private var task: Task<Void, Never>?
    private var lastSeen: [String: (meeting: DetectedMeeting, at: Date)] = [:]
    private var reportedEnded: Set<String> = []

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        detected = []
        lastSeen = [:]
    }

    private func poll() {
        let snapshot = Self.takeSnapshot(includeMicrophone: !isRecording)
        let current = MeetingDetector.detect(snapshot)
        let now = Date()

        for meeting in current {
            let previous = lastSeen[meeting.bundleID]
            if previous == nil {
                onNewMeeting?(meeting)
            }
            reportedEnded.remove(meeting.bundleID)
            lastSeen[meeting.bundleID] = (meeting, now)
        }

        let currentIDs = Set(current.map(\.bundleID))
        for (bundleID, entry) in lastSeen where !currentIDs.contains(bundleID) {
            // While recording, medium-confidence detections vanish because we
            // ignore the mic signal; only window-based meetings can "end".
            if entry.meeting.confidence == .high,
               now.timeIntervalSince(entry.at) > Self.endGracePeriod,
               !reportedEnded.contains(bundleID) {
                reportedEnded.insert(bundleID)
                onMeetingEnded?(entry.meeting)
                lastSeen[bundleID] = nil
            } else if entry.meeting.confidence == .medium, !isRecording,
                      now.timeIntervalSince(entry.at) > Self.endGracePeriod {
                lastSeen[bundleID] = nil
            }
        }

        if detected != current { detected = current }
    }

    static func takeSnapshot(includeMicrophone: Bool) -> SystemSnapshot {
        let apps = NSWorkspace.shared.runningApplications
        var bundleByPID: [pid_t: String] = [:]
        for app in apps {
            if let id = app.bundleIdentifier { bundleByPID[app.processIdentifier] = id }
        }

        var windows: [SystemSnapshot.Window] = []
        // Window titles are only visible with the Screen Recording permission.
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for window in info {
                guard (window[kCGWindowLayer as String] as? Int) == 0,
                      let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                      let bundleID = bundleByPID[pid],
                      let title = window[kCGWindowName as String] as? String,
                      !title.isEmpty
                else { continue }
                windows.append(.init(bundleID: bundleID, title: title))
            }
        }

        return SystemSnapshot(
            runningBundleIDs: Set(bundleByPID.values),
            windows: windows,
            microphoneInUse: includeMicrophone && MicrophoneCapture.isDefaultInputInUse()
        )
    }
}
