import AVFoundation
import ScreenCaptureKit

/// Captures system (speaker) audio using ScreenCaptureKit's audio-only stream.
/// macOS 13+; on 14+ this needs Screen Recording permission (audio-only still
/// gates behind it). No virtual device (BlackHole) required.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let resampler = Resampler()
    var onSamples: (([Float]) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "rt.sys", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        // Capture the whole display but we only consume the audio track.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true   // don't capture our own output
        // Keep the video path minimal — we don't use frames.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio,
                              sampleHandlerQueue: DispatchQueue(label: "rt.sys.audio"))
        try await s.startCapture()
        stream = s
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              let buf = pcmBuffer(from: sampleBuffer) else { return }
        let samples = resampler.resample(buf)
        if !samples.isEmpty { onSamples?(samples) }
    }

    /// CMSampleBuffer (CoreMedia) -> AVAudioPCMBuffer for the resampler.
    private func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)
        else { return nil }
        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        pcm.frameLength = frames
        let err = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        )
        return err == noErr ? pcm : nil
    }
}
