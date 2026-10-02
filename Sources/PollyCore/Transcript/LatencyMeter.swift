import Foundation

/// Tracks how far live transcription lags behind the audio, per speaker.
///
/// Each result says which stretch of audio it covers (seconds from the start
/// of the recording). Comparing its end with the current recording time gives
/// the recognizer's lag: how long after someone says a word it shows up.
public struct LatencyMeter: Sendable, Equatable {
    /// Smoothed lag per speaker, in seconds.
    public private(set) var smoothed: [Speaker: TimeInterval] = [:]
    /// Most recent raw lag per speaker.
    public private(set) var latest: [Speaker: TimeInterval] = [:]
    /// Weight of each new sample in the moving average.
    public var smoothing: Double = 0.3

    public init() {}

    /// Records a result covering audio up to `resultEnd` that arrived at
    /// recording time `now`. Implausible values (results "from the future"
    /// or long-stale finals) are ignored.
    public mutating func record(speaker: Speaker, resultEnd: TimeInterval, now: TimeInterval) {
        let lag = now - resultEnd
        guard resultEnd > 0, lag >= 0, lag < 30 else { return }
        latest[speaker] = lag
        if let previous = smoothed[speaker] {
            smoothed[speaker] = previous + smoothing * (lag - previous)
        } else {
            smoothed[speaker] = lag
        }
    }

    /// The worse of the two channels, for a single readout.
    public var overall: TimeInterval? { smoothed.values.max() }

    /// "0.8 s behind" / "2.4 s behind".
    public static func describe(_ lag: TimeInterval) -> String {
        String(format: "%.1f s behind", lag)
    }
}
