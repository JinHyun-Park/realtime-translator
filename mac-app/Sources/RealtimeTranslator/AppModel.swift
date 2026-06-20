import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Diagnostic logger. Writes to BOTH stdout (for direct runs) and a fixed file
/// (so runs launched via `open`/Finder — which have no visible stdout — are
/// still observable). Append mode; flushed each line.
func rtlog(_ s: String) {
    let line = "RTDBG \(s)\n"
    print(line, terminator: "")
    fflush(stdout)
    let path = "/tmp/rt-app.log"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}

/// Persists every finalized translation line to disk THE MOMENT it arrives, so
/// nothing is lost if the app is quit/killed/crashes (no need to press Export).
/// Files live under ~/Documents/RealtimeTranslator/, one per session, named by
/// start time. Append-only; each write is flushed immediately.
final class TranscriptAutoSaver {
    private let url: URL
    private let q = DispatchQueue(label: "rt.autosave")
    private var started = false

    /// The folder that holds all autosaved transcripts.
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("RealtimeTranslator", isDirectory: true)
    }

    init(startedAt: Date) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "transcript-\(fmt.string(from: startedAt)).md"
        url = TranscriptAutoSaver.folder.appendingPathComponent(name)
    }

    var fileURL: URL { url }

    private func ensureFile() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(
            at: TranscriptAutoSaver.folder, withIntermediateDirectories: true)
        let header = "# Translation transcript\n\n_started \(Date())_\n\n"
        try? header.data(using: .utf8)?.write(to: url)
    }

    /// Append one finalized line. Called on the main actor; does file IO on a
    /// background queue so the UI never blocks.
    func append(stream: String, src: String, tgt: String, source: String, translation: String) {
        let who = stream == "mic" ? "🎙 Me" : "🔊 Them"
        let block = "- **\(who) · \(src.uppercased())** \(source)\n"
            + "  - **\(tgt.uppercased())** \(translation)\n"
        q.async { [weak self] in
            guard let self else { return }
            self.ensureFile()
            guard let data = block.data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: self.url) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            }
        }
    }
}

/// Tiny thread-safe counter for audio-flow diagnostics, written from background
/// audio callbacks and read from the UI timer. A plain lock keeps it race-free.
final class FlowCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _samples = 0, _chunks = 0
    func add(_ n: Int) { lock.lock(); _samples += n; _chunks += 1; lock.unlock() }
    func reset() { lock.lock(); _samples = 0; _chunks = 0; lock.unlock() }
    var snapshot: (samples: Int, chunks: Int) {
        lock.lock(); defer { lock.unlock() }; return (_samples, _chunks)
    }
}

/// Where the (personal, cost-guarded) GPU box is in its wake/boot cycle. The box
/// self-stops when idle, so the app must wake it and wait. CloudFront returns a
/// 504 while the origin is down (booting); once the relay's HTTP server answers
/// we read /healthz: vLLM warming => ready:false; model loaded => ready:true.
enum ServerPhase: Equatable {
    case idle               // nothing in flight; press Wake & Start
    case waking             // /wake request sent
    case booting            // box starting, /healthz unreachable (CloudFront 504)
    case warming            // relay up, 32B vLLM still loading (ready:false)
    case ready              // ready:true — capture can start
    case failed(String)     // wake/poll gave up (e.g. wrong password)

    /// True while we're actively waiting on the box to come up.
    var isTransitioning: Bool {
        switch self { case .waking, .booting, .warming: return true
        default: return false }
    }
}

/// Minimal decode of the relay's /healthz (booleans only — never leaks metrics).
private struct Healthz: Decodable { let ready: Bool }

/// Outcome of one /healthz probe, mapped straight onto the wake phases.
private enum Probe {
    case unreachable   // CloudFront 504 / timeout — box still booting
    case warming       // 200 but ready:false — relay up, 32B vLLM loading
    case ready         // 200 ready:true — go
}

/// One translated line shown in the transcript.
/// `id` is globally unique across sessions (epoch*1e6 + relay seq) so the
/// transcript can accumulate across stop/start without seq collisions.
struct Line: Identifiable {
    let id: Int
    var stream: String          // "mic" (me) | "system" (them)
    var source: String
    var translation: String
    var src: String
    var tgt: String
    var isFinal: Bool
}

@MainActor
final class AppModel: ObservableObject {
    // Connection
    // Default points at the SSM port-forward (deploy/connect.sh maps 18765 -> Tokyo:8765).
    // Team deployment: CloudFront edge (wss). For local dev via SSM tunnel use
    // ws://localhost:18765. Editable at runtime in the server field.
    @Published var serverURL = "wss://dv7fu8km0bcfp.cloudfront.net"
    // Access password (shared token). Appended as ?token=... on connect.
    // Persisted so the user types it once.
    @Published var accessKey: String = UserDefaults.standard.string(forKey: "accessKey") ?? "" {
        didSet { UserDefaults.standard.set(accessKey, forKey: "accessKey") }
    }
    @Published var connected = false
    @Published var running = false
    @Published var status = "Idle"

    // --- Server wake / readiness (personal box self-stops when idle) ---
    @Published var serverPhase: ServerPhase = .idle
    // Human-readable progress line shown under the Wake button, e.g.
    // "서버 깨우는 중… 모델 로딩 ~5분 남음".
    @Published var wakeDetail = ""
    // Measured cold wake→ready was ~350s (mostly 32B vLLM load). Used only for
    // the countdown estimate; readiness is decided by /healthz, not this clock.
    private let estimatedWakeSeconds = 360
    private var wakeStartedAt: Date?
    private var wakeTask: Task<Void, Never>?

    // --- Auto-stop (GPU cost guard) controls, mirrored to the server ---
    // The box self-stops after idleStopMinutes of zero capture UNLESS
    // autoStopEnabled is off. Persisted so the choice survives app restarts,
    // and re-pushed to the box on every wake (a stop/start resets the server to
    // its env defaults). autoStopApplied tracks whether the live box has our
    // current setting yet (for UI + to re-apply after wake).
    @Published var autoStopEnabled: Bool = (UserDefaults.standard.object(forKey: "autoStopEnabled") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(autoStopEnabled, forKey: "autoStopEnabled") }
    }
    @Published var idleStopMinutes: Int = (UserDefaults.standard.object(forKey: "idleStopMinutes") as? Int ?? 15) {
        didSet { UserDefaults.standard.set(idleStopMinutes, forKey: "idleStopMinutes") }
    }
    // Transient UI feedback for the control buttons (e.g. "자동끔 OFF 적용됨").
    @Published var idleControlStatus = ""

    // --- Translation model: local Qwen vs Claude Sonnet 4.6 (Bedrock) ---
    // useClaude=true routes translation to Claude on Bedrock (higher accuracy,
    // costs API $; on a throttle the server auto-falls-back to Qwen for that
    // call). Persisted and re-applied on every wake (the server resets to its
    // env default on stop/start). idleStatus-style transient feedback reused.
    @Published var useClaude: Bool = (UserDefaults.standard.object(forKey: "useClaude") as? Bool ?? false) {
        didSet { UserDefaults.standard.set(useClaude, forKey: "useClaude") }
    }
    @Published var llmControlStatus = ""

    // --- Sentence endpointing (when to break a sentence and translate it) ---
    // The relay finalizes a sentence on a long pause, a max-length flush, OR —
    // when punctEnabled — as soon as Whisper punctuates the interim AND there's a
    // tiny breath (punctSilenceMs). Lowering minSilenceMs makes finals land
    // sooner (snappier, but risks chopping a slow speaker). Persisted and
    // re-applied on every wake (server resets to env defaults on stop/start).
    // Defaults mirror backend/config.py so the UI shows the box's real state.
    @Published var minSilenceMs: Int = (UserDefaults.standard.object(forKey: "minSilenceMs") as? Int ?? 650) {
        didSet { UserDefaults.standard.set(minSilenceMs, forKey: "minSilenceMs") }
    }
    @Published var punctEnabled: Bool = (UserDefaults.standard.object(forKey: "punctEnabled") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(punctEnabled, forKey: "punctEnabled") }
    }
    @Published var punctSilenceMs: Int = (UserDefaults.standard.object(forKey: "punctSilenceMs") as? Int ?? 300) {
        didSet { UserDefaults.standard.set(punctSilenceMs, forKey: "punctSilenceMs") }
    }
    @Published var endpointControlStatus = ""

    // Language pair (KO<->JA default). The relay auto-detects which side spoke.
    @Published var langA = "ko"
    @Published var langB = "ja"

    // Audio sources
    @Published var captureSystemAudio = true
    @Published var captureMic = true
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?   // for monitoring choice

    // Transcript
    @Published var lines: [Line] = []
    // Two independent in-progress slots — mic and system can both be mid-sentence.
    @Published var micInterim: Line?
    @Published var sysInterim: Line?
    // Auto-saves every final line to disk so nothing is lost on quit/crash.
    private var autoSaver: TranscriptAutoSaver?
    @Published var autosavePath: String = ""

    // Live audio-flow indicator shown in the UI (so we don't depend on console logs).
    @Published var flowInfo = ""

    private let mic = MicCapture()
    private var sysCapture: AnyObject?     // SystemAudioCapture (macOS 13+)
    // Two independent relay connections — the backend is per-connection, so each
    // stream gets its own VAD/endpointing, whisper calls, and translation context.
    // No mixing: that's what was wrecking quality when mic+system were summed.
    private let micClient = RelayClient(name: "mic")
    private let sysClient = RelayClient(name: "system")
    private let deviceWatcher = AudioDeviceWatcher()
    // Bumped on every start() so relay seq (which resets per connection) maps to
    // a globally-unique line id and the transcript accumulates across sessions.
    private var epoch = 0

    init() {
        refreshDevices()
        // Keep the input/output pickers live: re-enumerate whenever a device is
        // plugged in/out or the system default changes.
        deviceWatcher.start { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
        let stateCB: (Bool) -> Void = { [weak self] _ in
            Task { @MainActor in self?.updateConnState() }
        }
        micClient.onState = stateCB
        sysClient.onState = stateCB
        micClient.onMessage = { [weak self] msg in
            Task { @MainActor in self?.handle(msg, stream: "mic") }
        }
        sysClient.onMessage = { [weak self] msg in
            Task { @MainActor in self?.handle(msg, stream: "system") }
        }
    }

    private func updateConnState() {
        connected = micClient.isConnected || sysClient.isConnected
        status = connected ? "Connected" : "Disconnected"
    }

    func refreshDevices() {
        inputDevices = AudioDevices.inputs()
        outputDevices = AudioDevices.outputs()
        // If the currently-selected device went away, fall back to system default.
        if let sel = selectedInputID, !inputDevices.contains(where: { $0.id == sel }) {
            selectedInputID = nil
        }
        if let sel = selectedOutputID, !outputDevices.contains(where: { $0.id == sel }) {
            selectedOutputID = nil
        }
    }

    // MARK: - Wake & readiness

    /// Derive https origin + token from the wss serverURL the user already has.
    /// CloudFront serves wss (capture), /view, /healthz and /wake off ONE host,
    /// so we just swap the scheme. Returns nil if the URL is unusable.
    private func httpBase() -> URL? {
        guard var comp = URLComponents(string: serverURL) else { return nil }
        comp.scheme = (comp.scheme == "ws") ? "http" : "https"   // wss -> https
        comp.path = ""; comp.query = nil; comp.fragment = nil
        return comp.url
    }

    /// Open the broadcast viewer page (`/view`) in the default browser — the same
    /// live-subtitle page teammates use. The password rides as `?key=...` so it
    /// connects without prompting (viewer.html reads `key`, saves to localStorage).
    /// This opens on YOUR machine, so embedding the token is fine; to hand the URL
    /// to others, share the bare `/view` link and let them type the password.
    func openViewerPage() {
        guard let base = httpBase() else { status = "서버 주소 오류"; return }
        var comp = URLComponents(url: base.appendingPathComponent("view"),
                                 resolvingAgainstBaseURL: false)
        if !accessKey.isEmpty {
            comp?.queryItems = [URLQueryItem(name: "key", value: accessKey)]
        }
        guard let url = comp?.url else { status = "뷰어 URL 생성 실패"; return }
        rtlog("openViewerPage \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Auto-stop control (cost guard)

    /// Build a /control/<action> URL with the token + query params. Token rides
    /// as ?token= AND we also send X-Wake-Token (server accepts either).
    private func controlURL(_ action: String, _ items: [URLQueryItem]) -> URL? {
        guard let base = httpBase() else { return nil }
        var comp = URLComponents(url: base.appendingPathComponent(action),
                                 resolvingAgainstBaseURL: false)
        var q = items
        if !accessKey.isEmpty { q.append(URLQueryItem(name: "token", value: accessKey)) }
        comp?.queryItems = q
        return comp?.url
    }

    /// Push the current auto-stop preference (enabled + minutes) to the live box.
    /// Called from the toggle/buttons and automatically right after a wake (the
    /// server resets to env defaults on every stop/start, so we re-assert).
    func applyIdleSetting() {
        let enabled = autoStopEnabled
        let seconds = max(1, idleStopMinutes) * 60
        guard let url = controlURL("control/idle", [
            URLQueryItem(name: "enabled", value: enabled ? "1" : "0"),
            URLQueryItem(name: "seconds", value: String(seconds)),
        ]) else { idleControlStatus = "서버 주소 오류"; return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        rtlog("applyIdleSetting enabled=\(enabled) seconds=\(seconds)")
        Task { [weak self] in
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    if code == 401 || code == 403 {
                        self?.idleControlStatus = "비밀번호 오류 — 설정 미적용"
                    } else if code == 200 {
                        self?.idleControlStatus = enabled
                            ? "자동끔 ON (\(self?.idleStopMinutes ?? 0)분)"
                            : "자동끔 OFF — 수동으로 끌 때까지 안 꺼짐"
                    } else if code == 502 || code == 504 {
                        self?.idleControlStatus = "서버 꺼져 있음 — 깨운 뒤 자동 적용"
                    } else {
                        self?.idleControlStatus = "적용 실패 (\(code))"
                    }
                }
            } catch {
                await MainActor.run { self?.idleControlStatus = "서버 응답 없음 (꺼져 있을 수 있음)" }
            }
        }
    }

    /// Push the translation-model choice (Qwen vs Claude) to the live box.
    /// Called from the toggle and re-applied after every wake (server resets to
    /// its env default on stop/start).
    func applyLLMSetting() {
        let provider = useClaude ? "bedrock" : "vllm"
        guard let url = controlURL("control/llm", [
            URLQueryItem(name: "provider", value: provider),
        ]) else { llmControlStatus = "서버 주소 오류"; return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        rtlog("applyLLMSetting provider=\(provider)")
        Task { [weak self] in
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    if code == 401 || code == 403 {
                        self?.llmControlStatus = "비밀번호 오류 — 설정 미적용"
                    } else if code == 200 {
                        self?.llmControlStatus = (self?.useClaude ?? false)
                            ? "번역: Claude Sonnet 4.6 (정확도↑)"
                            : "번역: Qwen 3-32B (로컬·무료)"
                    } else if code == 502 || code == 504 {
                        self?.llmControlStatus = "서버 꺼져 있음 — 깨운 뒤 자동 적용"
                    } else {
                        self?.llmControlStatus = "적용 실패 (\(code))"
                    }
                }
            } catch {
                await MainActor.run { self?.llmControlStatus = "서버 응답 없음 (꺼져 있을 수 있음)" }
            }
        }
    }

    /// Push the sentence-endpointing knobs (silence threshold + punctuation
    /// early-finalize) to the live box. Called from the slider/toggle and
    /// re-applied after every wake (the server resets to env defaults on
    /// stop/start). The server clamps each value, so out-of-range is harmless.
    func applyEndpointSetting() {
        let silence = max(300, min(3000, minSilenceMs))
        let punctMs = max(0, min(1500, punctSilenceMs))
        guard let url = controlURL("control/endpoint", [
            URLQueryItem(name: "silence_ms", value: String(silence)),
            URLQueryItem(name: "punct", value: punctEnabled ? "1" : "0"),
            URLQueryItem(name: "punct_ms", value: String(punctMs)),
        ]) else { endpointControlStatus = "서버 주소 오류"; return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        rtlog("applyEndpointSetting silence=\(silence) punct=\(punctEnabled) punctMs=\(punctMs)")
        Task { [weak self] in
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    if code == 401 || code == 403 {
                        self?.endpointControlStatus = "비밀번호 오류 — 설정 미적용"
                    } else if code == 200 {
                        let s = self?.minSilenceMs ?? 0
                        self?.endpointControlStatus = (self?.punctEnabled ?? false)
                            ? "문장 끊기: 침묵 \(s)ms + 구두점 조기확정 ON"
                            : "문장 끊기: 침묵 \(s)ms (구두점 조기확정 OFF)"
                    } else if code == 502 || code == 504 {
                        self?.endpointControlStatus = "서버 꺼져 있음 — 깨운 뒤 자동 적용"
                    } else {
                        self?.endpointControlStatus = "적용 실패 (\(code))"
                    }
                }
            } catch {
                await MainActor.run { self?.endpointControlStatus = "서버 응답 없음 (꺼져 있을 수 있음)" }
            }
        }
    }

    /// Manual kill switch: stop the GPU box right now, regardless of auto-stop.
    /// Use after a meeting to stop paying immediately instead of waiting out the
    /// idle timer. If capture is running we stop it first (clean shutdown).
    func stopServerNow() {
        if running { stop() }
        guard let url = controlURL("control/stop", []) else {
            idleControlStatus = "서버 주소 오류"; return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        rtlog("stopServerNow")
        idleControlStatus = "서버 끄는 중…"
        Task { [weak self] in
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    switch code {
                    case 200:        self?.idleControlStatus = "서버 끄는 중 — 과금 곧 멈춤"
                    case 401, 403:   self?.idleControlStatus = "비밀번호 오류 — 못 껐어요"
                    case 502, 504:   self?.idleControlStatus = "이미 꺼져 있어요"
                    default:         self?.idleControlStatus = "끄기 실패 (\(code))"
                    }
                    self?.serverPhase = .idle
                }
            } catch {
                await MainActor.run { self?.idleControlStatus = "이미 꺼져 있거나 응답 없음" }
            }
        }
    }

    /// One-tap: wake the box (if asleep), wait until /healthz says ready, then
    /// auto-press Start. Safe to call when already up — /healthz returns ready
    /// immediately and we Start without booting anything. Idempotent: a second
    /// tap while transitioning is ignored.
    func wakeAndStart() {
        guard !running, !serverPhase.isTransitioning else { return }
        guard let base = httpBase() else { serverPhase = .failed("서버 주소 오류"); return }
        wakeStartedAt = Date()
        serverPhase = .waking
        wakeDetail = "서버 깨우는 중…"
        rtlog("wakeAndStart base=\(base.absoluteString)")
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in await self?.runWake(base: base) }
    }

    /// Cancel an in-progress wake/poll (the box keeps doing whatever it's doing;
    /// we just stop waiting and reset the UI).
    func cancelWake() {
        wakeTask?.cancel(); wakeTask = nil
        serverPhase = .idle; wakeDetail = ""
    }

    private func runWake(base: URL) async {
        // 1) Kick the box. /wake is idempotent: running -> reports state, stopped
        //    -> start_instances. A non-2xx with a token present == bad password.
        let wakeURL = base.appendingPathComponent("wake")
        var req = URLRequest(url: wakeURL, timeoutInterval: 12)
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                await MainActor.run {
                    self.serverPhase = .failed("비밀번호가 틀렸어요")
                    self.wakeDetail = ""
                }
                return
            }
            await MainActor.run { self.serverPhase = .booting }
        } catch {
            // The wake endpoint itself being unreachable is unusual (it's the
            // always-on Lambda via CloudFront) — surface it but still try polling
            // in case the box is actually coming up.
            rtlog("wake POST failed: \(error.localizedDescription)")
            await MainActor.run { self.serverPhase = .booting }
        }

        // 2) Poll /healthz until ready (or cancelled). The HTTP signal drives the
        //    phase directly: 504/timeout = booting; 200 ready:false = warming;
        //    200 ready:true = go.
        let healthURL = base.appendingPathComponent("healthz")
        while !Task.isCancelled {
            let probe = await Self.probeReady(healthURL)
            if Task.isCancelled { return }
            if case .ready = probe {
                await MainActor.run { self.onServerReady() }
                return
            }
            await MainActor.run { self.tickWakeProgress(probe) }
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        }
    }

    /// GET /healthz with a cache-buster. 200+ready:true => .ready; 200 otherwise
    /// => .warming; any error / non-200 (CloudFront 504 while origin down) =>
    /// .unreachable (still booting).
    private static func probeReady(_ healthURL: URL) async -> Probe {
        var comp = URLComponents(url: healthURL, resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "cb", value: UUID().uuidString)]
        guard let url = comp?.url else { return .unreachable }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .unreachable }
            let ready = (try? JSONDecoder().decode(Healthz.self, from: data))?.ready ?? false
            return ready ? .ready : .warming
        } catch { return .unreachable }
    }

    /// Drive phase + countdown text off the latest probe.
    private func tickWakeProgress(_ probe: Probe) {
        guard serverPhase.isTransitioning else { return }
        let elapsed = Int(Date().timeIntervalSince(wakeStartedAt ?? Date()))
        let remain = max(0, estimatedWakeSeconds - elapsed)
        let mins = (remain + 59) / 60
        switch probe {
        case .unreachable:
            serverPhase = .booting
            wakeDetail = remain > 0
                ? "서버 부팅 중… 약 \(mins)분 남음"
                : "서버 부팅 중…"
        case .warming:
            // Relay is up; the long pole is the 32B model load.
            serverPhase = .warming
            wakeDetail = remain > 0
                ? "모델 로딩 중… 약 \(mins)분 남음"
                : "모델 로딩 중… 거의 다 됐어요"
        case .ready:
            break   // handled in onServerReady
        }
    }

    /// /healthz said ready — notify the user and auto-start capture.
    private func onServerReady() {
        serverPhase = .ready
        wakeDetail = "준비 완료 — 시작합니다"
        wakeTask = nil
        notifyReady()
        // The box just (re)booted, so its auto-stop, translation-model choice AND
        // sentence-endpointing knobs are back at the env defaults. Re-assert all
        // saved preferences now.
        applyIdleSetting()
        applyLLMSetting()
        applyEndpointSetting()
        // Auto-press Start so one tap = end-to-end. If the user already pressed
        // Stop in the meantime we respect that (running guard inside start()).
        if !running { start() }
    }

    /// Gentle "your server is ready" ping: system sound + dock bounce, so the
    /// user can look away during the ~6-min wake and get pulled back.
    private func notifyReady() {
        NSSound(named: "Glass")?.play()
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: - Lifecycle

    func start() {
        rtlog("start() called; url=\(serverURL) micOn=\(captureMic) sysOn=\(captureSystemAudio) inputID=\(String(describing: selectedInputID)) screenPreflight=\(CGPreflightScreenCaptureAccess()) pid=\(ProcessInfo.processInfo.processIdentifier)")
        // Append the access token as a query param (the relay validates it).
        var comp = URLComponents(string: serverURL)
        if !accessKey.isEmpty {
            var q = comp?.queryItems ?? []
            q.append(URLQueryItem(name: "token", value: accessKey))
            comp?.queryItems = q
        }
        guard let url = comp?.url else {
            status = "Bad server URL"; return
        }
        // Keep prior transcript — a new session continues appending below it.
        epoch += 1
        micInterim = nil; sysInterim = nil
        micFlow.reset(); sysFlow.reset()

        // New autosave file per Start — every final line is written to disk
        // immediately, so a quit/crash never loses the transcript.
        let saver = TranscriptAutoSaver(startedAt: Date())
        autoSaver = saver
        autosavePath = saver.fileURL.path

        // mic = my side (my language first); system = the remote side (their
        // language first). Flipping the pair makes each stream translate toward
        // the other language even when whisper detects the expected source.
        if captureMic {
            micClient.connect(url: url)
            micClient.setPair(langA, langB)
            requestMicThenStart()
        }
        if captureSystemAudio {
            sysClient.connect(url: url)
            sysClient.setPair(langB, langA)
            startSystemAudio()
        }

        running = true
        status = "Listening…"
        serverPhase = .ready   // we're capturing; clear any wake-progress text
        wakeDetail = ""
        dbgTimer?.invalidate()
        dbgTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let m = self.micFlow.snapshot, s = self.sysFlow.snapshot
                self.flowInfo = "mic \(m.samples/1000)k→\(m.chunks) [\(self.micClient.isConnected ? "✓" : "✗")] · sys \(s.samples/1000)k→\(s.chunks) [\(self.sysClient.isConnected ? "✓" : "✗")]"
            }
        }
    }

    // Per-stream audio-flow counters (thread-safe; written from audio callbacks).
    private let micFlow = FlowCounter()
    private let sysFlow = FlowCounter()
    private var dbgTimer: Timer?

    private func requestMicThenStart() {
        let begin: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                try self.mic.setInputDevice(self.selectedInputID)
                self.mic.onSamples = { [weak self] s in
                    guard let self else { return }
                    self.micFlow.add(s.count)
                    self.micClient.sendAudio(floatsToPCM16(s))
                }
                try self.mic.start()
                rtlog("mic.start() OK device=\(String(describing: self.selectedInputID))")
            } catch {
                self.status = "Mic error: \(error.localizedDescription)"
                rtlog("mic.start() FAILED: \(error.localizedDescription)")
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            status = "Requesting mic permission…"
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { begin() }
                    else { self.status = "Mic permission DENIED — System Settings ▸ Privacy ▸ Microphone" }
                }
            }
        default:
            status = "Mic permission denied — System Settings ▸ Privacy ▸ Microphone"
        }
    }

    private func startSystemAudio() {
        if #available(macOS 13.0, *) {
            let cap = SystemAudioCapture()
            cap.onSamples = { [weak self] s in
                guard let self else { return }
                self.sysFlow.add(s.count)
                self.sysClient.sendAudio(floatsToPCM16(s))
            }
            sysCapture = cap
            Task {
                do {
                    try await cap.start()
                    rtlog("systemAudio.start() OK")
                } catch {
                    await MainActor.run {
                        self.status = "System audio error: \(error.localizedDescription)"
                    }
                    rtlog("systemAudio.start() FAILED: \(error.localizedDescription)")
                }
            }
        } else {
            status = "System audio needs macOS 13+"
        }
    }

    func stop() {
        wakeTask?.cancel(); wakeTask = nil
        dbgTimer?.invalidate(); dbgTimer = nil
        mic.stop()
        if #available(macOS 13.0, *), let cap = sysCapture as? SystemAudioCapture {
            cap.stop()
        }
        sysCapture = nil
        micClient.disconnect()
        sysClient.disconnect()
        running = false
        status = "Stopped"
        serverPhase = .idle
        wakeDetail = ""
    }

    func swapLanguages() {
        swap(&langA, &langB)
        if running { micClient.setPair(langA, langB); sysClient.setPair(langB, langA) }
    }

    // MARK: - Relay messages

    /// Map a per-connection relay seq to a globally-unique line id. The two
    /// streams have independent seq spaces (one per socket), so partition the
    /// range per stream to avoid collisions within an epoch.
    private func lineID(_ seq: Int, stream: String) -> Int {
        let base = stream == "mic" ? 0 : 500_000
        return epoch * 1_000_000 + base + seq
    }

    private func handle(_ msg: RelayMessage, stream: String) {
        switch msg.type {
        case "error":
            status = "Relay(\(stream)): \(msg.message ?? "error")"
        case "interim":
            guard let seq = msg.seq else { return }
            let l = Line(
                id: lineID(seq, stream: stream), stream: stream,
                source: msg.source ?? "",
                translation: msg.translation ?? "",
                src: msg.src ?? "", tgt: msg.tgt ?? "",
                isFinal: false
            )
            if stream == "mic" { micInterim = l } else { sysInterim = l }
        case "final":
            guard let seq = msg.seq else { return }
            let uid = lineID(seq, stream: stream)
            let line = Line(
                id: uid, stream: stream,
                source: msg.source ?? "",
                translation: msg.translation ?? "",
                src: msg.src ?? "", tgt: msg.tgt ?? "",
                isFinal: true
            )
            let isNew = !lines.contains(where: { $0.id == uid })
            if let idx = lines.firstIndex(where: { $0.id == uid }) {
                lines[idx] = line
            } else {
                lines.append(line)
            }
            // Persist each NEW final to disk immediately (crash/quit-proof).
            if isNew, !line.translation.isEmpty {
                autoSaver?.append(stream: stream, src: line.src, tgt: line.tgt,
                                  source: line.source, translation: line.translation)
            }
            if stream == "mic", micInterim?.id == uid { micInterim = nil }
            if stream == "system", sysInterim?.id == uid { sysInterim = nil }
        default:
            break
        }
    }

    // MARK: - Transcript actions

    /// Explicitly clear the accumulated transcript (the only way to wipe it —
    /// start/stop preserves it). Note: does NOT delete autosaved files on disk.
    func clearTranscript() {
        lines.removeAll()
        micInterim = nil; sysInterim = nil
    }

    /// Reveal the auto-saved transcripts folder in Finder.
    func revealAutosaveFolder() {
        let folder = TranscriptAutoSaver.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting(
            autosavePath.isEmpty ? [folder] : [URL(fileURLWithPath: autosavePath)])
    }

    /// Render the full transcript as Markdown, labeled by speaker.
    func transcriptMarkdown() -> String {
        var out = "# Translation transcript\n\n"
        for l in lines {
            let who = l.stream == "mic" ? "🎙 Me" : "🔊 Them"
            out += "- **\(who) · \(l.src.uppercased())** \(l.source)\n"
            out += "  - **\(l.tgt.uppercased())** \(l.translation)\n"
        }
        return out
    }

    /// Save the transcript to a .md file via a save panel. Returns nothing;
    /// updates `status` with the result.
    func exportMarkdown() {
        guard !lines.isEmpty else { status = "Nothing to export"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = "translation-transcript.md"
        panel.begin { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            do {
                try self.transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in self.status = "Saved \(url.lastPathComponent)" }
            } catch {
                Task { @MainActor in self.status = "Save failed: \(error.localizedDescription)" }
            }
        }
    }
}
