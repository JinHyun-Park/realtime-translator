import AVFoundation
import CoreAudio

/// Captures microphone (or any selected input device) via AVAudioEngine and
/// resamples to 16 kHz mono Float. Pass a specific AudioDeviceID to override
/// the system default input.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let resampler = Resampler()
    var onSamples: (([Float]) -> Void)?

    /// Set the HAL input device before start(). nil = system default.
    func setInputDevice(_ deviceID: AudioDeviceID?) throws {
        guard let deviceID else { return }
        // Point the engine's input unit at the chosen device.
        guard let unit = engine.inputNode.audioUnit else { return }
        var dev = deviceID
        let st = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if st != noErr {
            throw NSError(domain: "rt.mic", code: Int(st),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Failed to set input device (\(st))"])
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "rt.mic", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Mic has no valid input format"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let samples = self.resampler.resample(buf)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}
