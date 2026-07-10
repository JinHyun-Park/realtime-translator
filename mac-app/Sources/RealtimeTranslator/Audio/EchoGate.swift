import Accelerate
import Foundation

/// Cross-correlation echo gate — the device-independent fix for the SPEAKER
/// echo problem: meeting audio played through speakers re-enters the mic and
/// gets transcribed as ME duplicating THEM.
///
/// Why not the alternatives: macOS voice-processing AEC ducks the system
/// output (user can't hear the meeting) and muted the mic on some devices;
/// server-side TEXT dedup broke on differing sentence boundaries and deleted
/// the wrong side. This gate compares the AUDIO itself.
///
/// v2 design (v1 flapped: 134 gate transitions in one meeting — every
/// far-side sentence pause dropped the correlation, cleared the state, and
/// the next sentence's onset leaked ~0.5s of echo while the mic window
/// refilled — "초반에 잘되다가 ME가 들어온다"):
///
///   1. ACQUIRE: full cross-correlation search (vDSP_conv) of the last 0.5s
///      of mic against the last ~0.95s of system audio; the echo delay must
///      be STABLE across 3 consecutive evals.
///   2. LOCK: the acoustic path doesn't change when people pause. Once
///      acquired, the delay stays locked through silences; re-engage needs a
///      single soft verification at the locked delay (not 3 full-search
///      hits), and only ~3s of sustained mismatch WHILE both streams are
///      active unlocks it.
///   3. LOOKAHEAD: mic audio is released to the relay through a 500ms FIFO.
///      When the gate engages, pending chunks of the SAME utterance (no
///      ≥150ms silence break) are retroactively zeroed — the onset that
///      slipped out before detection never reaches the relay at all.
///   4. Double-talk guard: learn the acoustic gain during confirmed echo; if
///      the mic is much louder than the gain explains, the user is speaking
///      over the playback — pass it through.
///
/// Prototype validation (synthetic room, delay 80–300ms, gain 0.1–0.5,
/// sentence pauses 0.6–2s): 90–95% of echo windows blocked, 0% genuine
/// speech blocked when separated from echo (overlapping double-talk onset:
/// first syllables may clip), headset scenario completely unaffected.
/// Cost: ME audio reaches the relay 500ms late (subtitle-only impact).
///
/// Threading: `pushSystem` from the ScreenCaptureKit callback, `processMic`
/// from the mic tap queue. All state lock-protected; the full correlation
/// (~0.03ms via vDSP) runs at most every 50ms, only while unlocked.
final class EchoGate {
    // All sample counts at the decimated gate rate unless noted.
    private static let decimation = 2              // 16 kHz capture -> 8 kHz gate
    private static let rate = 8_000
    private static let micWin = rate / 2           // 0.5 s analysis window
    private static let maxDelay = Int(0.45 * Double(rate))   // search 0..450 ms
    private static let sysWin = micWin + maxDelay
    private static let evalEvery = rate / 20       // evaluate per 50 ms of mic
    private static let nccAcquire: Float = 0.30    // full-search acquire bar
    private static let nccRelock: Float = 0.15     // soft bar at locked delay
    private static let stableCount = 3
    private static let delayJitter = Int(0.03 * Double(rate))  // ±30 ms
    private static let overshoot: Float = 2.5      // mic > 2.5x echo => talking
    private static let unlockAfter = 60            // ~3s of active-mismatch evals
    private static let hangoverEvals = 12          // hold gate ~600ms past sys quiet
    private static let silenceRMS: Float = 3e-4
    // Lookahead FIFO (16 kHz ORIGINAL samples — what actually gets sent).
    private static let lookaheadSamples = 8_000    // 500 ms at 16 kHz
    private static let utteranceBreak = 0.15       // 150ms silence ends an utterance

    private let lock = NSLock()
    private var micBuf: [Float] = []               // 8 kHz analysis window
    private var sysBuf: [Float] = []
    private var sinceEval = 0
    private var acquireDelays: [Int] = []
    private var learnedGains: [Float] = []
    private var lockedDelay: Int? = nil
    private var missCount = 0
    private var hangover = 0
    private var gateOn = false
    // FIFO of pending mic chunks: (samples@16k, suppressed, rms, silentRunS).
    private struct Pending { var samples: [Float]; var suppress: Bool; var rms: Float }
    private var fifo: [Pending] = []
    private var fifoSamples = 0

    private(set) var isGating = false
    /// Called on gate transitions (off the main thread) for logging/UI.
    var onTransition: ((Bool) -> Void)?

    func reset() {
        lock.lock(); defer { lock.unlock() }
        micBuf.removeAll(); sysBuf.removeAll(); fifo.removeAll(); fifoSamples = 0
        sinceEval = 0; acquireDelays.removeAll(); learnedGains.removeAll()
        lockedDelay = nil; missCount = 0; hangover = 0
        gateOn = false; isGating = false
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

    /// Feed mic samples (16 kHz mono). Returns the DELAYED audio to actually
    /// send (500ms behind real time, zeroed where echo was detected — possibly
    /// retroactively), or nil while the lookahead is still priming.
    func processMic(_ samples: [Float]) -> [Float]? {
        guard !samples.isEmpty else { return nil }
        var rms: Float = 0
        samples.withUnsafeBufferPointer {
            vDSP_measqv($0.baseAddress!, 1, &rms, vDSP_Length(samples.count))
        }
        rms = sqrt(rms)
        let dec = Self.decimate(samples)

        lock.lock()
        micBuf.append(contentsOf: dec)
        if micBuf.count > Self.micWin { micBuf.removeFirst(micBuf.count - Self.micWin) }
        sinceEval += dec.count
        let due = sinceEval >= Self.evalEvery
            && micBuf.count == Self.micWin && sysBuf.count == Self.sysWin
        if due { sinceEval = 0 }
        let mic = due ? micBuf : []
        let sys = due ? sysBuf : []
        lock.unlock()
        if due { evaluate(mic: mic, sys: sys) }

        lock.lock()
        fifo.append(Pending(samples: samples, suppress: gateOn, rms: rms))
        fifoSamples += samples.count
        if gateOn {
            // Retroactive suppression: zero pending chunks backwards through
            // the current contiguous utterance (stop at a ≥150ms silence run).
            var silentSamples = 0
            let breakLen = Int(Self.utteranceBreak * 16_000)
            for i in stride(from: fifo.count - 1, through: 0, by: -1) {
                if fifo[i].rms < Self.silenceRMS {
                    silentSamples += fifo[i].samples.count
                    if silentSamples >= breakLen { break }
                } else {
                    silentSamples = 0
                }
                fifo[i].suppress = true
            }
        }
        var out: [Float]? = nil
        if fifoSamples - fifo[0].samples.count >= Self.lookaheadSamples {
            let head = fifo.removeFirst()
            fifoSamples -= head.samples.count
            out = head.suppress
                ? [Float](repeating: 0, count: head.samples.count)
                : head.samples
        }
        lock.unlock()
        return out
    }

    /// Flush remaining FIFO audio (unsuppressed tail) — call on capture stop
    /// so the last half-second of the user's speech isn't swallowed.
    func drain() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        var out: [Float] = []
        for p in fifo {
            out.append(contentsOf: p.suppress
                ? [Float](repeating: 0, count: p.samples.count) : p.samples)
        }
        fifo.removeAll(); fifoSamples = 0
        return out
    }

    // MARK: - internals

    private static func decimate(_ x: [Float]) -> [Float] {
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

    /// Normalized cross-correlation of zero-mean mic `m0` against the sys
    /// window at ONE candidate delay.
    private func nccAt(_ m0: [Float], _ mNorm: Float, sys: [Float], delay: Int) -> Float {
        let i = (sys.count - Self.micWin) - delay
        guard i >= 0 else { return 0 }
        let seg = Array(sys[i..<(i + Self.micWin)])
        var mean: Float = 0
        vDSP_meanv(seg, 1, &mean, vDSP_Length(seg.count))
        var s0 = seg
        mean = -mean
        vDSP_vsadd(seg, 1, &mean, &s0, 1, vDSP_Length(seg.count))
        var dot: Float = 0
        vDSP_dotpr(m0, 1, s0, 1, &dot, vDSP_Length(m0.count))
        var e: Float = 0
        vDSP_svesq(s0, 1, &e, vDSP_Length(s0.count))
        return dot / (mNorm * (sqrt(e) + 1e-9))
    }

    private func evaluate(mic: [Float], sys: [Float]) {
        let micRMS = Self.rms(mic[...])
        let sysRMS = Self.rms(sys[(sys.count - Self.micWin)...])

        if micRMS < Self.silenceRMS {
            setGate(false); hangover = 0
            return
        }
        var m0 = mic
        var mean: Float = 0
        vDSP_meanv(m0, 1, &mean, vDSP_Length(m0.count))
        mean = -mean
        vDSP_vsadd(mic, 1, &mean, &m0, 1, vDSP_Length(m0.count))
        var mNorm: Float = 0
        vDSP_svesq(m0, 1, &mNorm, vDSP_Length(m0.count))
        mNorm = sqrt(mNorm) + 1e-9

        if let d = lockedDelay {
            // LOCKED: soft verification at (around) the known delay only.
            let c = max(nccAt(m0, mNorm, sys: sys, delay: d),
                        nccAt(m0, mNorm, sys: sys, delay: max(0, d - Self.delayJitter / 2)),
                        nccAt(m0, mNorm, sys: sys, delay: d + Self.delayJitter / 2))
            if c > Self.nccRelock {
                missCount = 0
                let i = (sys.count - Self.micWin) - d
                let aligned = Self.rms(sys[max(0, i)..<min(sys.count, max(0, i) + Self.micWin)])
                let ratio = micRMS / (aligned + 1e-9)
                let g = medianGain(default: ratio)
                if learnedGains.isEmpty || ratio < g * Self.overshoot {
                    learnedGains.append(ratio)
                    if learnedGains.count > 40 { learnedGains.removeFirst() }
                }
                if ratio <= g * Self.overshoot {
                    hangover = Self.hangoverEvals
                    setGate(true)
                } else {
                    setGate(false)      // double-talk: user over playback
                }
                return
            }
            // Weak correlation. Far side quiet? Ride the hangover, keep lock.
            if sysRMS < Self.silenceRMS {
                if gateOn && hangover > 0 { hangover -= 1; return }
                setGate(false)
                return
            }
            missCount += 1
            if missCount >= Self.unlockAfter {
                lockedDelay = nil; acquireDelays.removeAll()
                learnedGains.removeAll(); missCount = 0
                rtlog("echoGate: lock lost (sustained mismatch)")
            }
            if gateOn && hangover > 0 { hangover -= 1; return }
            setGate(false)
            return
        }

        // UNLOCKED: full acquisition search (both streams must be active).
        if sysRMS < Self.silenceRMS {
            setGate(false)
            return
        }
        let nOut = sys.count - m0.count + 1
        var corr = [Float](repeating: 0, count: nOut)
        sys.withUnsafeBufferPointer { s in
            m0.withUnsafeBufferPointer { f in
                vDSP_conv(s.baseAddress!, 1, f.baseAddress!, 1,
                          &corr, 1, vDSP_Length(nOut), vDSP_Length(m0.count))
            }
        }
        var sysSq = [Float](repeating: 0, count: sys.count)
        vDSP_vsq(sys, 1, &sysSq, 1, vDSP_Length(sys.count))
        var prefix = [Float](repeating: 0, count: sys.count + 1)
        var acc: Float = 0
        for i in 0..<sysSq.count { acc += sysSq[i]; prefix[i + 1] = acc }
        var best: Float = 0
        var bestIdx = -1
        for i in 0..<nOut {
            let e = sqrt(max(prefix[i + Self.micWin] - prefix[i], 0)) + 1e-9
            let c = corr[i] / (mNorm * e)
            if c > best { best = c; bestIdx = i }
        }
        guard best > Self.nccAcquire, bestIdx >= 0 else {
            acquireDelays.removeAll(); setGate(false)
            return
        }
        let delay = (sys.count - Self.micWin) - bestIdx
        acquireDelays.append(delay)
        if acquireDelays.count > 8 { acquireDelays.removeFirst() }
        if acquireDelays.count >= Self.stableCount {
            let tail = acquireDelays.suffix(Self.stableCount).sorted()
            let median = tail[tail.count / 2]
            if acquireDelays.suffix(Self.stableCount)
                .allSatisfy({ abs($0 - median) <= Self.delayJitter }) {
                lockedDelay = median
                missCount = 0
                let aligned = Self.rms(sys[bestIdx..<(bestIdx + Self.micWin)])
                learnedGains = [micRMS / (aligned + 1e-9)]
                hangover = Self.hangoverEvals
                rtlog("echoGate: lock acquired, delay=\(median * Self.decimation * 1000 / 16_000)ms")
                setGate(true)
                return
            }
        }
        setGate(false)
    }

    private func medianGain(default def: Float) -> Float {
        guard !learnedGains.isEmpty else { return def }
        return learnedGains.sorted()[learnedGains.count / 2]
    }

    private func setGate(_ on: Bool) {
        let changed = gateOn != on
        gateOn = on
        isGating = on
        if changed { onTransition?(on) }
    }
}
