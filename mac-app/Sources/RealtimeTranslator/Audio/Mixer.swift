import Foundation

/// Mixes two 16 kHz mono Float streams (system audio + mic) into fixed-size
/// PCM16 chunks. Sources push samples whenever they have them; a timer pulls
/// aligned chunks and sums them (with soft clipping) so both voices are heard.
///
/// Thread-safe via a serial queue.
final class Mixer {
    /// 20 ms at 16 kHz = 320 samples. The relay re-frames anyway.
    private let chunkSamples = 320
    private let q = DispatchQueue(label: "rt.mixer")
    private var sys: [Float] = []
    private var mic: [Float] = []
    private var timer: DispatchSourceTimer?

    /// Called with little-endian PCM16 Data for each mixed chunk.
    var onChunk: ((Data) -> Void)?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        // Pull a chunk every 20 ms.
        t.schedule(deadline: .now() + 0.02, repeating: 0.02)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        q.sync { sys.removeAll(); mic.removeAll() }
    }

    func pushSystem(_ s: [Float]) { q.async { self.sys.append(contentsOf: s) } }
    func pushMic(_ s: [Float]) { q.async { self.mic.append(contentsOf: s) } }

    private func drain() {
        // Emit as many full chunks as both/either buffer can supply. We key off
        // whichever buffer is longer so a silent source never stalls the other.
        while max(sys.count, mic.count) >= chunkSamples {
            var out = [Float](repeating: 0, count: chunkSamples)
            if sys.count >= chunkSamples {
                for i in 0..<chunkSamples { out[i] += sys[i] }
                sys.removeFirst(chunkSamples)
            } else if !sys.isEmpty {
                for i in 0..<sys.count { out[i] += sys[i] }
                sys.removeAll()
            }
            if mic.count >= chunkSamples {
                for i in 0..<chunkSamples { out[i] += mic[i] }
                mic.removeFirst(chunkSamples)
            } else if !mic.isEmpty {
                for i in 0..<mic.count { out[i] += mic[i] }
                mic.removeAll()
            }
            // Soft clip the sum of the two sources.
            for i in 0..<chunkSamples { out[i] = max(-1.0, min(1.0, out[i])) }
            onChunk?(floatsToPCM16(out))
        }
    }
}
