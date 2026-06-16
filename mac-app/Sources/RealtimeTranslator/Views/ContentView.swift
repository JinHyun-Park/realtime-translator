import CoreAudio
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            ControlPanel()
                .frame(minWidth: 280, maxWidth: 340)
            TranscriptView()
                .frame(minWidth: 460)
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}

struct ControlPanel: View {
    @EnvironmentObject var model: AppModel
    private let langs = ["ko", "ja", "en"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Realtime Translator")
                    .font(.title2).bold()

                // Connection
                GroupBox("Server") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("ws://host:8765", text: $model.serverURL)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.running)
                        SecureField("접속 비밀번호 / access password", text: $model.accessKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.running)
                        HStack {
                            Circle()
                                .fill(model.connected ? .green : .secondary)
                                .frame(width: 9, height: 9)
                            Text(model.status).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.running && !model.flowInfo.isEmpty {
                            Text(model.flowInfo)
                                .font(.caption2).monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }

                // Languages
                GroupBox("Languages") {
                    HStack(spacing: 8) {
                        Picker("", selection: $model.langA) {
                            ForEach(langs, id: \.self) { Text($0.uppercased()) }
                        }.labelsHidden()
                        Button {
                            model.swapLanguages()
                        } label: { Image(systemName: "arrow.left.arrow.right") }
                        Picker("", selection: $model.langB) {
                            ForEach(langs, id: \.self) { Text($0.uppercased()) }
                        }.labelsHidden()
                    }.padding(6)
                }

                // Audio sources
                GroupBox("Audio sources") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("System audio (speakers)", isOn: $model.captureSystemAudio)
                            .disabled(model.running)
                        Toggle("Microphone / input", isOn: $model.captureMic)
                            .disabled(model.running)

                        Text("Input device")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $model.selectedInputID) {
                            Text("System default").tag(AudioDeviceID?.none)
                            ForEach(model.inputDevices) { d in
                                Text(d.name).tag(AudioDeviceID?.some(d.id))
                            }
                        }.labelsHidden().disabled(model.running || !model.captureMic)

                        Text("Output device (monitor)")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $model.selectedOutputID) {
                            Text("System default").tag(AudioDeviceID?.none)
                            ForEach(model.outputDevices) { d in
                                Text(d.name).tag(AudioDeviceID?.some(d.id))
                            }
                        }.labelsHidden().disabled(model.running)

                        HStack {
                            Button("Refresh devices") { model.refreshDevices() }
                            Spacer()
                            Text("\(model.inputDevices.count) in · \(model.outputDevices.count) out")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }

                // Start / Wake & Start / Stop
                StartControl()
            }
            .padding()
        }
    }
}

/// The primary action button + server-wake progress.
///
/// - Not running, box may be asleep → "Wake & Start": wakes the GPU box (if
///   needed), waits on /healthz, then auto-starts capture. Pressing it when the
///   box is already up just starts immediately (/healthz returns ready at once).
/// - Transitioning (waking/booting/warming) → progress text + Cancel.
/// - Running → "Stop".
struct StartControl: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            if model.running {
                Button(action: { model.stop() }) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if model.serverPhase.isTransitioning {
                // Waiting on the box — show a live progress card with Cancel.
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.wakeDetail.isEmpty ? "서버 준비 중…" : model.wakeDetail)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.cancelWake() }) {
                        Text("취소").frame(maxWidth: .infinity)
                    }.controlSize(.regular)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                // Idle (or just failed) — offer the one-tap wake+start.
                Button(action: { model.wakeAndStart() }) {
                    Label("Wake & Start", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                if case .failed(let why) = model.serverPhase {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("서버가 꺼져 있으면 깨우고, 준비되면 자동으로 시작해요 (최대 ~6분).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
