"""
Voice-activity segmenter — the piece that decides WHEN a sentence is "done".

This is what fixes the "translation cuts the sentence in half" complaint.

Strategy (hangover / endpointing):
  - Feed fixed-size frames (10/20/30ms) to webrtcvad.
  - When speech starts, begin accumulating audio (plus a short pre-roll so the
    first syllable is never clipped).
  - A sentence is only LOCKED (finalized) after we've seen MIN_SILENCE_MS of
    continuous silence. Short pauses ("음...", breaths, comma-pauses) do NOT
    finalize — that's the whole point: we listen longer.
  - While still speaking, we periodically emit the audio-so-far as an INTERIM
    (low-latency, beam=1) which the UI shows in grey and keeps revising.
  - A runaway monologue is force-flushed at MAX_SEGMENT_MS.

Emits events the caller turns into ASR + translation calls.
"""
from __future__ import annotations

import collections
from dataclasses import dataclass, field

import webrtcvad

from config import settings


@dataclass
class SegEvent:
    kind: str            # "interim" | "final"
    pcm: bytes           # raw PCM16 mono @ SAMPLE_RATE for the utterance so far
    seq: int             # utterance index (stable across interim->final)


@dataclass
class Segmenter:
    vad: webrtcvad.Vad = field(default_factory=lambda: webrtcvad.Vad(settings.VAD_AGGRESSIVENESS))

    def __post_init__(self):
        self._preroll = collections.deque(
            maxlen=max(1, settings.PREROLL_MS // settings.FRAME_MS)
        )
        self._buf = bytearray()
        self._triggered = False
        self._silence_ms = 0
        self._speech_ms = 0
        self._seg_ms = 0
        self._ms_since_interim = 0
        self._seq = 0
        self._tail = bytearray()  # leftover bytes < one frame

    def add_audio(self, chunk: bytes) -> list[SegEvent]:
        """Feed arbitrary-length PCM16 bytes; get back 0+ segment events."""
        events: list[SegEvent] = []
        self._tail.extend(chunk)
        fb = settings.frame_bytes

        while len(self._tail) >= fb:
            frame = bytes(self._tail[:fb])
            del self._tail[:fb]
            events.extend(self._process_frame(frame))
        return events

    def _process_frame(self, frame: bytes) -> list[SegEvent]:
        events: list[SegEvent] = []
        is_speech = self.vad.is_speech(frame, settings.SAMPLE_RATE)

        if not self._triggered:
            self._preroll.append(frame)
            if is_speech:
                # Speech onset: start an utterance, keep the pre-roll context.
                self._triggered = True
                self._buf = bytearray(b"".join(self._preroll))
                self._preroll.clear()
                self._silence_ms = 0
                self._speech_ms = settings.FRAME_MS
                self._seg_ms = len(self._buf) // settings.frame_bytes * settings.FRAME_MS
                self._ms_since_interim = 0
            return events

        # --- currently inside an utterance ---
        self._buf.extend(frame)
        self._seg_ms += settings.FRAME_MS
        self._ms_since_interim += settings.FRAME_MS

        if is_speech:
            self._speech_ms += settings.FRAME_MS
            self._silence_ms = 0
        else:
            self._silence_ms += settings.FRAME_MS

        # Emit periodic interim while the speaker is still going.
        if self._ms_since_interim >= settings.INTERIM_INTERVAL_MS and \
                self._speech_ms >= settings.MIN_SPEECH_MS:
            self._ms_since_interim = 0
            events.append(SegEvent("interim", bytes(self._buf), self._seq))

        # Finalize on a long-enough pause OR a runaway-length safety flush.
        long_pause = self._silence_ms >= settings.MIN_SILENCE_MS
        too_long = self._seg_ms >= settings.MAX_SEGMENT_MS
        if long_pause or too_long:
            if self._speech_ms >= settings.MIN_SPEECH_MS:
                events.append(SegEvent("final", bytes(self._buf), self._seq))
                self._seq += 1
            self._reset_utterance()
        return events

    def _reset_utterance(self):
        self._triggered = False
        self._buf = bytearray()
        self._silence_ms = 0
        self._speech_ms = 0
        self._seg_ms = 0
        self._ms_since_interim = 0
        self._preroll.clear()

    def flush(self) -> list[SegEvent]:
        """On stream close, finalize whatever is buffered."""
        events: list[SegEvent] = []
        if self._triggered and self._speech_ms >= settings.MIN_SPEECH_MS:
            events.append(SegEvent("final", bytes(self._buf), self._seq))
            self._seq += 1
        self._reset_utterance()
        return events
