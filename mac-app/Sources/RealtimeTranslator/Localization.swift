import Foundation

/// App UI languages. `code` is sent to the server so insight/summary come back
/// in the same language the user reads the app in.
enum UILang: String, CaseIterable, Identifiable {
    case ko, ja, en
    var id: String { rawValue }
    var label: String {            // shown in the picker, in its own language
        switch self { case .ko: return "한국어"; case .ja: return "日本語"; case .en: return "English" }
    }
}

/// Tiny in-app localization. Strings are keyed; each key has ko/ja/en. Lookup
/// falls back to ko (the original authoring language) if a key/translation is
/// missing, so nothing ever shows blank. UI reads `L10n.lang` (set from
/// AppModel.uiLanguage); call L10n.t("key") for plain strings and
/// L10n.t("key", a, b) for ones with %@ placeholders.
enum L10n {
    static var lang: UILang = .ko

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let row = table[key]
        let s = row?[lang] ?? row?[.ko] ?? key
        return args.isEmpty ? s : String(format: s, arguments: args)
    }

    // key -> per-language string. %@ = string arg, %d = int arg.
    private static let table: [String: [UILang: String]] = [
        // --- Server / connection panel ---
        "server.password": [.ko: "접속 비밀번호 / access password", .ja: "接続パスワード / access password", .en: "Access password"],
        "server.room": [.ko: "방", .ja: "ルーム", .en: "Room"],
        "server.roomSecret": [.ko: "방 비번", .ja: "ルームのパスワード", .en: "Room password"],
        "server.roomSecret.ph": [.ko: "선택 (비우면 공개 방)", .ja: "任意（空欄なら公開ルーム）", .en: "Optional (blank = open room)"],
        "server.room.help": [
            .ko: "같은 서버를 여러 명이 써도 '방'이 다르면 자막이 격리돼요. 함께 보려면 같은 방+방비번으로 맞추세요. 방 비번을 처음 설정한 사람이 그 방 주인이 됩니다.",
            .ja: "同じサーバーを複数人で使っても「ルーム」が違えば字幕は分離されます。一緒に見るには同じルーム＋パスワードに合わせてください。最初にパスワードを設定した人がそのルームの所有者になります。",
            .en: "Even with several people on one server, different 'rooms' keep subtitles isolated. To watch together, use the same room + password. Whoever sets the password first owns the room."],
        "server.viewBrowser": [.ko: "브라우저로 자막 보기 (/view)", .ja: "ブラウザで字幕を見る (/view)", .en: "Open subtitles in browser (/view)"],
        "server.viewBrowser.help": [.ko: "팀원과 함께 볼 땐 이 페이지 주소를 공유하세요 (비번 입력하면 시청).", .ja: "チームと見るときはこのページのURLを共有してください（パスワードを入力すれば視聴可）。", .en: "To watch with teammates, share this page URL (they enter the password)."],
        "server.history": [.ko: "지난 회의 기록 보기 (전사·요약)", .ja: "過去の会議の記録を見る（文字起こし・要約）", .en: "Past meeting records (transcript & summary)"],
        "server.history.help": [.ko: "이 방의 끝난 회의들의 전체 전사와 요약·다음 액션을 브라우저에서 봅니다.", .ja: "このルームの終了した会議の全文文字起こしと要約・ネクストアクションをブラウザで表示します。", .en: "View this room's finished meetings — full transcript + summary + next actions — in the browser."],
        "server.clearViewers": [.ko: "보고 있는 모든 자막 즉시 지우기", .ja: "視聴中の字幕をすべて即時クリア", .en: "Wipe all viewers' subtitles now"],
        "server.clearViewers.help": [.ko: "실수로 민감한 내용이 자막에 나갔을 때, 지금 보고 있는 모든 사람의 화면에서 쌓인 자막을 즉시 비웁니다. (내 앱 기록·저장 파일은 그대로)", .ja: "機密情報がうっかり字幕に出たとき、視聴中の全員の画面に溜まった字幕を即座に消去します。（自分のアプリ記録・保存ファイルはそのまま）", .en: "If something sensitive slips on-air, instantly blanks the accumulated subtitles on every current viewer's screen. (Your own app transcript & saved files stay intact.)"],

        // --- Translation model ---
        "model.title": [.ko: "번역 모델", .ja: "翻訳モデル", .en: "Translation model"],
        "model.claude": [.ko: "Claude Sonnet 4.6 사용 (정확도 ↑)", .ja: "Claude Sonnet 4.6 を使う（精度↑）", .en: "Use Claude Sonnet 4.6 (higher accuracy)"],
        "model.claude.help": [.ko: "클라우드 번역(Bedrock). 더 정확하지만 호출당 과금 + 인터넷 필요. 일시 폭주 시 자동으로 Qwen으로 폴백.", .ja: "クラウド翻訳(Bedrock)。より正確ですが呼び出しごとに課金＋インターネットが必要。一時的な負荷時は自動でQwenにフォールバック。", .en: "Cloud translation (Bedrock). More accurate but billed per call + needs internet. Auto-falls back to Qwen under load."],
        "model.qwen.help": [.ko: "로컬 Qwen 3-32B. 무료·오프라인, 정확도는 Claude보다 한 수 아래.", .ja: "ローカルのQwen 3-32B。無料・オフライン、精度はClaudeより一段下。", .en: "Local Qwen 3-32B. Free & offline; a bit less accurate than Claude."],

        // --- Sentence endpointing ---
        "endpoint.title": [.ko: "문장 끊기 (반응 속도)", .ja: "文の区切り（反応速度）", .en: "Sentence breaks (responsiveness)"],
        "endpoint.silence": [.ko: "침묵 민감도", .ja: "無音の感度", .en: "Silence sensitivity"],
        "endpoint.fast": [.ko: "빠름", .ja: "速い", .en: "Fast"],
        "endpoint.careful": [.ko: "신중", .ja: "慎重", .en: "Careful"],
        "endpoint.silence.help": [.ko: "작을수록 말 끝나자마자 번역(빠름), 클수록 더 기다림(느리지만 안 잘림).", .ja: "小さいほど話し終わってすぐ翻訳（速い）、大きいほど待つ（遅いが切れにくい）。", .en: "Lower = translate right after you stop (snappy); higher = wait longer (slower but fewer cut-offs)."],
        "endpoint.punct": [.ko: "구두점에서 문장 조기 확정", .ja: "句読点で文を早めに確定", .en: "Finalize early on punctuation"],
        "endpoint.punct.on.help": [.ko: "안 쉬고 길게 말해도 한 문장 끝(. 。 ? !)이 보이면 바로 끊어 번역해요.", .ja: "区切らず長く話しても、文末(. 。 ? !)が見えたらすぐ区切って翻訳します。", .en: "Even in a long unbroken stretch, it cuts at a sentence end (. 。 ? !) and translates right away."],
        "endpoint.punct.off.help": [.ko: "구두점 무시 — 침묵이 생길 때까지만 기다립니다.", .ja: "句読点を無視 — 無音になるまで待ちます。", .en: "Ignore punctuation — only wait for a pause."],

        // --- Live insight ---
        "insight.title": [.ko: "라이브 인사이트 (회의 코파일럿)", .ja: "ライブインサイト（会議コパイロット）", .en: "Live insight (meeting copilot)"],
        "insight.enable": [.ko: "실시간 인사이트 켜기", .ja: "リアルタイムインサイトを有効化", .en: "Enable live insight"],
        "insight.on.help": [.ko: "대화가 쌓이면 요약·추천 질문을 자동 갱신해요 (Claude 호출, 켰을 때만 과금).", .ja: "会話が溜まると要約・推奨質問を自動更新します（Claude呼び出し、オン時のみ課金）。", .en: "As the conversation builds, it auto-refreshes a summary + suggested questions (Claude calls, billed only while on)."],
        "insight.off.help": [.ko: "꺼져 있어요 — 서버를 호출하지 않아 추가 비용이 없습니다.", .ja: "オフです — サーバーを呼び出さないので追加費用はありません。", .en: "Off — no server calls, so no added cost."],
        "insight.context": [.ko: "컨텍스트 (내 역할·중점)", .ja: "コンテキスト（自分の役割・重点）", .en: "Context (your role & focus)"],
        "insight.context.ph": [.ko: "예: 나는 백엔드 시니어 면접관이다. 시스템 설계 깊이와 트레이드오프 사고를 본다.", .ja: "例: 私はバックエンドのシニア面接官です。システム設計の深さとトレードオフの思考を見ます。", .en: "e.g. I'm a senior backend interviewer; I assess system-design depth and trade-off thinking."],
        "insight.interval": [.ko: "갱신 주기", .ja: "更新間隔", .en: "Refresh every"],
        "insight.sentences": [.ko: "문장 %d개", .ja: "%d文", .en: "%d sentences"],
        "insight.wrap": [.ko: "마무리 정리 (핵심 + 다음 액션)", .ja: "まとめ（要点＋ネクストアクション）", .en: "Wrap up (key points + next actions)"],
        "insight.summaryNow": [.ko: "지금까지 요약", .ja: "ここまでの要約", .en: "Summary so far"],
        "insight.questions": [.ko: "추천 질문", .ja: "推奨質問", .en: "Suggested questions"],
        "insight.keySummary": [.ko: "핵심 요약", .ja: "要約", .en: "Summary"],
        "insight.keyPoints": [.ko: "핵심 포인트", .ja: "要点", .en: "Key points"],
        "insight.nextActions": [.ko: "다음 액션", .ja: "ネクストアクション", .en: "Next actions"],

        // --- Start / wake ---
        "start.preparing": [.ko: "서버 준비 중…", .ja: "サーバー準備中…", .en: "Preparing server…"],
        "start.cancel": [.ko: "취소", .ja: "キャンセル", .en: "Cancel"],
        "start.wake.help": [.ko: "서버가 꺼져 있으면 깨우고, 준비되면 자동으로 시작해요 (최대 ~6분).", .ja: "サーバーがオフなら起こし、準備できたら自動で開始します（最大～6分）。", .en: "Wakes the server if it's off and auto-starts when ready (up to ~6 min)."],

        // --- Status messages (AppModel) ---
        "st.serverURLError": [.ko: "서버 주소 오류", .ja: "サーバーアドレスエラー", .en: "Server URL error"],
        "st.viewerURLFail": [.ko: "뷰어 URL 생성 실패", .ja: "ビューアURLの生成に失敗", .en: "Failed to build viewer URL"],
        "st.historyURLFail": [.ko: "기록 URL 생성 실패", .ja: "記録URLの生成に失敗", .en: "Failed to build history URL"],
        "st.requestFail": [.ko: "요청 생성 실패", .ja: "リクエスト生成に失敗", .en: "Failed to build request"],
        "st.urlFail": [.ko: "URL 생성 실패", .ja: "URL生成に失敗", .en: "Failed to build URL"],
        "st.pwError": [.ko: "비밀번호 오류", .ja: "パスワードエラー", .en: "Wrong password"],
        "st.pwErrorNotApplied": [.ko: "비밀번호 오류 — 설정 미적용", .ja: "パスワードエラー — 設定は未適用", .en: "Wrong password — setting not applied"],
        "st.pwWrong": [.ko: "비밀번호가 틀렸어요", .ja: "パスワードが違います", .en: "Wrong password"],
        "st.serverOff": [.ko: "서버 꺼져 있음", .ja: "サーバーはオフ", .en: "Server is off"],
        "st.serverOffReapply": [.ko: "서버 꺼져 있음 — 깨운 뒤 자동 적용", .ja: "サーバーはオフ — 起動後に自動適用", .en: "Server off — applies after wake"],
        "st.noResponse": [.ko: "서버 응답 없음", .ja: "サーバー応答なし", .en: "No server response"],
        "st.noResponseMaybeOff": [.ko: "서버 응답 없음 (꺼져 있을 수 있음)", .ja: "サーバー応答なし（オフの可能性）", .en: "No response (may be off)"],
        "st.applyFail": [.ko: "적용 실패 (%@)", .ja: "適用失敗 (%@)", .en: "Apply failed (%@)"],
        "st.viewersCleared": [.ko: "뷰어 화면 비움 완료", .ja: "ビューア画面をクリアしました", .en: "Viewers cleared"],
        "warn.sysAudioReconnecting": [.ko: "⚠️ 시스템 오디오 끊김 — 재연결 중… (%d)", .ja: "⚠️ システム音声が途切れました — 再接続中… (%d)", .en: "⚠️ System audio dropped — reconnecting… (%d)"],
        "warn.sysAudioDead": [.ko: "⚠️ 시스템 오디오 복구 실패 — 아래 ‘오디오 엔진 재시작’을 누르거나 앱을 완전히 종료(⌘Q) 후 다시 켜주세요", .ja: "⚠️ システム音声の復旧に失敗 — 下の「オーディオエンジンを再起動」を押すか、アプリを完全に終了（⌘Q）して再起動してください", .en: "⚠️ System audio recovery failed — tap ‘Restart audio engine’ below, or quit the app (⌘Q) and reopen it"],
        "audio.aec": [.ko: "에코 제거 (스피커 사용 시)", .ja: "エコー除去（スピーカー使用時）", .en: "Echo cancellation (speakers)"],
        "audio.aec.help": [.ko: "스피커 소리가 마이크로 다시 들어가 ME로 중복 표시될 때 켜세요. 일부 장치에선 마이크가 무음이 될 수 있음 — 그땐 끄세요.", .ja: "スピーカーの音がマイクに回り込みMEとして重複表示される場合にオン。一部のデバイスではマイクが無音になることがあります — その場合はオフに。", .en: "Turn on if speaker audio re-enters the mic and shows up duplicated as ME. On some devices the mic may go silent — turn it off if so."],
        "audio.restartEngine": [.ko: "오디오 엔진 재시작", .ja: "オーディオエンジンを再起動", .en: "Restart audio engine"],
        "audio.restartEngine.help": [.ko: "시스템 오디오 데몬(coreaudiod)을 재시작해 멈춘 캡처를 복구합니다. 관리자 암호가 필요하며 소리가 1초 정도 끊깁니다.", .ja: "システム音声デーモン（coreaudiod）を再起動して停止したキャプチャを復旧します。管理者パスワードが必要で、音声が1秒ほど途切れます。", .en: "Restarts the system-audio daemon (coreaudiod) to recover a stalled capture. Needs your admin password; audio blips for ~1s."],
        "st.coreAudioRestarting": [.ko: "오디오 데몬 재시작 중…", .ja: "オーディオデーモンを再起動中…", .en: "Restarting audio daemon…"],
        "st.coreAudioRestarted": [.ko: "오디오 데몬 재시작 완료 — 캡처 재개 중", .ja: "オーディオデーモン再起動完了 — キャプチャ再開中", .en: "Audio daemon restarted — resuming capture"],
        "st.coreAudioRestartFailed": [.ko: "오디오 데몬 재시작 취소/실패", .ja: "オーディオデーモンの再起動をキャンセル/失敗", .en: "Audio daemon restart cancelled/failed"],
        "st.waking": [.ko: "서버 깨우는 중…", .ja: "サーバーを起動中…", .en: "Waking server…"],
        "st.wakingLong": [.ko: "서버 깨우는 중… 모델 로딩 ~5분 남음", .ja: "サーバー起動中… モデル読み込み残り～5分", .en: "Waking server… ~5 min for the model to load"],
        "st.booting": [.ko: "서버 부팅 중…", .ja: "サーバー起動中…", .en: "Server booting…"],
        "st.bootingMin": [.ko: "서버 부팅 중… 약 %d분 남음", .ja: "サーバー起動中… 残り約%d分", .en: "Server booting… ~%d min left"],
        "st.modelLoadingMin": [.ko: "모델 로딩 중… 약 %d분 남음", .ja: "モデル読み込み中… 残り約%d分", .en: "Loading model… ~%d min left"],
        "st.modelAlmost": [.ko: "모델 로딩 중… 거의 다 됐어요", .ja: "モデル読み込み中… もうすぐです", .en: "Loading model… almost there"],
        "st.ready": [.ko: "준비 완료 — 시작합니다", .ja: "準備完了 — 開始します", .en: "Ready — starting"],
        "st.transOnClaude": [.ko: "번역: Claude Sonnet 4.6 (정확도↑)", .ja: "翻訳: Claude Sonnet 4.6（精度↑）", .en: "Translation: Claude Sonnet 4.6 (higher accuracy)"],
        "st.transOnQwen": [.ko: "번역: Qwen 3-32B (로컬·무료)", .ja: "翻訳: Qwen 3-32B（ローカル・無料）", .en: "Translation: Qwen 3-32B (local, free)"],
        "st.endpointPunctOn": [.ko: "문장 끊기: 침묵 %dms + 구두점 조기확정 ON", .ja: "文区切り: 無音%dms＋句読点早期確定 ON", .en: "Breaks: silence %dms + punctuation finalize ON"],
        "st.endpointPunctOff": [.ko: "문장 끊기: 침묵 %dms (구두점 조기확정 OFF)", .ja: "文区切り: 無音%dms（句読点早期確定 OFF）", .en: "Breaks: silence %dms (punctuation finalize OFF)"],
        "st.insightUpdating": [.ko: "인사이트 갱신 중…", .ja: "インサイト更新中…", .en: "Updating insight…"],
        "st.insightWrapping": [.ko: "마무리 정리 중…", .ja: "まとめを生成中…", .en: "Wrapping up…"],
        "st.insightFail": [.ko: "인사이트 실패 (%@)", .ja: "インサイト失敗 (%@)", .en: "Insight failed (%@)"],
        "st.insightDone": [.ko: "정리 완료", .ja: "まとめ完了", .en: "Wrap-up done"],
        "st.insightUpdated": [.ko: "업데이트됨", .ja: "更新しました", .en: "Updated"],
        "st.insightNoConvo": [.ko: "정리할 대화 내용이 없어요", .ja: "まとめる会話がありません", .en: "No conversation to summarize"],
        "st.error": [.ko: "오류: %@", .ja: "エラー: %@", .en: "Error: %@"],

        // --- Language picker ---
        "lang.title": [.ko: "앱 언어", .ja: "アプリの言語", .en: "App language"],
    ]
}
