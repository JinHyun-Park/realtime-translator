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
