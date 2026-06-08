import AVFoundation

/// Converts an arbitrary input AVAudioPCMBuffer into 16 kHz mono Float32 samples.
/// One instance per source (mic, system) because AVAudioConverter is stateful.
final class Resampler {
    static let targetSampleRate: Double = 16_000

    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Resampler.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Returns mono 16 kHz Float32 samples for the given input buffer.
    func resample(_ input: AVAudioPCMBuffer) -> [Float] {
        guard input.frameLength > 0 else { return [] }

        if converter == nil || inFormat != input.format {
            inFormat = input.format
            converter = AVAudioConverter(from: input.format, to: outFormat)
            converter?.sampleRateConverterQuality = .max
        }
        guard let converter else { return [] }

        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(
            pcmFormat: outFormat, frameCapacity: max(capacity, 16)
        ) else { return [] }

        var supplied = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, let ch = out.floatChannelData else { return [] }
        let n = Int(out.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }
}

/// Float [-1,1] -> little-endian Int16 PCM bytes.
func floatsToPCM16(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for s in samples {
        let clamped = max(-1.0, min(1.0, s))
        let v = Int16(clamped * 32767.0)
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}
