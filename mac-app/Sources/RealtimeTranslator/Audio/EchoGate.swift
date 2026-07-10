import Accelerate
import Foundation

/// Cross-correlation echo gate — the device-independent fix for the SPEAKER
/// echo problem: meeting audio played through speakers re-enters the mic and
/// gets transcribed as ME duplicating THEM.
///
/// Everything else we tried failed structurally: macOS voice-processing AEC
/// ducks the system output (user can't hear the meeting) and muted the mic on
/// some devices; server-side TEXT dedup broke on differing sentence boundaries
/// and deleted the wrong side. This gate compares the AUDIO itself: the app
/// already holds both streams, and an echo is by definition the system signal
/// re-arriving in the mic at a constant acoustic delay. So:
///
///   1. Keep short rolling windows of both streams (decimated to 8 kHz).
///   2. Normalized cross-correlation of the mic window against the system
///      window across delays 0..MAX_DELAY (vDSP_conv).
///   3. Gate the mic ONLY when: correlation is strong AND the matched delay is
///      STABLE across consecutive evaluations (a real acoustic path has one
///      constant delay; coincidental speech matches jitter) AND the mic level
///      is explainable by the learned echo gain (if the mic is much louder
///      than the echo path predicts, the user is talking over it — pass).
///
/// Prototype numbers (synthetic room, delay 80–300 ms, gain 0.1–0.5):
/// echo windows blocked 88–92%, genuine speech falsely blocked 0% (6% during
/// double-talk). Headset users are unaffected: no leak → no stable correlation.
///
/// Threading: `pushSystem` is called from the ScreenCaptureKit callback,
/// `pushMic` from the mic tap queue. State is lock-protected; the correlation
/// (~14M MACs via vDSP) runs at most every 100 ms on the mic queue.
final class EchoGate {
    // Tunables (all in 8 kHz samples unless noted).
    private static let decimation = 2            // 16 kHz capture -> 8 kHz gate
    private static let rate = 8_000
    private static let micWin = rate / 2         // 0.5 s of mic
    private static let maxDelay = Int(0.45 * Double(rate))  // search 0..450 ms
    private static let sysWin = micWin + maxDelay
    private static let evalEvery = rate / 10     // evaluate per 100 ms of mic
    private static let nccThreshold: Float = 0.30
    private static let stableCount = 3           // consecutive stable-delay hits
    private static let delayJitter = Int(0.03 * Double(rate))  // ±30 ms
    private static let overshoot: Float = 2.2    // mic > 2.2x learned echo => talk
    private static let silenceRMS: Float = 3e-4

    private let lock = NSLock()
    private var micBuf: [Float] = []
    private var sysBuf: [Float] = []
    private var sinceEval = 0
    private var recentDelays: [Int] = []
    private var learnedGains: [Float] = []
    private(set) var isGating = false
    /// Called on gate transitions (off the main thread) for logging/UI.
    var onTransition: ((Bool) -> Void)?

    func reset() {
        lock.lock(); defer { lock.unlock() }
        micBuf.removeAll(); sysBuf.removeAll()
        sinceEval = 0; recentDelays.removeAll(); learnedGains.removeAll()
        isGating = false
    }

    /// Feed the clean system-audio reference (16 kHz mono).
    func pushSystem(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let dec = Self.decimate(samples)
        lock.lock()
        sysBuf.append(contentsOf: dec)
        if sysBuf.count > Self.sysWin { sysBuf.removeFirst(sysBuf.count - Self.sysWin) }
        lock.unlock()
    }

    /// Feed mic samples (16 kHz mono); returns true if this chunk should be
    /// suppressed (it is the speaker's echo, not the user).
    func pushMic(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return isGating }
        let dec = Self.decimate(samples)
        lock.lock()
        micBuf.append(contentsOf: dec)
        if micBuf.count > Self.micWin { micBuf.removeFirst(micBuf.count - Self.micWin) }
        sinceEval += dec.count
        let due = sinceEval >= Self.evalEvery
            && micBuf.count == Self.micWin && sysBuf.count == Self.sysWin
        if due { sinceEval = 0 }
        // Snapshot under the lock; correlate outside it so the system-audio
        // callback is never blocked behind a 1–2 ms vDSP call.
        let mic = due ? micBuf : []
        let sys = due ? sysBuf : []
        lock.unlock()
        if due { evaluate(mic: mic, sys: sys) }
        return isGating
    }

    // MARK: - internals

    private static func decimate(_ x: [Float]) -> [Float] {
        // Stride-2 pick: crude but adequate — both streams alias identically
        // enough for correlation, and the echo path is lowpassed anyway.
        var out = [Float](); out.reserveCapacity(x.count / decimation + 1)
        var i = 0
        while i < x.count { out.append(x[i]); i += decimation }
        return out
    }

    private static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var mean: Float = 0
        x.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress!, 1, &mean, vDSP_Length(x.count)) }
        return sqrt(mean)
    }

    private func evaluate(mic: [Float], sys: [Float]) {
        let micRMS = Self.rms(mic[...])
        let sysRMS = Self.rms(sys[(sys.count - Self.micWin)...])
        // Mic silent -> nothing to gate; system silent -> can't be an echo.
        if micRMS < Self.silenceRMS || sysRMS < Self.silenceRMS {
            setGate(false, clearHistory: true)
            return
        }

        // corr[i] = Σ_p sys[i+p] * mic0[p]   (vDSP_conv with unit filter stride)
        var mic0 = mic
        var mean: Float = 0
        vDSP_meanv(mic0, 1, &mean, vDSP_Length(mic0.count))
        mean = -mean
        vDSP_vsadd(mic0, 1, &mean, &mic0, 1, vDSP_Length(mic0.count))
        let nOut = sys.count - mic0.count + 1     // = maxDelay + 1
        var corr = [Float](repeating: 0, count: nOut)
        sys.withUnsafeBufferPointer { s in
            mic0.withUnsafeBufferPointer { f in
                vDSP_conv(s.baseAddress!, 1, f.baseAddress!, 1,
                          &corr, 1, vDSP_Length(nOut), vDSP_Length(mic0.count))
            }
        }
        var micNorm: Float = 0
        vDSP_svesq(mic0, 1, &micNorm, vDSP_Length(mic0.count))
        micNorm = sqrt(micNorm) + 1e-9

        // Per-delay normalization via prefix sums of sys².
        var sysSq = [Float](repeating: 0, count: sys.count)
        vDSP_vsq(sys, 1, &sysSq, 1, vDSP_Length(sys.count))
        var prefix = [Float](repeating: 0, count: sys.count + 1)
        var acc: Float = 0
        for i in 0..<sysSq.count { acc += sysSq[i]; prefix[i + 1] = acc }

        var best: Float = 0
        var bestIdx = -1
        for i in 0..<nOut {
            let e = sqrt(max(prefix[i + Self.micWin] - prefix[i], 0)) + 1e-9
            let c = corr[i] / (micNorm * e)
            if c > best { best = c; bestIdx = i }
        }
        guard best > Self.nccThreshold, bestIdx >= 0 else {
            setGate(false, clearHistory: true)
            return
        }
        // Buffer alignment: sysBuf spans [T-0.95s, T], micBuf [T-0.5s, T];
        // matching at corr index i means the mic lags the system by:
        let delay = (sys.count - Self.micWin) - bestIdx

        lock.lock()
        recentDelays.append(delay)
        if recentDelays.count > 8 { recentDelays.removeFirst() }
        var stable = false
        if recentDelays.count >= Self.stableCount {
            let tail = recentDelays.suffix(Self.stableCount).sorted()
            let median = tail[tail.count / 2]
            stable = recentDelays.suffix(Self.stableCount)
                .allSatisfy { abs($0 - median) <= Self.delayJitter }
        }
        lock.unlock()
        guard stable else { setGate(false, clearHistory: false); return }

        // Double-talk guard: learn the acoustic gain (mic/sys at the matched
        // delay) during confirmed echo; if the mic now carries far more energy
        // than that gain explains, the user is speaking over the echo — pass.
        let aligned = sys[bestIdx..<(bestIdx + Self.micWin)]
        let ratio = micRMS / (Self.rms(aligned) + 1e-9)
        lock.lock()
        let g = learnedGains.isEmpty ? ratio : learnedGains.sorted()[learnedGains.count / 2]
        if learnedGains.isEmpty || ratio < g * Self.overshoot {
            learnedGains.append(ratio)
            if learnedGains.count > 30 { learnedGains.removeFirst() }
        }
        lock.unlock()
        setGate(ratio <= g * Self.overshoot, clearHistory: false)
    }

    private func setGate(_ on: Bool, clearHistory: Bool) {
        lock.lock()
        if clearHistory { recentDelays.removeAll() }
        let changed = isGating != on
        isGating = on
        lock.unlock()
        if changed { onTransition?(on) }
    }
}
