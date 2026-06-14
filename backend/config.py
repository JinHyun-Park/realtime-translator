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
    MIN_SILENCE_MS = _i("RT_MIN_SILENCE_MS", 900)
    # Ignore blips: an utterance must contain at least this much real speech.
    MIN_SPEECH_MS = _i("RT_MIN_SPEECH_MS", 300)
    # Hard ceiling so a non-stop speaker still gets periodic finals.
    MAX_SEGMENT_MS = _i("RT_MAX_SEGMENT_MS", 12000)
    # Keep this much audio BEFORE speech starts so we never clip the first syllable.
    PREROLL_MS = _i("RT_PREROLL_MS", 300)
    # webrtcvad aggressiveness 0..3 (3 = most aggressive at calling things silence).
    VAD_AGGRESSIVENESS = _i("RT_VAD_AGGRESSIVENESS", 2)
    # How often to re-transcribe the in-progress utterance and emit an interim.
    INTERIM_INTERVAL_MS = _i("RT_INTERIM_INTERVAL_MS", 700)
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

    @property
    def frame_bytes(self) -> int:
        # PCM16 mono => 2 bytes/sample
        return int(self.SAMPLE_RATE * self.FRAME_MS / 1000) * 2

    @property
    def frame_samples(self) -> int:
        return int(self.SAMPLE_RATE * self.FRAME_MS / 1000)


settings = Settings()
