import CoreAudio
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            ControlPanel()
                .frame(minWidth: 320, idealWidth: 440, maxWidth: 520)
            TranscriptView()
                .frame(minWidth: 440)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

struct ControlPanel: View {
    @EnvironmentObject var model: AppModel
    private let langs = ["ko", "ja", "en"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Realtime Translator")
                        .font(.title2).bold()
                    Spacer()
                    // App UI language (ko/ja/en) — relabels the whole UI + sets
                    // the language insight/summaries come back in.
                    Picker("", selection: $model.uiLanguage) {
                        ForEach(UILang.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                    .help(L10n.t("lang.title"))
                }

                // Connection
                GroupBox("Server") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("ws://host:8765", text: $model.serverURL)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.running)
                        SecureField(L10n.t("server.password"), text: $model.accessKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.running)
                        HStack(spacing: 6) {
                            Text(L10n.t("server.room")).font(.caption).foregroundStyle(.secondary)
                            TextField("room", text: $model.roomID)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.running)
                        }
                        HStack(spacing: 6) {
                            Text(L10n.t("server.roomSecret")).font(.caption).foregroundStyle(.secondary)
                            SecureField(L10n.t("server.roomSecret.ph"), text: $model.roomSecret)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.running)
                        }
                        Text(L10n.t("server.room.help"))
                            .font(.caption2).foregroundStyle(.secondary)
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
                        Divider()
                        // Open the broadcast viewer page in the browser — the live
                        // subtitle page teammates watch. Opens with the password
                        // pre-filled so it connects without prompting.
                        Button {
                            model.openViewerPage()
                        } label: {
                            Label(L10n.t("server.viewBrowser"), systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.regular)
                        Text(L10n.t("server.viewBrowser.help"))
                            .font(.caption2).foregroundStyle(.secondary)
                        Button {
                            model.openHistoryPage()
                        } label: {
                            Label(L10n.t("server.history"), systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.regular)
                        Text(L10n.t("server.history.help"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(6)
                }

                // (Removed the "auto-stop / stop server now" panel: this box is a
                // SHARED relay meant to stay always-on, so the app no longer lets a
                // user stop it or toggle idle-shutdown. The server keeps idle-stop
                // OFF; cost is managed out-of-band by the operator.)

                // Translation model — local Qwen vs Claude Sonnet 4.6 (Bedrock).
                GroupBox(L10n.t("model.title")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L10n.t("model.claude"), isOn: $model.useClaude)
                            .onChange(of: model.useClaude) { _ in
                                model.applyLLMSetting()
                            }
                        Text(model.useClaude
                             ? L10n.t("model.claude.help")
                             : L10n.t("model.qwen.help"))
                            .font(.caption2).foregroundStyle(.secondary)
                        if !model.llmControlStatus.isEmpty {
                            Text(model.llmControlStatus)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }

                // Sentence endpointing — how aggressively to break + translate.
                // Lower silence = snappier (translates sooner); punctuation
                // early-finalize lets a long no-pause monologue break per sentence.
                GroupBox(L10n.t("endpoint.title")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.t("endpoint.silence")).font(.caption)
                            Spacer()
                            Text("\(model.minSilenceMs)ms")
                                .font(.caption2).monospaced().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(model.minSilenceMs) },
                            set: { model.minSilenceMs = Int(($0 / 50).rounded()) * 50 }
                        ), in: 300...1500, step: 50) {
                            Text(L10n.t("endpoint.silence"))
                        } minimumValueLabel: {
                            Text(L10n.t("endpoint.fast")).font(.caption2)
                        } maximumValueLabel: {
                            Text(L10n.t("endpoint.careful")).font(.caption2)
                        }
                        .onChange(of: model.minSilenceMs) { _ in
                            model.applyEndpointSetting()
                        }
                        Text(L10n.t("endpoint.silence.help"))
                            .font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        Toggle(L10n.t("endpoint.punct"), isOn: $model.punctEnabled)
                            .onChange(of: model.punctEnabled) { _ in
                                model.applyEndpointSetting()
                            }
                        Text(model.punctEnabled
                             ? L10n.t("endpoint.punct.on.help")
                             : L10n.t("endpoint.punct.off.help"))
                            .font(.caption2).foregroundStyle(.secondary)
                        if !model.endpointControlStatus.isEmpty {
                            Text(model.endpointControlStatus)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }

                // Live insight (meeting copilot over the transcript) — separate
                // from translation; only calls the server while toggled ON.
                InsightPanel()

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

                // Build version — lets a recipient tell if their app is current.
                Text("RealtimeTranslator \(AppConfig.versionLabel)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .textSelection(.enabled)
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
                        Text(model.wakeDetail.isEmpty ? L10n.t("start.preparing") : model.wakeDetail)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { model.cancelWake() }) {
                        Text(L10n.t("start.cancel")).frame(maxWidth: .infinity)
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
                Text(L10n.t("start.wake.help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Live insight panel: a meeting copilot that reads the rolling transcript plus
/// a user-supplied context (role/goals) and shows a live summary + suggested
/// questions, with a manual "wrap up" producing key points + next actions.
/// Calls the server ONLY while the toggle is on, so it adds zero cost when off.
struct InsightPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox(L10n.t("insight.title")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.t("insight.enable"), isOn: $model.insightEnabled)
                Text(model.insightEnabled
                     ? L10n.t("insight.on.help")
                     : L10n.t("insight.off.help"))
                    .font(.caption2).foregroundStyle(.secondary)

                if model.insightEnabled {
                    Divider()
                    // Context: who am I, what to focus on. Feeds the system prompt.
                    Text(L10n.t("insight.context")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.insightContext)
                        .font(.callout)
                        .frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        .overlay(alignment: .topLeading) {
                            if model.insightContext.isEmpty {
                                Text(L10n.t("insight.context.ph"))
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack {
                        Text(L10n.t("insight.interval")).font(.caption)
                        Picker("", selection: $model.insightEveryN) {
                            Text(L10n.t("insight.sentences", 3)).tag(3)
                            Text(L10n.t("insight.sentences", 5)).tag(5)
                            Text(L10n.t("insight.sentences", 8)).tag(8)
                            Text(L10n.t("insight.sentences", 12)).tag(12)
                        }.labelsHidden().frame(width: 110)
                        Spacer()
                        if model.insightBusy { ProgressView().controlSize(.small) }
                    }

                    // Live results — rendered as ONE selectable block so the
                    // summary + all questions can be dragged/copied in one go.
                    if !model.liveSummary.isEmpty || !model.suggestedQuestions.isEmpty {
                        Divider()
                        SelectableText(attributed: liveResultAttributed())
                            .frame(minHeight: 320)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    }

                    Divider()
                    Button {
                        model.finishAndSummarize()
                    } label: {
                        Label(L10n.t("insight.wrap"), systemImage: "checkmark.seal")
                            .frame(maxWidth: .infinity)
                    }.controlSize(.regular).disabled(model.insightBusy)

                    // Final wrap — also one selectable block.
                    if !model.finalSummary.isEmpty || !model.keyPoints.isEmpty || !model.nextActions.isEmpty {
                        SelectableText(attributed: finalResultAttributed())
                            .frame(minHeight: 380)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    }

                    if !model.insightStatus.isEmpty {
                        Text(model.insightStatus).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.padding(6)
        }
    }

    // Combine the live summary + questions into ONE attributed block so the
    // whole thing is a single drag-selectable surface. A blank line separates
    // each section so the summary and questions are visually distinct.
    private func liveResultAttributed() -> NSAttributedString {
        let s = NSMutableAttributedString()
        if !model.liveSummary.isEmpty {
            s.append(InsightStyle.heading(L10n.t("insight.summaryNow"), first: true))
            s.append(InsightStyle.body(model.liveSummary + "\n"))
        }
        if !model.suggestedQuestions.isEmpty {
            s.append(InsightStyle.heading(L10n.t("insight.questions"), first: s.length == 0))
            for q in model.suggestedQuestions { s.append(InsightStyle.bullet(q, marker: "• ")) }
        }
        return s
    }

    private func finalResultAttributed() -> NSAttributedString {
        let s = NSMutableAttributedString()
        if !model.finalSummary.isEmpty {
            s.append(InsightStyle.heading(L10n.t("insight.keySummary"), first: true))
            s.append(InsightStyle.body(model.finalSummary + "\n"))
        }
        if !model.keyPoints.isEmpty {
            s.append(InsightStyle.heading(L10n.t("insight.keyPoints"), first: s.length == 0))
            for p in model.keyPoints { s.append(InsightStyle.bullet(p, marker: "• ")) }
        }
        if !model.nextActions.isEmpty {
            s.append(InsightStyle.heading(L10n.t("insight.nextActions"), first: s.length == 0))
            for a in model.nextActions { s.append(InsightStyle.bullet(a, marker: "→ ")) }
        }
        return s
    }
}

/// Attributed-string styling for the insight blocks (headings, body, bullets).
enum InsightStyle {
    /// `first` = is this the first heading in the block? If not, prepend a blank
    /// line so each section (summary / questions / etc.) is visually separated.
    static func heading(_ t: String, first: Bool) -> NSAttributedString {
        NSAttributedString(string: (first ? "" : "\n") + t + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
    static func body(_ t: String) -> NSAttributedString {
        NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
    }
    static func bullet(_ t: String, marker: String) -> NSAttributedString {
        NSAttributedString(string: marker + t + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
