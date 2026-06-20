"""
Runtime configuration for the realtime translation relay.

All knobs are overridable via environment variables so the SAME code runs
locally (Ollama + small whisper) and on a Tokyo GPU box (vLLM + large-v3).

The "문장이 중간에 끊겨서 어색해지는" problem is controlled almost entirely by
the VAD / endpointing knobs below — NOT by the model. The defaults here lean
toward "listen longer, finalize later" so a sentence is rarely cut mid-way.
"""
import os


def _f(name: str, default: float) -> float:
    return float(os.environ.get(name, default))


def _i(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


def _s(name: str, default: str) -> str:
    return os.environ.get(name, default)


class Settings:
    # --- WebSocket server ---
    HOST = _s("RT_HOST", "0.0.0.0")
    PORT = _i("RT_PORT", 8765)

    # --- Access control (simple shared password/token) ---
    # If set, every connection (capture AND viewer) must present this token via
    # ?token=... on the WS URL (or Authorization: Bearer). Empty = open (dev).
    # Set RT_RELAY_TOKEN in the systemd unit to lock the relay down to you only.
    RELAY_TOKEN = _s("RT_RELAY_TOKEN", "")

    # --- Audio (must match what the Mac app sends) ---
    SAMPLE_RATE = _i("RT_SAMPLE_RATE", 16000)   # Hz, mono PCM16 LE
    FRAME_MS = _i("RT_FRAME_MS", 30)            # webrtcvad accepts 10/20/30

    # --- ASR (faster-whisper) ---
    ASR_MODEL = _s("RT_ASR_MODEL", "large-v3")  # local demo: "small" / "base"
    ASR_DEVICE = _s("RT_ASR_DEVICE", "auto")    # "cuda" | "cpu" | "auto"
    ASR_COMPUTE = _s("RT_ASR_COMPUTE", "auto")  # "float16" on GPU, "int8" on CPU
    ASR_BEAM = _i("RT_ASR_BEAM", 1)             # interim uses 1 for speed
    # --- concurrency (for many simultaneous users) ---
    # Number of faster-whisper model replicas. Each replica ≈ 3–5 GB VRAM and
    # adds one lane of concurrent transcription (the old single-lock design
    # serialized ALL users through one model). Set ~5 per dedicated L40S.
    ASR_WORKERS = _i("RT_ASR_WORKERS", 1)
    # GPUs to spread the replicas across (round-robin device_index).
    ASR_NUM_GPUS = _i("RT_ASR_NUM_GPUS", 1)

    # --- auto-stop on idle (personal GPU-cost guard) ---
    # Self-stop the EC2 box after this many seconds of ZERO capture sessions.
    # A meeting = the Mac app pressed Start = mic+system capture WebSockets, so
    # the box never stops mid-meeting. Viewers alone do NOT keep it alive.
    IDLE_STOP_S = _i("RT_IDLE_STOP_S", 900)        # 15 min of zero capture
    # Don't even arm the idle clock until this long after boot (cold-start grace
    # so the user has time to press Start after waking the box).
    IDLE_GRACE_S = _i("RT_IDLE_GRACE_S", 600)      # 10 min
    # Master switch — set "0" to disable self-stop (e.g. while load-testing).
    IDLE_STOP_ENABLED = _s("RT_IDLE_STOP_ENABLED", "1") == "1"
    # How often the idle-watcher checks.
    IDLE_CHECK_S = _i("RT_IDLE_CHECK_S", 60)
    # --- hallucination suppression thresholds ---
    # If a segment's no-speech probability is above this, treat it as silence
    # (drops the "Thank you for watching" type invented text). Higher = stricter.
    ASR_NO_SPEECH_THRESHOLD = _f("RT_ASR_NO_SPEECH_THRESHOLD", 0.6)
    # Segments whose average token log-prob is below this are discarded.
    ASR_LOGPROB_THRESHOLD = _f("RT_ASR_LOGPROB_THRESHOLD", -1.0)
    # Repetitive/garbage text compresses well; above this ratio = likely junk.
    ASR_COMPRESSION_THRESHOLD = _f("RT_ASR_COMPRESSION_THRESHOLD", 2.4)

    # --- Endpointing / anti-cut knobs (THE important ones) ---
    # How long a pause must last before we LOCK a sentence. Bigger = waits more,
    # far fewer mid-sentence cuts, slightly more latency. This is the main dial.
    # 650ms (from 900) makes finals land sooner; the punctuation-aware path below
    # handles long no-pause monologues. Tunable live from the app.
    MIN_SILENCE_MS = _i("RT_MIN_SILENCE_MS", 650)
    # Ignore blips: an utterance must contain at least this much real speech.
    MIN_SPEECH_MS = _i("RT_MIN_SPEECH_MS", 300)
    # Hard ceiling so a non-stop speaker still gets periodic finals. Lowered to
    # 8s (from 12s) so a long monologue gets finalized more often even when no
    # sentence-end is detected. Tunable live from the app.
    MAX_SEGMENT_MS = _i("RT_MAX_SEGMENT_MS", 8000)
    # --- sentence-end early finalize (punctuation-aware endpointing) ----------
    # Whisper already punctuates its transcription (。 . ? !) when it judges a
    # sentence complete. When ON, an in-progress utterance whose latest interim
    # ends in sentence punctuation AND has paused PUNCT_SILENCE_MS is finalized
    # immediately — so someone who talks 1-2 min without a real break still gets
    # crisp per-sentence subtitles instead of waiting out MIN_SILENCE/MAX_SEGMENT.
    # We require BOTH punctuation and a tiny pause so a stray mid-speech period
    # (whisper misfire) doesn't chop a sentence in half.
    PUNCT_ENDPOINT_ENABLED = _s("RT_PUNCT_ENDPOINT", "1") == "1"
    PUNCT_SILENCE_MS = _i("RT_PUNCT_SILENCE_MS", 300)
    # --- English-target sentence gate -----------------------------------------
    # KO and JA are SOV: chopping a sentence at a mid-utterance breath and
    # translating the halves still reads fine (word order is preserved). English
    # is SVO with reordering that CANNOT cross a wrong cut — so a half-sentence
    # becomes a dangling noun phrase ("departments that seem like a good fit")
    # plus a disconnected clause. When ON and the session's language pair
    # involves English, we IGNORE the bare silence pause as a finalize trigger
    # and only finalize on a grammatically-complete sentence (punctuation or a
    # KO/JA sentence-final ending + a tiny pause) or the max-segment safety net.
    # This keeps a clause whole so the English comes out as one well-ordered
    # sentence. KO<->JA sessions are unaffected (still snappy pause-based).
    EN_SENTENCE_GATE = _s("RT_EN_SENTENCE_GATE", "1") == "1"
    # Keep this much audio BEFORE speech starts so we never clip the first syllable.
    PREROLL_MS = _i("RT_PREROLL_MS", 300)
    # webrtcvad aggressiveness 0..3 (3 = most aggressive at calling things silence).
    VAD_AGGRESSIVENESS = _i("RT_VAD_AGGRESSIVENESS", 2)
    # How often to re-transcribe the in-progress utterance and emit an interim.
    # 1000ms (up from 700) keeps interim translation calls ~1/s so a Bedrock
    # round-trip can be absorbed without the preview lagging, and roughly halves
    # interim LLM call volume (matters when interim also goes to a paid API).
    INTERIM_INTERVAL_MS = _i("RT_INTERIM_INTERVAL_MS", 1000)
    # Interim ASR only re-transcribes the most recent N ms of the utterance, so
    # cost stays flat as a sentence grows (instead of re-running the whole 12s
    # buffer every 0.5s). Finals always use the FULL utterance for accuracy.
    INTERIM_WINDOW_MS = _i("RT_INTERIM_WINDOW_MS", 6000)

    # --- Translation LLM (OpenAI-compatible endpoint) ---
    # Local:  http://localhost:11434/v1  (Ollama)
    # Tokyo:  http://<gpu-host>:8000/v1   (vLLM serve)
    LLM_BASE_URL = _s("RT_LLM_BASE_URL", "http://localhost:11434/v1")
    LLM_API_KEY = _s("RT_LLM_API_KEY", "sk-no-key-required")
    LLM_MODEL = _s("RT_LLM_MODEL", "qwen3:32b")
    LLM_TEMPERATURE = _f("RT_LLM_TEMPERATURE", 0.2)
    # Per-request timeout (seconds) so a stuck LLM call can't wedge a session.
    LLM_TIMEOUT = _f("RT_LLM_TIMEOUT", 20.0)
    # How many previous final sentences to feed as context for coherence.
    CONTEXT_WINDOW = _i("RT_CONTEXT_WINDOW", 3)

    # --- Translation provider switch: "vllm" (local Qwen) | "bedrock" (Claude) ---
    # The app flips this live via /control/llm. "bedrock" routes translation to
    # Claude Sonnet 4.6 on Amazon Bedrock (higher accuracy); "vllm" uses the local
    # Qwen3-32B (free, fast, offline). On a Bedrock throttle/error we fall back to
    # Qwen for THAT call so subtitles never go blank mid-meeting.
    LLM_PROVIDER = _s("RT_LLM_PROVIDER", "vllm")        # default: local Qwen
    # Bedrock cross-region inference profile. Sonnet 4.6 has NO apac. profile, so
    # in Tokyo use "global." (no premium) — NOT "apac.". "jp." is also valid (10%
    # premium, data stays in Japan).
    BEDROCK_MODEL = _s("RT_BEDROCK_MODEL", "global.anthropic.claude-sonnet-4-6")
    # Region the bedrock-runtime endpoint is hit in. The box is in Tokyo.
    BEDROCK_REGION = _s("RT_BEDROCK_REGION", "ap-northeast-1")
    # Cap output so a runaway translation can't blow latency/cost. Subtitles are
    # short — a couple hundred tokens is plenty.
    BEDROCK_MAX_TOKENS = _i("RT_BEDROCK_MAX_TOKENS", 512)

    # --- Live insight (assistant-over-the-transcript) -------------------------
    # A SEPARATE feature from translation: the app, when its insight toggle is
    # ON, periodically POSTs the recent transcript + a free-text context (e.g.
    # "I'm the interviewer, focus on system-design depth") to /insight and shows
    # a rolling summary + suggested next questions, plus an end-of-meeting wrap
    # (key points + next actions). This costs a Bedrock call ONLY while the
    # toggle is on; off => the app never calls => zero added cost.
    #
    # How often the app asks for a live refresh (it batches every N new finals
    # so cost stays bounded). This is the app's default; the app owns the timer.
    INSIGHT_EVERY_N_FINALS = _i("RT_INSIGHT_EVERY_N_FINALS", 5)
    # Output caps: the live refresh is short (a couple bullet points + 2-3
    # questions); the final wrap is allowed more room (key points + next actions).
    INSIGHT_LIVE_MAX_TOKENS = _i("RT_INSIGHT_LIVE_MAX_TOKENS", 700)
    INSIGHT_FINAL_MAX_TOKENS = _i("RT_INSIGHT_FINAL_MAX_TOKENS", 1500)
    # The transcript can grow unbounded; only the most recent N lines are sent on
    # a live refresh (the running summary already carries earlier context). The
    # final wrap sends more so nothing important is missed.
    INSIGHT_LIVE_TRANSCRIPT_LINES = _i("RT_INSIGHT_LIVE_LINES", 40)
    INSIGHT_FINAL_TRANSCRIPT_LINES = _i("RT_INSIGHT_FINAL_LINES", 400)

    @property
    def frame_bytes(self) -> int:
        # PCM16 mono => 2 bytes/sample
        return int(self.SAMPLE_RATE * self.FRAME_MS / 1000) * 2

    @property
    def frame_samples(self) -> int:
        return int(self.SAMPLE_RATE * self.FRAME_MS / 1000)


settings = Settings()
