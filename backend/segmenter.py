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

# Runtime-mutable endpointing knobs, seeded from config. The app tunes these
# live via /control/endpoint without a redeploy (same pattern as IDLE / LLM).
# The segmenter re-reads this dict every frame, so changes take effect on the
# next utterance boundary.
ENDPOINT = {
    "min_silence_ms": settings.MIN_SILENCE_MS,
    "max_segment_ms": settings.MAX_SEGMENT_MS,
    "punct_enabled": settings.PUNCT_ENDPOINT_ENABLED,
    "punct_silence_ms": settings.PUNCT_SILENCE_MS,
    "en_sentence_gate": settings.EN_SENTENCE_GATE,
}

# Sentence-final punctuation Whisper emits when it judges an utterance complete
# (covers KO/JA/EN: full stops, CJK 。, question/exclamation, CJK variants).
_SENTENCE_END = ("。", "．", ".", "?", "？", "!", "！")

# KO/JA sentence-final endings. Whisper does NOT always punctuate Korean, so we
# also treat these grammatical terminators as a completed sentence. They are
# ENDINGS a clause closes on; a mid-sentence connective particle (조사) like
# "한테/에서/하고/그리고" is deliberately NOT here, so a breath after "부서들한테"
# does not look complete. We require the ending to be the LAST token, and pair
# it with a tiny pause at the call site, so a noun that merely happens to end in
# these letters mid-speech (e.g. "필요" + still talking) won't false-finalize.
_KO_SENTENCE_END = (
    # polite -요 / -까/-�까 questions / -죠·-네요·-군요 etc. end in 요/죠/네/군 + optional 요
    "요", "죠", "쇼",
    # plain/declarative -다 / -까 / -니 / -지 / -야 / -자 / -군 / -네 / -걸 / -래 / -대
    "다", "까", "니", "지", "야", "자", "군", "네", "걸", "래", "대",
    # formal -습니다/-ㅂ니다/-십시오/-세요 end in 다/오 already covered; add 오
    "오",
)
# JA sentence-final forms (です/ます/ました/だ/た/ね/よ/か/...). Like KO, these are
# terminators, not connective particles (は/が/を/に/で/と are excluded).
_JA_SENTENCE_END = (
    "す", "た", "だ", "る", "い", "ね", "よ", "わ", "の", "か", "な",
)


def ends_sentence(text: str) -> bool:
    """True if `text` looks like a completed sentence — ends in sentence
    punctuation OR a KO/JA sentence-final ending. Used to early-finalize a long
    monologue at sentence boundaries instead of waiting out silence/max-segment,
    and to gate finalization entirely when an English target is involved."""
    t = (text or "").rstrip().rstrip('"”」』’\')')  # drop trailing quotes/brackets
    if not t:
        return False
    if t.endswith(_SENTENCE_END):
        return True
    last = t[-1]
    return last in _KO_SENTENCE_END or last in _JA_SENTENCE_END


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
        # Set by the server (via mark_sentence_complete) when the latest interim
        # ASR text for the CURRENT utterance ended in sentence punctuation. The
        # frame loop consumes it: punctuation + a tiny pause => finalize early.
        self._sentence_complete = False
        # Whether this session's language pair involves English. When True (and
        # ENDPOINT["en_sentence_gate"] is on) a bare silence pause does NOT
        # finalize — we wait for a complete sentence or the max-segment net — so
        # an SVO clause is never cut where English reordering would break.
        self._english = False

    def set_english_target(self, english: bool):
        """Server tells us if the active language pair involves English, so we
        can switch on the sentence-gate (keep clauses whole for SVO output)."""
        self._english = bool(english)

    def mark_sentence_complete(self, seq: int):
        """Server feedback: the interim transcription for utterance `seq` looks
        like a finished sentence (ended in . 。 ? !). Only honored if it's the
        utterance we're still accumulating — a stale seq is ignored."""
        if seq == self._seq and self._triggered:
            self._sentence_complete = True

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
            # Only transcribe the most recent window so interim cost stays flat
            # as the utterance grows. Finals (below) still use the full buffer.
            #
            # Under the English gate a sentence can run up to max_segment before
            # it finalizes, so a 6s interim window would show only the TAIL of a
            # long clause — the preview would then jump when the (full-buffer)
            # final lands. Widen the interim window to cover the whole gated
            # utterance so the grey preview tracks the full sentence as it grows.
            # KO<->JA keeps the cheap fixed window (their finals come fast).
            interim_window_ms = settings.INTERIM_WINDOW_MS
            if self._english and ENDPOINT["en_sentence_gate"]:
                interim_window_ms = max(interim_window_ms,
                                        ENDPOINT["max_segment_ms"])
            window_bytes = int(interim_window_ms / settings.FRAME_MS) \
                * settings.frame_bytes
            tail = bytes(self._buf[-window_bytes:]) if len(self._buf) > window_bytes \
                else bytes(self._buf)
            events.append(SegEvent("interim", tail, self._seq))

        # Finalize on any of:
        #  - a long-enough pause (normal end of turn),
        #  - a runaway-length safety flush (non-stop speaker), or
        #  - sentence punctuation + a tiny pause (the server told us the latest
        #    interim ended a sentence; we just need a brief breath to confirm it
        #    wasn't a mid-word whisper misfire). This is what lets a 1-2 min
        #    monologue finalize per-sentence instead of waiting out the pause.
        long_pause = self._silence_ms >= ENDPOINT["min_silence_ms"]
        too_long = self._seg_ms >= ENDPOINT["max_segment_ms"]
        punct_end = (ENDPOINT["punct_enabled"] and self._sentence_complete
                     and self._silence_ms >= ENDPOINT["punct_silence_ms"])
        # English-target gate: KO/JA are SOV so a mid-utterance breath can be cut
        # safely, but English (SVO) reordering can't cross a wrong cut, so a half
        # sentence comes out as a dangling phrase. When the pair involves English
        # we DROP the bare-pause trigger and only finalize on a complete sentence
        # (punct_end) or the max-segment safety net — keeping the clause whole.
        if self._english and ENDPOINT["en_sentence_gate"]:
            long_pause = False
        if long_pause or too_long or punct_end:
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
        self._sentence_complete = False
        self._preroll.clear()

    def flush(self) -> list[SegEvent]:
        """On stream close, finalize whatever is buffered."""
        events: list[SegEvent] = []
        if self._triggered and self._speech_ms >= settings.MIN_SPEECH_MS:
            events.append(SegEvent("final", bytes(self._buf), self._seq))
            self._seq += 1
        self._reset_utterance()
        return events
