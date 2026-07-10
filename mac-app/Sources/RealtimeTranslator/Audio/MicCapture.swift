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

    // Auto-restart on device-graph changes: switching the DEFAULT OUTPUT
    // device (e.g. headphones -> MacBook speakers) fires
    // AVAudioEngineConfigurationChange and silently STOPS the engine — the
    // mic looks alive but no samples flow. Remember what we started with so
    // the observer can rebuild the exact same capture.
    private var running = false
    private var lastDevice: AudioDeviceID?
    private var lastAec = false
    private var configObserver: NSObjectProtocol?

    /// Start on the private queue. `onError` is called (on that queue) with nil
    /// on success or a message on failure — callers hop to the main actor.
    /// `aec`: enable macOS voice processing (echo cancellation). OFF by default
    /// — on engines like ours with no output path, voice processing can deliver
    /// all-zero input buffers on some device combos (mic looks alive, hears
    /// nothing). Users who meet the speaker-echo problem opt in via the UI.
    func startAsync(device: AudioDeviceID?, aec: Bool,
                    onError: @escaping (String?) -> Void) {
        q.async { [weak self] in
            guard let self else { return }
            do {
                try self.setInputDeviceLocked(device)
                try self.startLocked(aec: aec)
                self.running = true
                self.lastDevice = device
                self.lastAec = aec
                self.installConfigObserverLocked()
                rtlog("mic.start() OK device=\(String(describing: device)) aec=\(aec)")
                onError(nil)
            } catch {
                rtlog("mic.start() FAILED: \(error.localizedDescription)")
                onError(error.localizedDescription)
            }
        }
    }

    func stopAsync() {
        q.async { [weak self] in
            guard let self else { return }
            self.running = false
            if let obs = self.configObserver {
                NotificationCenter.default.removeObserver(obs)
                self.configObserver = nil
            }
            self.stopLocked()
        }
    }

    /// AVAudioEngine stops itself when the audio device graph changes (default
    /// output switch, headphones plugged/unplugged, ...). Rebuild the tap with
    /// the same device+AEC so capture survives the change. Debounced on our
    /// serial queue; a burst of change notifications collapses into one rebuild.
    private func installConfigObserverLocked() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.q.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.running, !self.engine.isRunning else { return }
                rtlog("mic: engine config change — restarting capture")
                self.stopLocked()
                do {
                    try self.setInputDeviceLocked(self.lastDevice)
                    try self.startLocked(aec: self.lastAec)
                    rtlog("mic: restart after config change OK")
                } catch {
                    rtlog("mic: restart after config change FAILED: \(error.localizedDescription)")
                }
            }
        }
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

    private func startLocked(aec: Bool) throws {
        let input = engine.inputNode
        // Acoustic echo cancellation (OPT-IN): when the meeting plays through
        // SPEAKERS, the other side's voice re-enters this mic and gets
        // transcribed as ME duplicating THEM. Apple's voice processing
        // subtracts the system output from the mic signal (same tech as
        // FaceTime). Must be set BEFORE reading the format/installing the tap
        // — it changes the node's I/O format. Caveat: on an input-only engine
        // some device combos deliver silent (all-zero) buffers with voice
        // processing on — hence opt-in rather than default.
        if aec {
            do {
                try input.setVoiceProcessingEnabled(true)
                rtlog("mic AEC (voice processing) enabled")
            } catch {
                rtlog("mic AEC unavailable, capturing raw: \(error.localizedDescription)")
            }
        } else if input.isVoiceProcessingEnabled {
            // A previous AEC run leaves voice processing latched on the node;
            // turn it back off so plain capture is truly plain.
            try? input.setVoiceProcessingEnabled(false)
            rtlog("mic AEC disabled (raw capture)")
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
