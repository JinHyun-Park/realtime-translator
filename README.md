# Realtime Translator (KO ↔ JA)

Mac app that captures **system audio + your selected mic/output device** and shows
**live translation** on screen, powered by self-hosted **open-weight** models.
Default pair is Korean ↔ Japanese (auto-detects which side spoke); English is
also supported. Any language pair works as long as the models support it.

```
[Mac app (Swift/SwiftUI)]                         [Relay (Python)]                 [Open models]
 System audio  (ScreenCaptureKit) ─┐
 + Mic / input (AVAudioEngine)     ─┼─ mix → 16k PCM16 ─WS→  VAD endpointing      faster-whisper large-v3 (ASR)
 + Output device picker            ─┘                        + sentence buffer    Qwen3-32B via vLLM/Ollama (MT)
        └── live subtitle overlay  ←──── JSON {interim, final} ────────────────────────────────────
```

## Why open-weight (and why the "model in Tokyo" idea changes)

OpenAI Realtime and Gemini Live are **hosted paid APIs** — they don't give you
the weights, so you can't "put the model on a Tokyo instance"; you'd only host a
relay that calls out to them and pays per second of audio. Since the requirement
is *host the best model ourselves in Tokyo*, this uses the strongest **open**
stack instead:

- **ASR:** `faster-whisper large-v3` — best open multilingual recognizer for KO/JA.
- **Translation:** `Qwen3-32B` (served by vLLM), OpenAI-compatible. Swap to
  `gemma-3-27b-it` or `Qwen3-8B` freely. See `backend/deploy_tokyo.md`.

## The "sentences get cut in half" problem — solved here

This is an **endpointing/VAD** problem, not a model problem. The relay listens
**longer** before deciding a sentence is finished, and re-translates as more
audio arrives. The dials (env vars, `backend/config.py`):

| Knob | Default | Effect |
|---|---|---|
| `RT_MIN_SILENCE_MS` | `900` | **The main one.** Pause length required to *lock* a sentence. Raise to 1100–1300 if sentences still split; short "음…"/comma pauses won't finalize. |
| `RT_MAX_SEGMENT_MS` | `12000` | Safety flush for a non-stop talker. |
| `RT_PREROLL_MS` | `300` | Audio kept *before* speech onset so the first syllable is never clipped. |
| `RT_MIN_SPEECH_MS` | `300` | Ignore coughs/blips below this. |
| `RT_INTERIM_INTERVAL_MS` | `500` | How often the grey "in-progress" translation refreshes. |
| `RT_VAD_AGGRESSIVENESS` | `2` | webrtcvad 0–3; higher = calls quiet bits silence sooner. |

Behavior: while you speak, a **grey interim** line updates live; when you pause
long enough, it commits to a **solid final** line. Finals carry the last few
sentences as **context** to the LLM so pronouns/topic stay consistent.

## Quick start (local demo, no cloud)

```bash
# 1. Backend (CPU whisper + Ollama Qwen3)
brew install ollama
ollama serve            # in one terminal
cd backend && ./run_local.sh   # installs deps, pulls qwen3:8b, starts relay

# 2. Mac app
cd ../mac-app && ./bundle.sh
open RealtimeTranslator.app
```

In the app: server `ws://localhost:8765`, leave **System audio** + **Microphone**
on, pick your input/output devices, press **Start**. Play a Japanese video or
speak Korean — translations appear live.

> **Permissions:** first launch macOS will ask for **Microphone** and **Screen
> Recording** (system-audio capture rides on the screen-recording permission).
> Approve both in System Settings → Privacy & Security, then relaunch. The app is
> ad-hoc signed; if Gatekeeper blocks it, right-click → Open once.

## Tokyo GPU (best quality) — automated

The whole box is provisioned by scripts in **`deploy/`** — no SSH keys, no public
ports (reachable only via SSM, per the no-public-exposure rule).

```bash
deploy/launch.sh                 # package -> S3, IAM+SG, launch g6e.2xlarge in Tokyo
                                 #   (override size:  INSTANCE_TYPE=g6e.12xlarge deploy/launch.sh)
# wait until bootstrap reaches READY (watch /var/run/rt-status over SSM)
deploy/connect.sh                # SSM port-forward  ws://localhost:8765  (leave running)
# -> in the Mac app set server = ws://localhost:8765, press Start
deploy/teardown.sh stop          # stop billing when done  (or: terminate)
```

What `launch.sh` builds:
- **AMI** Deep Learning PyTorch 2.7 (Ubuntu 22.04), **g6e.2xlarge** (1× L40S 46GB)
- **IAM** `rt-translator-ec2-role` (SSM core + read-only on the deploy bucket)
- **SG** `rt-translator-sg` with **zero inbound** — Session Manager only
- **user-data** pulls `backend/` from S3 and starts two systemd units:
  `rt-vllm` (Qwen3-32B-AWQ on :8000) and `rt-relay` (whisper large-v3 + WS on :8765),
  both bound to `127.0.0.1`. A readiness probe flips `/var/run/rt-status` to `READY`.

> **Cost:** g6e.2xlarge bills ~\$2/hr while running. `deploy/teardown.sh stop` when
> idle (a stopped instance still pays ~\$16/mo for its 200 GB EBS; `terminate` to zero it).

> **Scaling to ~20 concurrent users:** a single L40S is fine for the *translation*
> LLM (vLLM continuous batching) but the *ASR* path is the bottleneck — 20 live
> whisper streams will queue on one model. For real 20-user load, go
> `g6e.12xlarge` (4× L40S) AND give the relay multiple ASR workers (the current
> relay shares one ASR model behind a global lock). See `backend/deploy_tokyo.md`.

## Layout

```
backend/
  server.py        WebSocket relay (asyncio + websockets)
  segmenter.py     VAD endpointing — the anti-cut logic
  asr.py           faster-whisper wrapper
  translator.py    OpenAI-compatible LLM translation + context
  config.py        all tunable knobs (env-overridable)
  run_local.sh     one-shot local launcher
  deploy_tokyo.md  GPU deploy guide
mac-app/
  Sources/RealtimeTranslator/
    Audio/         Resampler, Mixer, SystemAudioCapture, MicCapture, AudioDevices
    Net/           RelayClient (WebSocket)
    Views/         ContentView (controls), TranscriptView (live subtitles)
    AppModel.swift main view model
    main.swift     app entry
  bundle.sh        build + wrap into a signed .app (needed for permissions)
```
