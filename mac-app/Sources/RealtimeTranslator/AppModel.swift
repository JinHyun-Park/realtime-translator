import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// App configuration. `defaultServerURL` is the relay URL shown on first run,
/// before the user enters their own (which is then persisted). It is EMPTY by
/// default: a PUBLIC distributable .dmg must NOT ship someone else's box URL
/// baked in, or every recipient would point at the author's server.
///
/// A build CAN bake one in (e.g. a .dmg shared with one trusted person who
/// should use the author's existing box) by setting RT_DEFAULT_SERVER_URL when
/// building — bundle.sh rewrites the marker line below. The token is NEVER baked
/// in either way; the user always enters the password themselves.
enum AppConfig {
    // BUILD-INJECTED: bundle.sh replaces the value below when RT_DEFAULT_SERVER_URL is set.
    static let defaultServerURL = ""  // RT_DEFAULT_SERVER_URL
    // BUILD-INJECTED: bundle.sh stamps these from the VERSION file + build date.
    static let version = "dev"          // RT_VERSION
    static let buildDate = ""           // RT_BUILD_DATE
    /// e.g. "v1.3 (2026-06-21)" — shown small at the bottom of the control panel
    /// so a recipient can tell which build they're on.
    static var versionLabel: String {
        buildDate.isEmpty ? version : "\(version) (\(buildDate))"
    }
}

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
    // The relay URL. Persisted so each user types their own CloudFront/host once
    // and it sticks across launches. The first-run default is EMPTY for the
    // distributable build — a shared .dmg must NOT ship someone else's box URL
    // baked in (that would point every recipient at the author's server). A
    // private build can bake one in via the RT_DEFAULT_SERVER_URL build setting
    // (see AppConfig.defaultServerURL). For local dev use ws://localhost:18765.
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL")
        ?? AppConfig.defaultServerURL {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    // Access password (shared token). Appended as ?token=... on connect.
    // Persisted so the user types it once.
    @Published var accessKey: String = UserDefaults.standard.string(forKey: "accessKey") ?? "" {
        didSet { UserDefaults.standard.set(accessKey, forKey: "accessKey") }
    }
    // Room/meeting id — appended as ?room=... so concurrent users on the SAME box
    // stay ISOLATED (each app install gets its own stable random room, so two
    // people in different meetings never see each other's subtitles). Editable so
    // teammates who WANT to share one broadcast can type the same room. Persisted.
    @Published var roomID: String = {
        if let r = UserDefaults.standard.string(forKey: "roomID"), !r.isEmpty { return r }
        let r = "r-" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(r, forKey: "roomID")
        return r
    }() {
        didSet {
            let v = roomID.trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(v.isEmpty ? "default" : v, forKey: "roomID")
        }
    }
    // Optional per-room secret (opt-in privacy). Sent as ?rs=... on connect.
    // Leave blank for an open room; set one and your room locks to it (the first
    // connection with a secret claims the room — TOFU). Persisted. NOT the same
    // as the relay access password (that's box entry; this is room entry).
    @Published var roomSecret: String = UserDefaults.standard.string(forKey: "roomSecret") ?? "" {
        didSet { UserDefaults.standard.set(roomSecret, forKey: "roomSecret") }
    }
    // App UI language (ko/ja/en). Persisted; drives L10n + the language sent to
    // the server so insight/summary come back in the same language. Defaults to
    // the macOS preferred language if it's one we support, else Korean.
    @Published var uiLanguage: UILang = {
        if let saved = UserDefaults.standard.string(forKey: "uiLanguage"),
           let l = UILang(rawValue: saved) { return l }
        let pref = Locale.preferredLanguages.first ?? "ko"
        let l: UILang = pref.hasPrefix("ja") ? .ja : (pref.hasPrefix("en") ? .en : .ko)
        return l
    }() {
        didSet {
            UserDefaults.standard.set(uiLanguage.rawValue, forKey: "uiLanguage")
            L10n.lang = uiLanguage
            objectWillChange.send()   // re-render all views in the new language
        }
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

    // --- Idle auto-stop: DISABLED from the app side ---
    // This is a SHARED relay meant to stay always-on, so the app no longer lets
    // a user stop the box or toggle idle-shutdown (the UI panel was removed).
    // On every wake we push idle-stop OFF so a server-side env default can't
    // silently start shutting the shared box down under people. (The operator
    // manages cost out-of-band.)

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
    // Result of the last "clear viewers" panic wipe (shown next to the button).
    @Published var clearViewersStatus = ""

    // --- Live insight (meeting copilot over the transcript) -------------------
    // SEPARATE from translation. When enabled, every N new finals the app POSTs
    // the recent transcript + the user's free-text context to /insight and shows
    // a rolling summary + suggested questions; a manual "wrap up" produces key
    // points + next actions. OFF => the app never calls => zero added cost.
    @Published var insightEnabled: Bool = (UserDefaults.standard.object(forKey: "insightEnabled") as? Bool ?? false) {
        didSet { UserDefaults.standard.set(insightEnabled, forKey: "insightEnabled") }
    }
    // Free-text role/goals, e.g. "I'm the interviewer; probe system-design depth."
    // Becomes part of the insight system prompt. Persisted across sessions.
    @Published var insightContext: String = UserDefaults.standard.string(forKey: "insightContext") ?? "" {
        didSet { UserDefaults.standard.set(insightContext, forKey: "insightContext") }
    }
    // Refresh cadence: ask for a live insight every this-many new finals.
    @Published var insightEveryN: Int = (UserDefaults.standard.object(forKey: "insightEveryN") as? Int ?? 5) {
        didSet { UserDefaults.standard.set(insightEveryN, forKey: "insightEveryN") }
    }
    // Live results (replaced each refresh).
    @Published var liveSummary = ""
    @Published var suggestedQuestions: [String] = []
    // End-of-meeting wrap.
    @Published var finalSummary = ""
    @Published var keyPoints: [String] = []
    @Published var nextActions: [String] = []
    // UI feedback + in-flight guard so refreshes don't pile up.
    @Published var insightStatus = ""
    @Published var insightBusy = false
    // Counts finals since the last live refresh; when it hits insightEveryN we
    // fire a refresh and reset. Reset on Start so each meeting batches cleanly.
    private var finalsSinceInsight = 0

    // Language pair (KO<->JA default). The relay auto-detects which side spoke.
    // Persisted so your chosen pair sticks instead of resetting to KO/JA each launch.
    @Published var langA: String = UserDefaults.standard.string(forKey: "langA") ?? "ko" {
        didSet { UserDefaults.standard.set(langA, forKey: "langA") }
    }
    @Published var langB: String = UserDefaults.standard.string(forKey: "langB") ?? "ja" {
        didSet { UserDefaults.standard.set(langB, forKey: "langB") }
    }

    // Audio sources — persisted so your capture choices stick across launches.
    @Published var captureSystemAudio: Bool =
        (UserDefaults.standard.object(forKey: "captureSystemAudio") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(captureSystemAudio, forKey: "captureSystemAudio") }
    }
    @Published var captureMic: Bool =
        (UserDefaults.standard.object(forKey: "captureMic") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(captureMic, forKey: "captureMic") }
    }
    // Mic echo cancellation (AEC) — for SPEAKER users whose meeting audio leaks
    // back into the mic and shows up duplicated as ME. OFF by default: voice
    // processing on an input-only engine can yield silent buffers on some
    // device combos, which looks like "my mic stopped working".
    @Published var micAEC: Bool =
        (UserDefaults.standard.object(forKey: "micAEC") as? Bool ?? false) {
        didSet { UserDefaults.standard.set(micAEC, forKey: "micAEC") }
    }
    // Echo gate — OUR replacement for AEC (which ducked system volume and muted
    // the mic in the field): correlates the mic against the system-audio stream
    // and drops mic chunks that are just the speaker's sound re-entering.
    // Device-independent, touches nothing outside this app. Default ON; no-op
    // for headset users (no acoustic leak -> no stable correlation).
    @Published var echoGateEnabled: Bool =
        (UserDefaults.standard.object(forKey: "echoGateEnabled") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(echoGateEnabled, forKey: "echoGateEnabled") }
    }
    /// Live indicator: the gate is currently suppressing mic input (echo heard).
    @Published var echoGateActive = false
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    // Selected audio devices, persisted by device UID-ish ID. NOTE: AudioDeviceID
    // is a runtime handle that CAN change across reboots/replug; we restore it
    // only if the saved ID still exists in the enumerated device list (see
    // refreshDevices), otherwise we fall back to the system default.
    @Published var selectedInputID: AudioDeviceID? =
        (UserDefaults.standard.object(forKey: "selectedInputID") as? UInt32).map { AudioDeviceID($0) } {
        didSet {
            if let id = selectedInputID { UserDefaults.standard.set(Int(id), forKey: "selectedInputID") }
            else { UserDefaults.standard.removeObject(forKey: "selectedInputID") }
        }
    }
    @Published var selectedOutputID: AudioDeviceID? =
        (UserDefaults.standard.object(forKey: "selectedOutputID") as? UInt32).map { AudioDeviceID($0) } {
        didSet {
            if let id = selectedOutputID { UserDefaults.standard.set(Int(id), forKey: "selectedOutputID") }
            else { UserDefaults.standard.removeObject(forKey: "selectedOutputID") }
        }
    }

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
    private let echoGate = EchoGate()
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
        L10n.lang = uiLanguage          // localize from the very first render
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
        // Enumerate devices OFF the main thread: AudioDevices.* calls into the
        // CoreAudio HAL (AudioObjectGetPropertyData), which BLOCKS if coreaudiod
        // is busy/wedged — and on the main thread that freezes the whole UI. We
        // compute on a background queue and hop back only to assign @Published.
        DispatchQueue.global(qos: .userInitiated).async {
            let ins = AudioDevices.inputs()
            let outs = AudioDevices.outputs()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inputDevices = ins
                self.outputDevices = outs
                // If a selected device went away, fall back to system default.
                if let sel = self.selectedInputID, !ins.contains(where: { $0.id == sel }) {
                    self.selectedInputID = nil
                }
                if let sel = self.selectedOutputID, !outs.contains(where: { $0.id == sel }) {
                    self.selectedOutputID = nil
                }
            }
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

    /// The room id actually sent on the wire: trimmed, or "default" if blank.
    var effectiveRoom: String {
        let v = roomID.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "default" : v
    }

    /// Open the broadcast viewer page (`/view`) in the default browser — the same
    /// live-subtitle page teammates use. The password rides as `?key=...` so it
    /// connects without prompting (viewer.html reads `key`, saves to localStorage).
    /// `room` MUST match this capture's room or the viewer sees nothing. This opens
    /// on YOUR machine, so embedding the token is fine; to hand the URL to others,
    /// share it (it carries the room) and let them type the password.
    func openViewerPage() {
        guard let base = httpBase() else { status = L10n.t("st.serverURLError"); return }
        var comp = URLComponents(url: base.appendingPathComponent("view"),
                                 resolvingAgainstBaseURL: false)
        var q = [URLQueryItem(name: "room", value: effectiveRoom)]
        if !accessKey.isEmpty { q.append(URLQueryItem(name: "key", value: accessKey)) }
        if !roomSecret.isEmpty { q.append(URLQueryItem(name: "rs", value: roomSecret)) }
        comp?.queryItems = q
        guard let url = comp?.url else { status = L10n.t("st.viewerURLFail"); return }
        rtlog("openViewerPage \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    /// Open THIS ROOM's past-session history (transcripts + auto summaries) in the
    /// browser. Carries room + password (+ room secret if set) so it opens without
    /// prompting. Shows only this room's sessions (server enforces room match).
    func openHistoryPage() {
        guard let base = httpBase() else { status = L10n.t("st.serverURLError"); return }
        var comp = URLComponents(url: base.appendingPathComponent("history"),
                                 resolvingAgainstBaseURL: false)
        var q = [URLQueryItem(name: "room", value: effectiveRoom),
                 URLQueryItem(name: "lang", value: uiLanguage.rawValue)]
        if !accessKey.isEmpty { q.append(URLQueryItem(name: "key", value: accessKey)) }
        if !roomSecret.isEmpty { q.append(URLQueryItem(name: "rs", value: roomSecret)) }
        comp?.queryItems = q
        guard let url = comp?.url else { status = L10n.t("st.historyURLFail"); return }
        rtlog("openHistoryPage \(url.absoluteString)")
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

    /// Keep the shared box always-on: push idle-stop OFF on every wake so a
    /// server-side env default can't start shutting it down under other users.
    /// (No UI — the auto-stop / stop-now panel was removed for the shared relay.)
    func disableIdleStop() {
        guard let url = controlURL("control/idle", [
            URLQueryItem(name: "enabled", value: "0"),
        ]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        rtlog("disableIdleStop (shared box stays always-on)")
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    /// Push the translation-model choice (Qwen vs Claude) to the live box.
    /// Called from the toggle and re-applied after every wake (server resets to
    /// its env default on stop/start).
    func applyLLMSetting() {
        let provider = useClaude ? "bedrock" : "vllm"
        guard let url = controlURL("control/llm", [
            URLQueryItem(name: "provider", value: provider),
        ]) else { llmControlStatus = L10n.t("st.serverURLError"); return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        rtlog("applyLLMSetting provider=\(provider)")
        Task { [weak self] in
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    if code == 401 || code == 403 {
                        self?.llmControlStatus = L10n.t("st.pwErrorNotApplied")
                    } else if code == 200 {
                        self?.llmControlStatus = (self?.useClaude ?? false)
                            ? L10n.t("st.transOnClaude")
                            : L10n.t("st.transOnQwen")
                    } else if code == 502 || code == 504 {
                        self?.llmControlStatus = L10n.t("st.serverOffReapply")
                    } else {
                        self?.llmControlStatus = L10n.t("st.applyFail", "\(code)")
                    }
                }
            } catch {
                await MainActor.run { self?.llmControlStatus = L10n.t("st.noResponseMaybeOff") }
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
        ]) else { endpointControlStatus = L10n.t("st.serverURLError"); return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        rtlog("applyEndpointSetting silence=\(silence) punct=\(punctEnabled) punctMs=\(punctMs)")
        Task { [weak self] in
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    if code == 401 || code == 403 {
                        self?.endpointControlStatus = L10n.t("st.pwErrorNotApplied")
                    } else if code == 200 {
                        let s = self?.minSilenceMs ?? 0
                        self?.endpointControlStatus = (self?.punctEnabled ?? false)
                            ? L10n.t("st.endpointPunctOn", s)
                            : L10n.t("st.endpointPunctOff", s)
                    } else if code == 502 || code == 504 {
                        self?.endpointControlStatus = L10n.t("st.serverOffReapply")
                    } else {
                        self?.endpointControlStatus = L10n.t("st.applyFail", "\(code)")
                    }
                }
            } catch {
                await MainActor.run { self?.endpointControlStatus = L10n.t("st.noResponseMaybeOff") }
            }
        }
    }

    // (Removed stopServerNow(): this is a shared always-on relay, so the app no
    // longer exposes a way to stop the box. The server's /control/stop endpoint
    // still exists for the operator if ever needed.)

    /// One-tap: wake the box (if asleep), wait until /healthz says ready, then
    /// auto-press Start. Safe to call when already up — /healthz returns ready
    /// immediately and we Start without booting anything. Idempotent: a second
    /// tap while transitioning is ignored.
    func wakeAndStart() {
        guard !running, !serverPhase.isTransitioning else { return }
        guard let base = httpBase() else { serverPhase = .failed(L10n.t("st.serverURLError")); return }
        wakeStartedAt = Date()
        serverPhase = .waking
        wakeDetail = L10n.t("st.waking")
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
                    self.serverPhase = .failed(L10n.t("st.pwWrong"))
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
                ? L10n.t("st.bootingMin", mins)
                : L10n.t("st.booting")
        case .warming:
            // Relay is up; the long pole is the 32B model load.
            serverPhase = .warming
            wakeDetail = remain > 0
                ? L10n.t("st.modelLoadingMin", mins)
                : L10n.t("st.modelAlmost")
        case .ready:
            break   // handled in onServerReady
        }
    }

    /// /healthz said ready — notify the user and auto-start capture.
    private func onServerReady() {
        serverPhase = .ready
        wakeDetail = L10n.t("st.ready")
        wakeTask = nil
        notifyReady()
        // The box just (re)booted, so its translation-model choice and
        // sentence-endpointing knobs are back at the env defaults. Re-assert the
        // saved preferences, and force idle-stop OFF (shared box stays always-on).
        disableIdleStop()
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
        // Append the access token + room as query params (the relay validates the
        // token and isolates this capture's subtitles to its room).
        var comp = URLComponents(string: serverURL)
        var q = comp?.queryItems ?? []
        if !accessKey.isEmpty { q.append(URLQueryItem(name: "token", value: accessKey)) }
        q.append(URLQueryItem(name: "room", value: effectiveRoom))
        if !roomSecret.isEmpty { q.append(URLQueryItem(name: "rs", value: roomSecret)) }
        comp?.queryItems = q
        guard let url = comp?.url else {
            status = "Bad server URL"; return
        }
        // Keep prior transcript — a new session continues appending below it.
        epoch += 1
        micInterim = nil; sysInterim = nil
        micFlow.reset(); sysFlow.reset()
        // Arm the system-audio watchdog fresh for this session.
        sysWatchdogLastSamples = 0
        sysWatchdogLastGrowth = Date()
        sysRestartAttempts = 0
        sysRestarting = false
        audioWarning = ""

        // New autosave file per Start — every final line is written to disk
        // immediately, so a quit/crash never loses the transcript.
        let saver = TranscriptAutoSaver(startedAt: Date())
        autoSaver = saver
        autosavePath = saver.fileURL.path

        // UI language drives the end-of-session summary language (sent in config).
        micClient.uiLang = uiLanguage.rawValue
        sysClient.uiLang = uiLanguage.rawValue
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
        finalsSinceInsight = 0   // batch insight refreshes fresh per meeting
        dbgTimer?.invalidate()
        dbgTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let m = self.micFlow.snapshot, s = self.sysFlow.snapshot
                self.flowInfo = "mic \(m.samples/1000)k→\(m.chunks) [\(self.micClient.isConnected ? "✓" : "✗")] · sys \(s.samples/1000)k→\(s.chunks) [\(self.sysClient.isConnected ? "✓" : "✗")]"
                self.checkSysWatchdog(sysSamples: s.samples)
            }
        }
    }

    // Per-stream audio-flow counters (thread-safe; written from audio callbacks).
    private let micFlow = FlowCounter()
    private let sysFlow = FlowCounter()
    private var dbgTimer: Timer?

    // --- System-audio watchdog -------------------------------------------------
    // ScreenCaptureKit's stream can die SILENTLY (no error, no callback) — e.g.
    // after a display/output-device change or when coreaudiod/replayd wedges. The
    // app still looks "Listening…" while zero frames flow, so subtitles freeze
    // with nobody noticing. We can't see an error, but we CAN see that frames
    // stopped: sysFlow grows on every captured buffer (even during silence —
    // SCStream delivers continuous near-zero buffers), so "no growth for 6s while
    // we should be capturing" = a real stall, NOT just a quiet room.
    //
    // Recovery ladder: auto stop→start the capture up to sysMaxRestarts times
    // (cheap, fixes transient drops); if frames still don't return it's a daemon
    // wedge that a same-process restart can't clear, so we stop retrying and warn
    // the user to relaunch (Cmd+Q) — a wedge needs a fresh process.
    @Published var audioWarning = ""        // prominent banner when sys audio stalls
    private let sysStallSeconds = 6.0
    private let sysMaxRestarts = 2
    private var sysWatchdogLastSamples = 0
    private var sysWatchdogLastGrowth = Date()
    private var sysRestartAttempts = 0
    private var sysRestarting = false

    @MainActor
    private func checkSysWatchdog(sysSamples: Int) {
        // Only watch when system audio is actually supposed to be flowing.
        guard running, captureSystemAudio else { return }
        guard #available(macOS 13.0, *) else { return }
        if sysRestarting { return }   // a restart is in flight — don't pile on

        if sysSamples > sysWatchdogLastSamples {
            // Frames are flowing. If we'd previously warned/retried, we recovered.
            sysWatchdogLastSamples = sysSamples
            sysWatchdogLastGrowth = Date()
            if sysRestartAttempts > 0 || !audioWarning.isEmpty {
                sysRestartAttempts = 0
                audioWarning = ""
                rtlog("watchdog: sys audio recovered")
            }
            return
        }
        // No new frames since last tick — how long has it been stalled?
        let stalled = Date().timeIntervalSince(sysWatchdogLastGrowth)
        if stalled < sysStallSeconds { return }

        if sysRestartAttempts >= sysMaxRestarts {
            // Auto-recovery exhausted → warn only (a wedge needs a relaunch).
            audioWarning = L10n.t("warn.sysAudioDead")
            return
        }
        sysRestartAttempts += 1
        audioWarning = L10n.t("warn.sysAudioReconnecting", sysRestartAttempts)
        rtlog("watchdog: sys audio stalled \(Int(stalled))s — auto-restart \(sysRestartAttempts)/\(sysMaxRestarts)")
        restartSystemAudio()
    }

    @MainActor
    private func restartSystemAudio() {
        guard #available(macOS 13.0, *) else { return }
        sysRestarting = true
        // Tear down the old (possibly wedged) stream before making a fresh one.
        (sysCapture as? SystemAudioCapture)?.stop()
        sysCapture = nil
        let cap = SystemAudioCapture()
        cap.onSamples = { [weak self] s in
            guard let self else { return }
            self.sysFlow.add(s.count)
            self.echoGate.pushSystem(s)   // reference for the mic echo gate
            self.sysClient.sendAudio(floatsToPCM16(s))
        }
        sysCapture = cap
        Task {
            do {
                try await cap.start()
                rtlog("watchdog: sys restart start() OK")
            } catch {
                rtlog("watchdog: sys restart FAILED: \(error.localizedDescription)")
            }
            await MainActor.run {
                // Give the fresh stream a full stall-window to prove itself before
                // the next check (acts as the inter-attempt cooldown).
                self.sysWatchdogLastGrowth = Date()
                self.sysRestarting = false
            }
        }
    }

    private func requestMicThenStart() {
        // IMPORTANT: do all AVAudioEngine work OFF the main thread. Touching
        // engine.inputNode / engine.start() can dispatch_sync to an internal HAL
        // queue and BLOCK; on the main thread that freezes the whole UI ("앱이
        // 응답하지 않음"). We run it on a background queue and only hop back to
        // the main actor to update status. The onSamples closure just forwards
        // audio (thread-safe counters/WS send), so it's fine off-main.
        let selected = selectedInputID
        let aec = micAEC
        let gateOn = echoGateEnabled
        echoGate.reset()
        echoGate.onTransition = { [weak self] gating in
            rtlog("echoGate: \(gating ? "SUPPRESSING mic (speaker echo)" : "passing mic")")
            Task { @MainActor in self?.echoGateActive = gating }
        }
        let begin: () -> Void = { [weak self] in
            guard let self else { return }
            self.mic.onSamples = { [weak self] s in
                guard let self else { return }
                self.micFlow.add(s.count)
                // Echo gate: drop mic chunks that are the speakers' sound
                // re-entering the mic. Suppressed audio is replaced by silence
                // (not skipped) so the relay's VAD sees continuous time and
                // closes any open utterance naturally.
                if gateOn, self.echoGate.pushMic(s) {
                    self.micClient.sendAudio(floatsToPCM16([Float](repeating: 0, count: s.count)))
                    return
                }
                self.micClient.sendAudio(floatsToPCM16(s))
            }
            // MicCapture.startAsync runs the blocking AVAudioEngine work on its
            // OWN private queue (never the main thread) and calls back on error.
            self.mic.startAsync(device: selected, aec: aec) { msg in
                if let msg { Task { @MainActor in self.status = "Mic error: \(msg)" } }
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
                self.echoGate.pushSystem(s)   // reference for the mic echo gate
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
        // Stop audio off the main thread too — engine teardown touches the same
        // HAL queue that can block. MicCapture.stopAsync uses its own queue;
        // system capture stop is already async-safe.
        mic.stopAsync()
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
        // Disarm the watchdog so a manual stop never shows a stall warning.
        sysRestarting = false
        sysRestartAttempts = 0
        audioWarning = ""
    }

    func swapLanguages() {
        swap(&langA, &langB)
        if running { micClient.setPair(langA, langB); sysClient.setPair(langB, langA) }
    }

    // MARK: - Core Audio daemon restart (last-resort recovery)
    // When the watchdog exhausts in-process restarts (warn.sysAudioDead), the
    // stall is a coreaudiod/replayd wedge that a same-process SCStream restart
    // can't clear — historically the only fix was relaunching the app (⌘Q). But
    // bouncing the audio daemon (`killall coreaudiod`; launchd relaunches it in
    // ~1s) clears the wedge WITHOUT losing the transcript or the session. That
    // needs admin rights, so we ask via macOS's standard auth prompt (osascript
    // "with administrator privileges") — no sudoers edit, no baked-in password.
    @Published var coreAudioRestartStatus = ""
    @Published var coreAudioRestarting = false

    /// Bounce coreaudiod (admin prompt), then re-arm system-audio capture. Safe:
    /// launchd immediately respawns the daemon; only in-flight audio blips ~1s.
    func restartCoreAudio() {
        guard !coreAudioRestarting else { return }
        coreAudioRestarting = true
        coreAudioRestartStatus = L10n.t("st.coreAudioRestarting")
        rtlog("restartCoreAudio: requesting admin kill of coreaudiod")
        // Run the privileged kill off-main (the auth dialog + process spawn block).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Self.killCoreAudioWithAuth()
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.coreAudioRestartStatus = L10n.t("st.coreAudioRestarted")
                    rtlog("restartCoreAudio: daemon bounced OK")
                    // Give launchd a moment to respawn coreaudiod, then re-enumerate
                    // devices and, if we were capturing, restart system audio so the
                    // user is back to a live stream without touching anything.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.refreshDevices()
                        if self.running, self.captureSystemAudio, #available(macOS 13.0, *) {
                            self.sysRestartAttempts = 0
                            self.audioWarning = ""
                            self.restartSystemAudio()
                        }
                        self.coreAudioRestarting = false
                        // Clear the status line after a few seconds.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            self.coreAudioRestartStatus = ""
                        }
                    }
                } else {
                    self.coreAudioRestartStatus = L10n.t("st.coreAudioRestartFailed")
                    self.coreAudioRestarting = false
                    rtlog("restartCoreAudio: failed or cancelled")
                }
            }
        }
    }

    /// Kill coreaudiod via an admin-authenticated AppleScript shell call. Returns
    /// true on success. The prompt is macOS's own (Touch ID / password); if the
    /// user cancels, osascript exits non-zero and we report failure.
    private nonisolated static func killCoreAudioWithAuth() -> Bool {
        let script = "do shell script \"/usr/bin/killall coreaudiod\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                rtlog("killCoreAudioWithAuth non-zero: \(err.prefix(200))")
                return false
            }
            return true
        } catch {
            rtlog("killCoreAudioWithAuth threw: \(error.localizedDescription)")
            return false
        }
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
                // Live insight: count only genuinely new finals; every N, refresh.
                if insightEnabled {
                    finalsSinceInsight += 1
                    if finalsSinceInsight >= max(1, insightEveryN) {
                        finalsSinceInsight = 0
                        requestInsight(mode: "live")
                    }
                }
            }
            if stream == "mic", micInterim?.id == uid { micInterim = nil }
            if stream == "system", sysInterim?.id == uid { sysInterim = nil }
        case "dedup":
            // Echo dedup: this utterance was the other stream's audio leaking
            // in (speaker -> mic). Its final was suppressed server-side; just
            // clear the orphaned grey interim so it doesn't linger.
            guard let seq = msg.seq else { return }
            let uid = lineID(seq, stream: stream)
            if stream == "mic", micInterim?.id == uid { micInterim = nil }
            if stream == "system", sysInterim?.id == uid { sysInterim = nil }
        case "refine":
            // Post-final refine: the server re-translated this line with more
            // conversation context — swap the translation in place. The line
            // was already autosaved with the fast translation; the on-disk
            // file keeps it (the S3 archive gets the refined text server-side).
            guard let seq = msg.seq else { return }
            let uid = lineID(seq, stream: stream)
            if let idx = lines.firstIndex(where: { $0.id == uid }) {
                var l = lines[idx]
                l.translation = msg.translation ?? l.translation
                lines[idx] = l
            }
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

    /// PANIC WIPE for the public viewers. Tells the relay to blank every viewer
    /// browser in our room RIGHT NOW (for when something sensitive slips on-air).
    /// The relay keeps no backlog, so this only clears the live viewer DOM;
    /// new/reloaded viewers already start empty. Our own app transcript and the
    /// on-disk autosave are left intact (use clearTranscript() for the local view).
    func clearViewers() {
        guard let url = controlURL("control/clear", [
            URLQueryItem(name: "room", value: effectiveRoom),
        ]) else { clearViewersStatus = L10n.t("st.serverURLError"); return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        rtlog("clearViewers room=\(effectiveRoom)")
        Task { [weak self] in
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    if code == 401 || code == 403 {
                        self?.clearViewersStatus = L10n.t("st.pwErrorNotApplied")
                    } else if code == 200 {
                        self?.clearViewersStatus = L10n.t("st.viewersCleared")
                    } else if code == 502 || code == 504 {
                        self?.clearViewersStatus = L10n.t("st.serverOffReapply")
                    } else {
                        self?.clearViewersStatus = L10n.t("st.applyFail", "\(code)")
                    }
                }
            } catch {
                await MainActor.run { self?.clearViewersStatus = L10n.t("st.noResponseMaybeOff") }
            }
        }
    }

    /// Reveal the auto-saved transcripts folder in Finder.
    func revealAutosaveFolder() {
        let folder = TranscriptAutoSaver.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting(
            autosavePath.isEmpty ? [folder] : [URL(fileURLWithPath: autosavePath)])
    }

    // MARK: - Live insight (meeting copilot)

    /// Build speaker-labeled transcript lines (chronological) for the insight
    /// call. We send the TRANSLATION (so a single-language model reads cleanly)
    /// with the speaker tag, capped to the most recent `limit` lines.
    private func transcriptLines(limit: Int) -> [String] {
        let recent = lines.suffix(limit)
        return recent.map { l in
            let who = l.stream == "mic" ? "ME" : "THEM"
            // Prefer the translation; fall back to source if translation empty.
            let text = l.translation.isEmpty ? l.source : l.translation
            return "\(who): \(text)"
        }
    }

    /// POST the recent transcript + context to /insight and update the panel.
    /// mode "live" -> rolling summary + suggested questions; "final" -> wrap with
    /// key points + next actions. No-op (and no cost) unless the user invoked it.
    func requestInsight(mode: String) {
        guard !lines.isEmpty else {
            if mode == "final" { insightStatus = L10n.t("st.insightNoConvo") }
            return
        }
        // One in-flight at a time: drop a live refresh if one is running (a newer
        // one will come), but always let a manual "final" through after it.
        if insightBusy && mode == "live" { return }
        let limit = mode == "final" ? 400 : 40
        let payload: [String: Any] = [
            "mode": mode,
            "context": insightContext,
            "lang": uiLanguage.rawValue,
            "transcript": transcriptLines(limit: limit),
        ]
        guard let base = httpBase(),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            insightStatus = L10n.t("st.requestFail"); return
        }
        var comp = URLComponents(url: base.appendingPathComponent("insight"),
                                 resolvingAgainstBaseURL: false)
        if !accessKey.isEmpty { comp?.queryItems = [URLQueryItem(name: "token", value: accessKey)] }
        guard let url = comp?.url else { insightStatus = L10n.t("st.urlFail"); return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !accessKey.isEmpty { req.setValue(accessKey, forHTTPHeaderField: "X-Wake-Token") }
        insightBusy = true
        insightStatus = mode == "final" ? L10n.t("st.insightWrapping") : L10n.t("st.insightUpdating")
        rtlog("requestInsight mode=\(mode) lines=\(transcriptLines(limit: limit).count)")
        Task { [weak self] in
            defer { Task { @MainActor in self?.insightBusy = false } }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                await MainActor.run {
                    guard code == 200, let obj else {
                        if code == 401 || code == 403 { self?.insightStatus = L10n.t("st.pwError") }
                        else if code == 502 || code == 504 { self?.insightStatus = L10n.t("st.serverOff") }
                        else { self?.insightStatus = L10n.t("st.insightFail", "\(code)") }
                        return
                    }
                    if let err = obj["error"] as? String {
                        self?.insightStatus = L10n.t("st.error", err); return
                    }
                    if mode == "final" {
                        self?.finalSummary = obj["summary"] as? String ?? ""
                        self?.keyPoints = (obj["key_points"] as? [Any])?.compactMap { $0 as? String } ?? []
                        self?.nextActions = (obj["next_actions"] as? [Any])?.compactMap { $0 as? String } ?? []
                        self?.insightStatus = L10n.t("st.insightDone")
                    } else {
                        self?.liveSummary = obj["summary"] as? String ?? ""
                        self?.suggestedQuestions = (obj["questions"] as? [Any])?.compactMap { $0 as? String } ?? []
                        self?.insightStatus = L10n.t("st.insightUpdated")
                    }
                }
            } catch {
                await MainActor.run { self?.insightStatus = L10n.t("st.noResponse") }
            }
        }
    }

    /// Manual end-of-meeting wrap: produce the final summary + key points +
    /// next actions from the whole transcript.
    func finishAndSummarize() { requestInsight(mode: "final") }

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
