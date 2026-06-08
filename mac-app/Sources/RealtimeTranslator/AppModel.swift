import AVFoundation
import Combine
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// One translated line shown in the transcript.
/// `id` is globally unique across sessions (epoch*1e6 + relay seq) so the
/// transcript can accumulate across stop/start without seq collisions.
struct Line: Identifiable {
    let id: Int
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
    @Published var serverURL = "ws://localhost:18765"
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
    @Published var interim: Line?

    private let mixer = Mixer()
    private let mic = MicCapture()
    private var sysCapture: AnyObject?     // SystemAudioCapture (macOS 13+)
    private let client = RelayClient()
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
        client.onState = { [weak self] c in
            Task { @MainActor in
                self?.connected = c
                self?.status = c ? "Connected" : "Disconnected"
            }
        }
        client.onMessage = { [weak self] msg in
            Task { @MainActor in self?.handle(msg) }
        }
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
        guard let url = URL(string: serverURL) else {
            status = "Bad server URL"; return
        }
        // Keep prior transcript — a new session continues appending below it.
        epoch += 1
        interim = nil
        client.connect(url: url)
        client.setPair(langA, langB)

        mixer.onChunk = { [weak self] data in self?.client.sendAudio(data) }
        mixer.start()

        // Mic needs explicit TCC authorization; request it before tapping.
        if captureMic {
            requestMicThenStart()
        }

        if captureSystemAudio {
            startSystemAudio()
        }

        running = true
        status = "Listening…"
    }

    private func requestMicThenStart() {
        let begin: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                try self.mic.setInputDevice(self.selectedInputID)
                self.mic.onSamples = { [weak self] s in self?.mixer.pushMic(s) }
                try self.mic.start()
            } catch {
                self.status = "Mic error: \(error.localizedDescription)"
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
            cap.onSamples = { [weak self] s in self?.mixer.pushSystem(s) }
            sysCapture = cap
            Task {
                do { try await cap.start() }
                catch {
                    await MainActor.run {
                        self.status = "System audio error: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            status = "System audio needs macOS 13+"
        }
    }

    func stop() {
        mic.stop()
        if #available(macOS 13.0, *), let cap = sysCapture as? SystemAudioCapture {
            cap.stop()
        }
        sysCapture = nil
        mixer.stop()
        client.disconnect()
        running = false
        status = "Stopped"
    }

    func swapLanguages() {
        swap(&langA, &langB)
        if running { client.setPair(langA, langB) }
    }

    // MARK: - Relay messages

    /// Map a per-connection relay seq to a globally-unique line id.
    private func lineID(_ seq: Int) -> Int { epoch * 1_000_000 + seq }

    private func handle(_ msg: RelayMessage) {
        switch msg.type {
        case "error":
            status = "Relay: \(msg.message ?? "error")"
        case "interim":
            guard let seq = msg.seq else { return }
            interim = Line(
                id: lineID(seq),
                source: msg.source ?? "",
                translation: msg.translation ?? "",
                src: msg.src ?? "", tgt: msg.tgt ?? "",
                isFinal: false
            )
        case "final":
            guard let seq = msg.seq else { return }
            let uid = lineID(seq)
            let line = Line(
                id: uid,
                source: msg.source ?? "",
                translation: msg.translation ?? "",
                src: msg.src ?? "", tgt: msg.tgt ?? "",
                isFinal: true
            )
            if let idx = lines.firstIndex(where: { $0.id == uid }) {
                lines[idx] = line
            } else {
                lines.append(line)
            }
            if interim?.id == uid { interim = nil }
        default:
            break
        }
    }

    // MARK: - Transcript actions

    /// Explicitly clear the accumulated transcript (the only way to wipe it —
    /// start/stop preserves it).
    func clearTranscript() {
        lines.removeAll()
        interim = nil
    }

    /// Render the full transcript as Markdown.
    func transcriptMarkdown() -> String {
        var out = "# Translation transcript\n\n"
        for l in lines {
            out += "- **\(l.src.uppercased())** \(l.source)\n"
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
