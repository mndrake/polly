import Foundation

/// Keeps a speech engine's audio clock aligned with wall-clock time.
///
/// Speech engines timestamp results by the number of samples they've been
/// fed. Capture sources can pause (ScreenCaptureKit may stop delivering
/// buffers when an app is silent, devices can hiccup), which would make one
/// channel's timestamps drift behind the other's. Before each buffer, the
/// pipeline asks the aligner how many frames of silence to insert so the fed
/// sample count matches the elapsed time since recording started.
public struct TimelineAligner: Sendable {
    public let sampleRate: Double
    /// Gaps shorter than this are ignored (normal capture jitter).
    public let tolerance: TimeInterval
    public private(set) var framesFed: Int64 = 0

    public init(sampleRate: Double, tolerance: TimeInterval = 0.25) {
        self.sampleRate = sampleRate
        self.tolerance = tolerance
    }

    /// Seconds of audio fed so far.
    public var fedDuration: TimeInterval { Double(framesFed) / sampleRate }

    /// Returns the number of silent frames to insert before a buffer that
    /// arrives `elapsed` seconds after the recording started.
    public mutating func silenceFrames(beforeBufferAt elapsed: TimeInterval) -> Int {
        let gap = elapsed - fedDuration
        guard gap > tolerance else { return 0 }
        let frames = Int((gap * sampleRate).rounded(.down))
        framesFed += Int64(frames)
        return frames
    }

    public mutating func didFeed(frames: Int) {
        framesFed += Int64(frames)
    }
}
