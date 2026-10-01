import Foundation

/// A snapshot of what's on the machine, gathered by the macOS app.
public struct SystemSnapshot: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var bundleID: String
        public var title: String

        public init(bundleID: String, title: String) {
            self.bundleID = bundleID
            self.title = title
        }
    }

    public var runningBundleIDs: Set<String>
    /// On-screen windows with non-empty titles (requires Screen Recording permission on macOS).
    public var windows: [Window]
    /// Whether some process is currently capturing from the default input device.
    public var microphoneInUse: Bool

    public init(runningBundleIDs: Set<String>, windows: [Window], microphoneInUse: Bool) {
        self.runningBundleIDs = runningBundleIDs
        self.windows = windows
        self.microphoneInUse = microphoneInUse
    }
}

public struct DetectedMeeting: Sendable, Equatable, Hashable {
    public enum Confidence: Int, Sendable, Comparable {
        /// A meeting app is running and the microphone is in use.
        case medium = 1
        /// A window title clearly identifies an in-progress meeting.
        case high = 2

        public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var platform: MeetingPlatform
    /// The application whose audio should be captured (native client or browser).
    public var bundleID: String
    /// The window title that triggered detection, if any.
    public var windowTitle: String?
    public var confidence: Confidence

    public init(platform: MeetingPlatform, bundleID: String, windowTitle: String?, confidence: Confidence) {
        self.platform = platform
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.confidence = confidence
    }

    /// A human-friendly meeting title derived from the window, if there is a useful one.
    public var suggestedTitle: String? {
        guard let title = windowTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        let generic: Set<String> = ["zoom meeting", "zoom webinar", "zoom", "microsoft teams"]
        if generic.contains(title.lowercased()) { return nil }
        var cleaned = title
        for suffix in [" | Microsoft Teams", " - Microsoft Teams", " – Microsoft Teams"] {
            if cleaned.hasSuffix(suffix) { cleaned = String(cleaned.dropLast(suffix.count)) }
        }
        // Browser titles often end with " - Google Chrome", " — Mozilla Firefox", etc.
        for separator in [" - ", " — ", " – "] {
            if let range = cleaned.range(of: separator, options: .backwards),
               KnownBrowserNames.all.contains(String(cleaned[range.upperBound...])) {
                cleaned = String(cleaned[..<range.lowerBound])
            }
        }
        // Bare Meet codes ("Meet - abc-defg-hij") aren't a meaningful title.
        if MeetingDetector.matchesMeetCode(cleaned) { return nil }
        return cleaned.isEmpty ? nil : cleaned
    }
}

enum KnownBrowserNames {
    static let all: Set<String> = [
        "Google Chrome", "Safari", "Microsoft Edge", "Mozilla Firefox", "Firefox",
        "Arc", "Brave", "Vivaldi", "Opera", "Chromium",
    ]
}

/// Pure rule engine: turns a `SystemSnapshot` into detected meetings.
///
/// Rules (highest confidence wins per app):
/// * Zoom: a window titled "Zoom Meeting"/"Zoom Webinar" → high.
/// * Teams: a window whose title mentions a meeting/call → high.
/// * Google Meet: a browser window titled "Meet - xxx-xxxx-xxx" or containing a
///   meet.google.com meeting URL → high.
/// * Teams/Zoom in the browser: matching browser window titles → high.
/// * Any native meeting client running while the mic is in use → medium.
public enum MeetingDetector {
    public static func detect(_ snapshot: SystemSnapshot) -> [DetectedMeeting] {
        var best: [String: DetectedMeeting] = [:]

        func offer(_ candidate: DetectedMeeting) {
            if let existing = best[candidate.bundleID], existing.confidence >= candidate.confidence { return }
            best[candidate.bundleID] = candidate
        }

        for window in snapshot.windows {
            guard snapshot.runningBundleIDs.contains(window.bundleID) else { continue }
            if let platform = platformForWindow(bundleID: window.bundleID, title: window.title) {
                offer(DetectedMeeting(platform: platform, bundleID: window.bundleID, windowTitle: window.title, confidence: .high))
            }
        }

        if snapshot.microphoneInUse {
            for bundleID in snapshot.runningBundleIDs {
                if let platform = MeetingPlatform.platform(forNativeBundleID: bundleID) {
                    offer(DetectedMeeting(platform: platform, bundleID: bundleID, windowTitle: nil, confidence: .medium))
                }
            }
        }

        return best.values.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.bundleID < $1.bundleID
        }
    }

    static func platformForWindow(bundleID: String, title: String) -> MeetingPlatform? {
        let lower = title.lowercased()

        if let native = MeetingPlatform.platform(forNativeBundleID: bundleID) {
            switch native {
            case .zoom:
                return (lower.hasPrefix("zoom meeting") || lower.hasPrefix("zoom webinar")) ? .zoom : nil
            case .teams:
                return isTeamsMeetingTitle(lower) ? .teams : nil
            case .webex:
                return (lower.contains("meeting") || lower.contains("webex")) && !lower.contains("home") ? .webex : nil
            case .googleMeet, .other:
                return nil
            }
        }

        guard KnownBrowsers.bundleIDs.contains(bundleID) else { return nil }
        if matchesMeetCode(title) || lower.contains("meet.google.com/") && containsMeetCode(lower) {
            return .googleMeet
        }
        if lower.contains("microsoft teams") && isTeamsMeetingTitle(lower) {
            return .teams
        }
        if lower.contains("zoom meeting") || lower.contains("app.zoom.us/wc") {
            return .zoom
        }
        return nil
    }

    static func isTeamsMeetingTitle(_ lower: String) -> Bool {
        // Teams meeting/call windows: "Meeting with Jane | Microsoft Teams",
        // "Weekly sync (Meeting) | Microsoft Teams", "Call with Bob | Microsoft Teams".
        let keywords = ["meeting", "call with", "| call", "(call)", "huddle", "meet now"]
        let excluded = ["meeting notes", "meetings app", "calendar"]
        guard keywords.contains(where: { lower.contains($0) }) else { return false }
        return !excluded.contains(where: { lower.contains($0) })
    }

    private static let meetCodePattern = "[a-z]{3}-[a-z]{4}-[a-z]{3}"

    /// "Meet - abc-defg-hij" / "Meet – abc-defg-hij - Google Chrome"
    static func matchesMeetCode(_ title: String) -> Bool {
        title.range(of: "^Meet\\s*[-–—:]\\s*\(meetCodePattern)\\b", options: [.regularExpression]) != nil
    }

    static func containsMeetCode(_ text: String) -> Bool {
        text.range(of: meetCodePattern, options: .regularExpression) != nil
    }
}
