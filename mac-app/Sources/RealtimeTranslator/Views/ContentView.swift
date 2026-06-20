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
                        Divider()
                        // Open the broadcast viewer page in the browser — the live
                        // subtitle page teammates watch. Opens with the password
                        // pre-filled so it connects without prompting.
                        Button {
                            model.openViewerPage()
                        } label: {
                            Label("브라우저로 자막 보기 (/view)", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.regular)
                        Text("팀원과 함께 볼 땐 이 페이지 주소를 공유하세요 (비번 입력하면 시청).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(6)
                }

                // Auto-stop (GPU cost guard) — turn it off so the box stays up,
                // change the timeout, or stop the box right now.
                GroupBox("자동 끄기 (비용 절감)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("유휴 시 자동으로 끄기", isOn: $model.autoStopEnabled)
                            .onChange(of: model.autoStopEnabled) { _ in
                                model.applyIdleSetting()
                            }
                        HStack {
                            Text("끄기까지").font(.caption)
                            Picker("", selection: $model.idleStopMinutes) {
                                Text("10분").tag(10)
                                Text("15분").tag(15)
                                Text("30분").tag(30)
                                Text("60분").tag(60)
                            }
                            .labelsHidden()
                            .frame(width: 90)
                            .disabled(!model.autoStopEnabled)
                            .onChange(of: model.idleStopMinutes) { _ in
                                model.applyIdleSetting()
                            }
                            Spacer()
                        }
                        Text(model.autoStopEnabled
                             ? "회의 중엔 안 꺼져요 (캡처 중엔 유휴 아님). 보기만 하는 뷰어는 카운트 안 함."
                             : "⚠️ 자동으로 안 꺼집니다 — 다 쓰면 아래 '지금 끄기'로 직접 끄세요 (과금 계속됨).")
                            .font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        Button(role: .destructive) {
                            model.stopServerNow()
                        } label: {
                            Label("지금 서버 끄기", systemImage: "stop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.regular)
                        if !model.idleControlStatus.isEmpty {
                            Text(model.idleControlStatus)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }

                // Translation model — local Qwen vs Claude Sonnet 4.6 (Bedrock).
                GroupBox("번역 모델") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Claude Sonnet 4.6 사용 (정확도 ↑)", isOn: $model.useClaude)
                            .onChange(of: model.useClaude) { _ in
                                model.applyLLMSetting()
                            }
                        Text(model.useClaude
                             ? "클라우드 번역(Bedrock). 더 정확하지만 호출당 과금 + 인터넷 필요. 일시 폭주 시 자동으로 Qwen으로 폴백."
                             : "로컬 Qwen 3-32B. 무료·오프라인, 정확도는 Claude보다 한 수 아래.")
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
                GroupBox("문장 끊기 (반응 속도)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("침묵 민감도").font(.caption)
                            Spacer()
                            Text("\(model.minSilenceMs)ms")
                                .font(.caption2).monospaced().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(model.minSilenceMs) },
                            set: { model.minSilenceMs = Int(($0 / 50).rounded()) * 50 }
                        ), in: 300...1500, step: 50) {
                            Text("침묵 민감도")
                        } minimumValueLabel: {
                            Text("빠름").font(.caption2)
                        } maximumValueLabel: {
                            Text("신중").font(.caption2)
                        }
                        .onChange(of: model.minSilenceMs) { _ in
                            model.applyEndpointSetting()
                        }
                        Text("작을수록 말 끝나자마자 번역(빠름), 클수록 더 기다림(느리지만 안 잘림).")
                            .font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        Toggle("구두점에서 문장 조기 확정", isOn: $model.punctEnabled)
                            .onChange(of: model.punctEnabled) { _ in
                                model.applyEndpointSetting()
                            }
                        Text(model.punctEnabled
                             ? "안 쉬고 길게 말해도 한 문장 끝(. 。 ? !)이 보이면 바로 끊어 번역해요."
                             : "구두점 무시 — 침묵이 생길 때까지만 기다립니다.")
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

/// Live insight panel: a meeting copilot that reads the rolling transcript plus
/// a user-supplied context (role/goals) and shows a live summary + suggested
/// questions, with a manual "wrap up" producing key points + next actions.
/// Calls the server ONLY while the toggle is on, so it adds zero cost when off.
struct InsightPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox("라이브 인사이트 (회의 코파일럿)") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("실시간 인사이트 켜기", isOn: $model.insightEnabled)
                Text(model.insightEnabled
                     ? "대화가 쌓이면 요약·추천 질문을 자동 갱신해요 (Claude 호출, 켰을 때만 과금)."
                     : "꺼져 있어요 — 서버를 호출하지 않아 추가 비용이 없습니다.")
                    .font(.caption2).foregroundStyle(.secondary)

                if model.insightEnabled {
                    Divider()
                    // Context: who am I, what to focus on. Feeds the system prompt.
                    Text("컨텍스트 (내 역할·중점)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.insightContext)
                        .font(.callout)
                        .frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        .overlay(alignment: .topLeading) {
                            if model.insightContext.isEmpty {
                                Text("예: 나는 백엔드 시니어 면접관이다. 시스템 설계 깊이와 트레이드오프 사고를 본다.")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack {
                        Text("갱신 주기").font(.caption)
                        Picker("", selection: $model.insightEveryN) {
                            Text("문장 3개").tag(3)
                            Text("5개").tag(5)
                            Text("8개").tag(8)
                            Text("12개").tag(12)
                        }.labelsHidden().frame(width: 100)
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
                        Label("마무리 정리 (핵심 + 다음 액션)", systemImage: "checkmark.seal")
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
            s.append(InsightStyle.heading("지금까지 요약", first: true))
            s.append(InsightStyle.body(model.liveSummary + "\n"))
        }
        if !model.suggestedQuestions.isEmpty {
            s.append(InsightStyle.heading("추천 질문", first: s.length == 0))
            for q in model.suggestedQuestions { s.append(InsightStyle.bullet(q, marker: "• ")) }
        }
        return s
    }

    private func finalResultAttributed() -> NSAttributedString {
        let s = NSMutableAttributedString()
        if !model.finalSummary.isEmpty {
            s.append(InsightStyle.heading("핵심 요약", first: true))
            s.append(InsightStyle.body(model.finalSummary + "\n"))
        }
        if !model.keyPoints.isEmpty {
            s.append(InsightStyle.heading("핵심 포인트", first: s.length == 0))
            for p in model.keyPoints { s.append(InsightStyle.bullet(p, marker: "• ")) }
        }
        if !model.nextActions.isEmpty {
            s.append(InsightStyle.heading("다음 액션", first: s.length == 0))
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
