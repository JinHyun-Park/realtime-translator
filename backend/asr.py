"""
Speech recognition via faster-whisper (CTranslate2).

faster-whisper large-v3 is the strongest open-weight multilingual ASR for
Korean & Japanese and runs comfortably on a single GPU. On the local Mac demo
you'll want RT_ASR_MODEL=small (or base) so it runs on CPU.

We transcribe in the source language directly (no translate task) and let the
LLM do the translation — that gives far better KO<->JA quality than whisper's
built-in english-only translate task.
"""
from __future__ import annotations

import io
import wave
from dataclasses import dataclass

from config import settings

# Languages we let whisper auto-detect among. Restricting the set makes
# detection on short KO/JA utterances much more reliable.
ALLOWED_LANGS = {"ko", "ja", "en"}


@dataclass
class AsrResult:
    text: str
    language: str
    avg_logprob: float


class Asr:
    def __init__(self):
        from faster_whisper import WhisperModel

        device = settings.ASR_DEVICE
        compute = settings.ASR_COMPUTE
        if device == "auto":
            try:
                import torch  # noqa
                device = "cuda" if torch.cuda.is_available() else "cpu"
            except Exception:
                device = "cpu"
        if compute == "auto":
            compute = "float16" if device == "cuda" else "int8"

        self.model = WhisperModel(
            settings.ASR_MODEL, device=device, compute_type=compute
        )
        self.device = device

    @staticmethod
    def _pcm_to_wav(pcm: bytes) -> io.BytesIO:
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(settings.SAMPLE_RATE)
            w.writeframes(pcm)
        buf.seek(0)
        return buf

    def transcribe(self, pcm: bytes, interim: bool) -> AsrResult:
        wav = self._pcm_to_wav(pcm)
        segments, info = self.model.transcribe(
            wav,
            beam_size=settings.ASR_BEAM if interim else max(settings.ASR_BEAM, 5),
            vad_filter=False,                 # our segmenter already did VAD
            condition_on_previous_text=False, # avoid runaway hallucinated context
            language=None,                    # auto-detect within multilingual
            task="transcribe",
        )
        text = "".join(s.text for s in segments).strip()
        lang = info.language if info.language in ALLOWED_LANGS else "ko"
        return AsrResult(text=text, language=lang, avg_logprob=info.language_probability)
