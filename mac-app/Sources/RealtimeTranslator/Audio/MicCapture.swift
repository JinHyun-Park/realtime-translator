import AVFoundation
import CoreAudio

/// Captures microphone (or any selected input device) via AVAudioEngine and
/// resamples to 16 kHz mono Float. Pass a specific AudioDeviceID to override
/// the system default input.
///
/// THREADING: all AVAudioEngine work (inputNode access, start, stop) happens on
/// a private serial queue, NEVER the caller's thread. Touching engine.inputNode
/// can dispatch_sync to an internal CoreAudio HAL queue and block; doing that on
/// the main thread froze the whole app ("응답 없음"). Callers use startAsync /
/// stopAsync and stay responsive.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let resampler = Resampler()
    private let q = DispatchQueue(label: "rt.mic.engine")
    var onSamples: (([Float]) -> Void)?

    /// Start on the private queue. `onError` is called (on that queue) with nil
    /// on success or a message on failure — callers hop to the main actor.
    func startAsync(device: AudioDeviceID?, onError: @escaping (String?) -> Void) {
        q.async { [weak self] in
            guard let self else { return }
            do {
                try self.setInputDeviceLocked(device)
                try self.startLocked()
                rtlog("mic.start() OK device=\(String(describing: device))")
                onError(nil)
            } catch {
                rtlog("mic.start() FAILED: \(error.localizedDescription)")
                onError(error.localizedDescription)
            }
        }
    }

    func stopAsync() {
        q.async { [weak self] in self?.stopLocked() }
    }

    // --- private, always run on `q` ---

    private func setInputDeviceLocked(_ deviceID: AudioDeviceID?) throws {
        guard let deviceID else { return }
        guard let unit = engine.inputNode.audioUnit else { return }
        var dev = deviceID
        let st = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
            0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if st != noErr {
            throw NSError(domain: "rt.mic", code: Int(st),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Failed to set input device (\(st))"])
        }
    }

    private func startLocked() throws {
        let input = engine.inputNode
        // Acoustic echo cancellation: when the meeting plays through SPEAKERS,
        // the other side's voice re-enters this mic and gets transcribed as ME
        // duplicating THEM. Apple's voice processing subtracts the system
        // output from the mic signal (same tech as FaceTime). Must be set
        // BEFORE reading the format/installing the tap — it changes the node's
        // I/O format. Best-effort: if the device/OS refuses, capture stays raw
        // (headphone users lose nothing either way).
        do {
            try input.setVoiceProcessingEnabled(true)
            rtlog("mic AEC (voice processing) enabled")
        } catch {
            rtlog("mic AEC unavailable, capturing raw: \(error.localizedDescription)")
        }
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

    private func stopLocked() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}
