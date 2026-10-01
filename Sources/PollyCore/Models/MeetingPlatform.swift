import Foundation

public enum MeetingPlatform: String, Codable, Sendable, CaseIterable {
    case zoom
    case teams
    case googleMeet
    case webex
    case other

    public var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .googleMeet: return "Google Meet"
        case .webex: return "Webex"
        case .other: return "Other"
        }
    }

    /// Native desktop clients for the platform.
    public var nativeBundleIDs: [String] {
        switch self {
        case .zoom: return ["us.zoom.xos"]
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .googleMeet: return []
        case .webex: return ["Cisco-Systems.Spark", "com.webex.meetingmanager"]
        case .other: return []
        }
    }

    public static func platform(forNativeBundleID bundleID: String) -> MeetingPlatform? {
        allCases.first { $0.nativeBundleIDs.contains(bundleID) }
    }
}

/// Browsers that can host web meetings (Google Meet, Teams on the web, Zoom web client).
public enum KnownBrowsers {
    public static let bundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
    ]
}
