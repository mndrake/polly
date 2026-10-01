import AVFoundation
import ScreenCaptureKit

/// What remote-side audio to capture.
enum CaptureTarget: Equatable, Sendable {
    /// Audio from one application (and its helper processes), e.g. Zoom or the browser running Meet.
    case application(bundleID: String)
    /// Everything the Mac plays, except Polly itself.
    case allSystemAudio
}

/// Captures the meeting app's audio output with ScreenCaptureKit.
///
/// ScreenCaptureKit filters audio by application, so this works the same for
/// Zoom, Teams, Webex and browsers without any vendor-specific code.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CaptureError: LocalizedError {
        case noDisplay
        case applicationNotRunning(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display is available for audio capture."
            case let .applicationNotRunning(bundleID): return "The meeting app (\(bundleID)) isn't running."
            }
        }
    }

    /// Called on a private queue with each captured buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called if the stream stops unexpectedly (e.g. permission revoked, app quit).
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.polly.system-audio", qos: .userInitiated)

    func start(target: CaptureTarget) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter: SCContentFilter
        switch target {
        case let .application(bundleID):
            // Include helper processes (e.g. "com.google.Chrome.helper") which
            // is where browsers and Electron apps actually play audio from.
            let apps = content.applications.filter {
                $0.bundleIdentifier == bundleID || $0.bundleIdentifier.hasPrefix(bundleID + ".")
            }
            guard !apps.isEmpty else { throw CaptureError.applicationNotRunning(bundleID) }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        case .allSystemAudio:
            let ownBundleID = Bundle.main.bundleIdentifier ?? "app.polly.Polly"
            let excluded = content.applications.filter { $0.bundleIdentifier == ownBundleID }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // We only want audio; keep the (mandatory) video stream as cheap as possible.
        configuration.width = 64
        configuration.height = 64
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Registering a screen output avoids "stream output NOT found" frame-drop log spam.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = sampleBuffer.makePCMBuffer() else { return }
        onBuffer?(buffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}
