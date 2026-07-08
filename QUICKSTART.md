# Realtime Translator — Quick Start · 한 장 안내

[English](#english) · [한국어](#한국어)

---

## English

### What it is

A Mac app that puts **live translation subtitles** on your screen during meetings.

- It hears both **the other side** (Zoom, videos — anything your Mac plays) and **you** (microphone) at the same time
- Translates between Korean ↔ Japanese ↔ English and shows the result as subtitles
- It waits for you to actually finish a sentence before locking it in, so **sentences don't get chopped in half**

Everything runs on a **self-hosted GPU server** — no paid translation API, and your audio never leaves infrastructure you control. (Details in [README.md](README.md).)

### Install (once, ~3 min)

1. Get the app:
   - **Given a `.dmg`?** Double-click it and drag the app into **Applications**.
   - **Building yourself?** `cd mac-app && ./bundle.sh`, then open `RealtimeTranslator.app`.
2. First launch: **right-click the app ▸ Open ▸ Open** — it's not Apple-notarized, so macOS warns once. After this, normal double-click works.
3. Grant two permissions:
   - **Microphone** → click "Allow" on the popup
   - **Screen Recording** → enable it in System Settings ▸ Privacy & Security ▸ Screen Recording, then **restart the app** (this is how macOS lets the app hear system audio)

> If you see *"damaged and can't be opened"* (it isn't — it's the download quarantine flag), run:
> `xattr -dr com.apple.quarantine /Applications/RealtimeTranslator.app`

### Use

1. **Server** — the relay's WebSocket URL (from whoever runs the server, or your own deploy — see [README.md](README.md)). **Password** — the shared access token. Both are remembered after the first time.
2. **Languages** — pick the pair (KO / JA / EN; the ⇄ button flips direction).
3. Press **Wake & Start**. If the GPU server is asleep (it auto-sleeps to save cost), this wakes it — the **first wake takes ~6 minutes**, then capture starts automatically.
4. Speak, or play a video — subtitles appear on the right:
   - **ME** (blue) = your microphone · **THEM** (green) = system audio (the other side)
   - Grey = still speaking · solid = finalized sentence

Leave the **room** field as auto-generated (it isolates your subtitles from other users on the same server). For a sensitive meeting, set a **room password** so only people who know it can view.

**Extras**: drag-select to copy subtitles, **Export .md** to save the whole transcript (it's also auto-saved to `~/Documents/RealtimeTranslator/`). Turn on **Live insight** and describe your role to get a live summary + suggested questions during the meeting. Teammates can watch the same subtitles in a browser at `https://<server>/view` — no app needed.

### If it doesn't work

| Symptom | Check |
|---|---|
| No subtitles | Did you **Wake & Start** and wait out the ~6 min first wake? Password typo? |
| Only THEM (other side) is missing | Screen Recording permission on + **app restarted** after enabling? |
| Zoom voices not picked up | Headphones-only can hide them from capture — switch output to speakers |

---

## 한국어

### 이게 뭐냐면

회의할 때 화면에 **실시간 번역 자막**을 띄워주는 Mac 앱입니다.

- **상대방 말**(Zoom·영상 등 Mac에서 나는 소리)과 **내 말**(마이크)을 동시에 알아듣고
- 한국어 ↔ 일본어 ↔ 영어로 번역해서 자막으로 보여줍니다
- 말이 끝나기를 기다렸다가 문장 단위로 확정하기 때문에, **문장이 중간에 뚝 끊기지 않습니다**

전부 **직접 운영하는 GPU 서버**에서 돌아갑니다 — 유료 번역 API 없이, 오디오가 내 인프라 밖으로 나가지 않습니다. (자세한 구조는 [README.md](README.md) 참고.)

### 설치 (처음 한 번, 3분)

1. 앱 받기:
   - **`.dmg`를 받았다면** 더블클릭 → 앱을 **Applications 폴더로 드래그**
   - **직접 빌드한다면** `cd mac-app && ./bundle.sh` 후 `RealtimeTranslator.app` 실행
2. 첫 실행: 앱을 **우클릭 ▸ 열기 ▸ 열기** — Apple 공증이 없어서 처음엔 보안 경고가 뜹니다. 한 번만 이렇게 열면 다음부턴 그냥 더블클릭.
3. 권한 2개 허용:
   - **마이크** → 팝업에서 "허용"
   - **화면 기록** → 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 화면 기록에서 켜고 → **앱 재시작** (상대방 소리를 잡으려면 필요합니다)

> "손상되었기 때문에 열 수 없습니다"가 뜨면 (실제 손상 아님, 다운로드 격리 표식) 터미널에 한 줄:
> `xattr -dr com.apple.quarantine /Applications/RealtimeTranslator.app`

### 사용법

1. **서버** — 릴레이의 WebSocket 주소 (서버 운영자에게 받거나, 직접 배포 — [README.md](README.md) 참고). **접속 비밀번호** — 공유받은 토큰. 둘 다 한 번 넣으면 저장됩니다.
2. **Languages** — 언어쌍 선택 (KO / JA / EN, 가운데 ⇄로 방향 전환)
3. **Wake & Start** 클릭. GPU 서버가 자고 있으면 (비용 절약을 위해 자동으로 잠듭니다) 이 버튼이 깨웁니다 — **처음 깨울 땐 ~6분**, 준비되면 자동 시작.
4. 말하거나 영상을 틀면 오른쪽에 자막이 뜹니다:
   - **ME**(파랑) = 내 마이크 · **THEM**(초록) = 시스템 오디오(상대방)
   - 회색 = 말하는 중 · 진하게 = 확정된 문장

**방(room)** 칸은 자동 생성된 그대로 두면 됩니다 (같은 서버의 다른 사용자와 자막이 섞이지 않게 격리). 민감한 회의면 **방 비번**을 정하세요 — 그 비번을 아는 사람만 볼 수 있습니다.

**팁**: 자막은 드래그 복사 가능, **Export .md**로 전체 기록 저장 (자동으로 `~/Documents/RealtimeTranslator/`에도 저장됩니다). **라이브 인사이트**를 켜고 내 역할을 적어두면 회의 중 실시간 요약 + 추천 질문을 받아볼 수 있습니다. 팀원들은 앱 없이 브라우저로 `https://<서버>/view`에서 같은 자막을 볼 수 있습니다.

### 안 될 때

| 증상 | 확인할 것 |
|---|---|
| 자막이 안 뜸 | **Wake & Start**로 서버 깨우고 ~6분 기다렸는지 / 비밀번호 오타 |
| 상대방(THEM) 소리만 안 잡힘 | 화면 기록 권한 켜고 **앱 재시작**했는지 |
| Zoom 상대 소리가 안 잡힘 | 이어폰만 쓰면 안 잡힐 수 있음 — 스피커 출력으로 |
