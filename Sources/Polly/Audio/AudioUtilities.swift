import AVFoundation
import CoreMedia

extension CMSampleBuffer {
    /// Copies the audio in this sample buffer into a new `AVAudioPCMBuffer`.
    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        let frames = CMSampleBufferGetNumSamples(self)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

extension AVAudioPCMBuffer {
    /// Root-mean-square level (0…1) of the first channel, for level meters.
    var rmsLevel: Float {
        let frames = Int(frameLength)
        guard frames > 0 else { return 0 }
        if let data = floatChannelData {
            var sum: Float = 0
            for i in 0..<frames { sum += data[0][i] * data[0][i] }
            return (sum / Float(frames)).squareRoot()
        }
        if let data = int16ChannelData {
            var sum: Float = 0
            for i in 0..<frames {
                let sample = Float(data[0][i]) / Float(Int16.max)
                sum += sample * sample
            }
            return (sum / Float(frames)).squareRoot()
        }
        return 0
    }

    var duration: TimeInterval {
        Double(frameLength) / format.sampleRate
    }

    /// A buffer of digital silence.
    static func silence(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        return buffer
    }
}

/// Converts arbitrary PCM buffers (device sample rate, channel count, sample
/// format) into the format a speech engine wants. Not thread-safe; each
/// capture source feeds its own converter from a single thread.
final class AudioFormatConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }

        if converter == nil || inputFormat != buffer.format {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                throw TranscriptionError.audioFormat("Cannot convert \(buffer.format) to \(outputFormat)")
            }
            newConverter.downmix = buffer.format.channelCount > outputFormat.channelCount
            converter = newConverter
            inputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let input = SingleBufferInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let next = input.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        if status == .error {
            throw conversionError ?? TranscriptionError.audioFormat("Audio conversion failed")
        }
        return output.frameLength > 0 ? output : nil
    }
}

/// Hands a buffer to AVAudioConverter's input block exactly once.
private final class SingleBufferInput {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
