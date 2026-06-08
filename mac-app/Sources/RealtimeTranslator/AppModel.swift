import AVFoundation
import Combine
import CoreAudio
import SwiftUI

/// One translated line shown in the transcript.
struct Line: Identifiable {
    let id: Int            // seq from relay
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
        lines.removeAll()
        interim = nil
        sentChunks = 0
        micSamples = 0
        sysSamples = 0
        client.connect(url: url)
        client.setPair(langA, langB)

        mixer.onChunk = { [weak self] data in
            self?.sentChunks += 1
            self?.client.sendAudio(data)
        }
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
        startMeter()
    }

    private func requestMicThenStart() {
        let begin: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                try self.mic.setInputDevice(self.selectedInputID)
                self.mic.onSamples = { [weak self] s in
                    self?.micSamples += s.count
                    self?.mixer.pushMic(s)
                }
                try self.mic.start()
                NSLog("RT mic started")
            } catch {
                self.status = "Mic error: \(error.localizedDescription)"
                NSLog("RT mic error: \(error.localizedDescription)")
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
                    else { self.status = "Mic permission DENIED — enable in System Settings ▸ Privacy ▸ Microphone" }
                }
            }
        default:
            status = "Mic permission denied — System Settings ▸ Privacy ▸ Microphone"
            NSLog("RT mic not authorized")
        }
    }

    // Diagnostics: log audio flow once a second so we can see where it stalls.
    private var sentChunks = 0
    private var micSamples = 0
    private var sysSamples = 0
    private var meter: Timer?
    private func startMeter() {
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            NSLog("RT flow: mic=\(self.micSamples) sys=\(self.sysSamples) chunksSent=\(self.sentChunks) connected=\(self.client.isConnected)")
        }
    }

    private func startSystemAudio() {
        if #available(macOS 13.0, *) {
            let cap = SystemAudioCapture()
            cap.onSamples = { [weak self] s in
                self?.sysSamples += s.count
                self?.mixer.pushSystem(s)
            }
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
        meter?.invalidate(); meter = nil
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

    private func handle(_ msg: RelayMessage) {
        NSLog("RT recv: type=\(msg.type) seq=\(msg.seq ?? -1) tr=\(msg.translation ?? "")")
        switch msg.type {
        case "error":
            status = "Relay: \(msg.message ?? "error")"
        case "interim":
            guard let seq = msg.seq else { return }
            interim = Line(
                id: seq,
                source: msg.source ?? "",
                translation: msg.translation ?? "",
                src: msg.src ?? "", tgt: msg.tgt ?? "",
                isFinal: false
            )
        case "final":
            guard let seq = msg.seq else { return }
            let line = Line(
                id: seq,
                source: msg.source ?? "",
                translation: msg.translation ?? "",
                src: msg.src ?? "", tgt: msg.tgt ?? "",
                isFinal: true
            )
            if let idx = lines.firstIndex(where: { $0.id == seq }) {
                lines[idx] = line
            } else {
                lines.append(line)
            }
            if interim?.id == seq { interim = nil }
        default:
            break
        }
    }
}
