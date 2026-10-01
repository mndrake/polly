import XCTest
@testable import PollyCore

final class MeetingDetectorTests: XCTestCase {
    private func detect(running: [String], windows: [(String, String)] = [], mic: Bool = false) -> [DetectedMeeting] {
        MeetingDetector.detect(SystemSnapshot(
            runningBundleIDs: Set(running),
            windows: windows.map { SystemSnapshot.Window(bundleID: $0.0, title: $0.1) },
            microphoneInUse: mic
        ))
    }

    func testZoomMeetingWindow() {
        let result = detect(running: ["us.zoom.xos"], windows: [("us.zoom.xos", "Zoom Meeting")])
        XCTAssertEqual(result, [DetectedMeeting(platform: .zoom, bundleID: "us.zoom.xos", windowTitle: "Zoom Meeting", confidence: .high)])
        XCTAssertNil(result.first?.suggestedTitle)
    }

    func testZoomHomeWindowIsNotAMeeting() {
        XCTAssertTrue(detect(running: ["us.zoom.xos"], windows: [("us.zoom.xos", "Zoom Workplace")]).isEmpty)
    }

    func testZoomRunningWithMicIsMedium() {
        let result = detect(running: ["us.zoom.xos", "com.apple.finder"], mic: true)
        XCTAssertEqual(result.first?.confidence, .medium)
        XCTAssertEqual(result.first?.platform, .zoom)
    }

    func testTeamsMeetingWindow() {
        let result = detect(
            running: ["com.microsoft.teams2"],
            windows: [("com.microsoft.teams2", "Chat | Microsoft Teams"), ("com.microsoft.teams2", "Quarterly planning (Meeting) | Microsoft Teams")]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.platform, .teams)
        XCTAssertEqual(result.first?.confidence, .high)
        XCTAssertEqual(result.first?.suggestedTitle, "Quarterly planning (Meeting)")
    }

    func testTeamsCalendarIsNotAMeeting() {
        XCTAssertTrue(detect(running: ["com.microsoft.teams2"], windows: [("com.microsoft.teams2", "Calendar | Microsoft Teams")]).isEmpty)
    }

    func testGoogleMeetInChrome() {
        let result = detect(running: ["com.google.Chrome"], windows: [("com.google.Chrome", "Meet - abc-defg-hij - Google Chrome")])
        XCTAssertEqual(result.first?.platform, .googleMeet)
        XCTAssertEqual(result.first?.bundleID, "com.google.Chrome")
        XCTAssertNil(result.first?.suggestedTitle, "bare meeting codes are not useful titles")
    }

    func testGoogleMeetNamedMeetingInArc() {
        let result = detect(running: ["company.thebrowser.Browser"], windows: [("company.thebrowser.Browser", "Meet – abc-defg-hij")])
        XCTAssertEqual(result.first?.platform, .googleMeet)
    }

    func testGoogleMeetLandingPageIsNotAMeeting() {
        XCTAssertTrue(detect(running: ["com.google.Chrome"], windows: [("com.google.Chrome", "Google Meet - Google Chrome")]).isEmpty)
    }

    func testTeamsOnTheWeb() {
        let result = detect(running: ["com.microsoft.edgemac"], windows: [("com.microsoft.edgemac", "Meeting with Ana | Microsoft Teams - Microsoft Edge")])
        XCTAssertEqual(result.first?.platform, .teams)
    }

    func testBrowserWithMicAloneIsNotDetected() {
        // Browsers use the mic for many things; only titles identify a web meeting.
        XCTAssertTrue(detect(running: ["com.google.Chrome"], windows: [("com.google.Chrome", "Inbox - Gmail")], mic: true).isEmpty)
    }

    func testWindowsOfAppsThatAreNotRunningAreIgnored() {
        XCTAssertTrue(detect(running: [], windows: [("us.zoom.xos", "Zoom Meeting")]).isEmpty)
    }

    func testHighConfidenceWinsAndSortsFirst() {
        let result = detect(
            running: ["us.zoom.xos", "com.microsoft.teams2"],
            windows: [("com.microsoft.teams2", "Meeting with Bo | Microsoft Teams")],
            mic: true
        )
        XCTAssertEqual(result.map(\.platform), [.teams, .zoom])
        XCTAssertEqual(result.map(\.confidence), [.high, .medium])
    }
}
