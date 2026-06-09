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

# Phrases whisper hallucinates on silence/noise (YouTube-outro training bias).
# Matched case-insensitively after stripping punctuation/whitespace.
_HALLUCINATION_PHRASES = {
    # English
    "thank you for watching", "thanks for watching", "thank you for watching!",
    "please subscribe", "like and subscribe", "see you next time",
    "thank you", "bye", "you",
    # Japanese
    "ご視聴ありがとうございました", "ご視聴ありがとうございます",
    "視聴ありがとうございました", "視聴していただきありがとうございます",
    "チャンネル登録をお願いします", "チャンネル登録お願いします",
    "最後までご視聴いただきありがとうございました",
    # Korean
    "시청해주셔서 감사합니다", "시청해 주셔서 감사합니다",
    "구독과 좋아요 부탁드립니다", "구독 부탁드립니다", "감사합니다",
}


def _norm(s: str) -> str:
    return "".join(ch for ch in s.lower() if ch.isalnum() or ch.isspace()).strip()


def _is_hallucination(text: str) -> bool:
    if not text:
        return False
    n = _norm(text)
    if not n:
        return True
    if n in {_norm(p) for p in _HALLUCINATION_PHRASES}:
        return True
    # A short fragment that simply IS one of the canned phrases (no other words).
    for p in _HALLUCINATION_PHRASES:
        if n == _norm(p):
            return True
    return False


@dataclass
class AsrResult:
    text: str
    language: str
    avg_logprob: float


class Asr:
    def __init__(self, device_index=None, num_workers: int = 1):
        """A single WhisperModel, optionally replicated across multiple GPUs.

        The CORRECT multi-GPU pattern (per faster-whisper maintainer) is ONE
        model with device_index=[list of GPUs] + num_workers, NOT one model per
        GPU behind a shared thread pool — the latter triggers
        "CUDA failed with error invalid argument" because a GPU-pinned model can
        run on a thread bound to a different device. CTranslate2 owns the
        worker→GPU routing; we just submit concurrent calls.
        """
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

        kwargs = {"num_workers": max(1, num_workers)}
        if device == "cuda" and device_index is not None:
            # int OR list of ints; a list = one CTranslate2 worker per GPU.
            kwargs["device_index"] = device_index

        self.model = WhisperModel(
            settings.ASR_MODEL, device=device, compute_type=compute, **kwargs
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
            # --- hallucination suppression ---
            # whisper was trained on tons of YouTube captions, so on silence/noise
            # it loves to invent "Thank you for watching / 視聴ありがとう / 구독".
            # These thresholds drop low-confidence + likely-silent segments.
            no_speech_threshold=settings.ASR_NO_SPEECH_THRESHOLD,
            log_prob_threshold=settings.ASR_LOGPROB_THRESHOLD,
            compression_ratio_threshold=settings.ASR_COMPRESSION_THRESHOLD,
            temperature=0.0,                  # no sampling fallback into garbage
        )
        # Drop segments whose own scores look like hallucination, then keep text.
        kept = []
        for s in segments:
            if getattr(s, "no_speech_prob", 0.0) >= settings.ASR_NO_SPEECH_THRESHOLD:
                continue
            txt = s.text.strip()
            if _is_hallucination(txt):
                continue
            kept.append(txt)
        text = " ".join(kept).strip()
        if _is_hallucination(text):
            text = ""
        lang = info.language if info.language in ALLOWED_LANGS else "ko"
        return AsrResult(text=text, language=lang, avg_logprob=info.language_probability)
