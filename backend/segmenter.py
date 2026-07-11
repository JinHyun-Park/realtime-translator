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
    # Multiplier on min_silence_ms when the latest interim text does NOT look
    # sentence-final: a breath mid-thought ("저희가 검토한 <pause> 방안은...")
    # must outlast a LONGER hold before pure silence cuts the sentence.
    # Complete-looking sentences still finalize fast via the punctuation path.
    "incomplete_hold": settings.INCOMPLETE_HOLD,
    # Sentence-boundary flush: finalize a COMPLETED sentence the moment more
    # speech follows it inside the same utterance (no pause needed) — a
    # non-stop talker gets per-sentence finals instead of 5-sentence blocks.
    "sentence_flush": settings.SENTENCE_FLUSH,
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


def find_flush_boundary(words, min_gap_s: float, edge_margin_s: float,
                        total_s: float):
    """Sentence-boundary flush: given interim word timings [(text, start, end)],
    find the LAST completed-sentence boundary that is safely inside the
    snapshot. Returns (split_time_s, n_words_before) or None.

    A boundary word must end like a sentence (punctuation — whisper's own
    completion judgment; KO/JA endings alone are too spurious word-medially),
    be followed by more speech after a small articulation gap (>= min_gap_s —
    a real inter-sentence junction has one; a mid-sentence decimal point
    doesn't), and sit clear of the still-being-revised window edge
    (edge_margin_s). Scanning from the END yields the most content per flush
    when several sentences completed in one tick."""
    if not words or len(words) < 2:
        return None
    for i in range(len(words) - 2, -1, -1):
        w_text, _w_start, w_end = words[i]
        t = (w_text or "").rstrip().rstrip('"”」』’\')')
        if not t or not t.endswith(_SENTENCE_END):
            continue
        nxt_start = words[i + 1][1]
        if nxt_start - w_end < min_gap_s:
            continue
        if w_end > total_s - edge_margin_s:
            continue
        return (w_end + min(min_gap_s, (nxt_start - w_end) / 2.0), i + 1)
    return None


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
        # Where the most recent interim snapshot began/ended inside _buf, so a
        # word timestamp (snapshot-relative) maps to a buffer split position.
        self._last_snapshot_start = 0
        self._last_snapshot_len = 0
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

    def mark_sentence_incomplete(self, seq: int):
        """Server feedback: the latest interim for `seq` does NOT look like a
        finished sentence — the speaker paused mid-thought. The silence trigger
        then waits longer (incomplete_hold x min_silence) before cutting."""
        if seq == self._seq and self._triggered:
            self._sentence_complete = False

    def split_at(self, seq: int, snapshot_time_s: float) -> SegEvent | None:
        """Sentence-boundary flush. `snapshot_time_s` is a word-timestamp
        position INSIDE the last interim snapshot for utterance `seq`, marking
        the end of a completed sentence with speech continuing after it. Split
        the live buffer there: return a FINAL event for the finished sentence
        (audio from utterance start through the boundary) and keep the
        remainder accumulating under a NEW seq — the current sentence's grey
        preview restarts cleanly.

        Returns None if the utterance already ended/changed (stale seq) or the
        split would leave either side too small to be meaningful."""
        if seq != self._seq or not self._triggered:
            return None
        fb = settings.frame_bytes
        # Map snapshot-relative seconds -> absolute buffer byte offset, framed.
        byte_in_snap = int(snapshot_time_s * settings.SAMPLE_RATE) * 2
        split = self._last_snapshot_start + byte_in_snap
        split = (split // fb) * fb
        min_bytes = int(settings.MIN_SPEECH_MS / settings.FRAME_MS) * fb
        if split < min_bytes or len(self._buf) - split < fb:
            return None
        head = bytes(self._buf[:split])
        remainder = self._buf[split:]
        ev = SegEvent("final", head, self._seq)
        # Re-arm the utterance state for the remainder: seq advances (clients
        # key interim previews by seq — the old preview is replaced by the
        # final; the remainder starts a fresh grey line), speech/segment clocks
        # restart at the remainder's actual length.
        self._seq += 1
        self._buf = remainder
        rem_ms = len(remainder) // fb * settings.FRAME_MS
        self._seg_ms = rem_ms
        self._speech_ms = rem_ms          # it was all speech (flush requires it)
        self._silence_ms = 0
        self._ms_since_interim = 0
        self._sentence_complete = False
        self._last_snapshot_start = 0
        self._last_snapshot_len = len(remainder)
        return ev

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
            # Sentence-flush bookkeeping: remember where this snapshot began in
            # the utterance buffer, so a word timestamp inside the snapshot can
            # be mapped back to an absolute buffer position (split point).
            self._last_snapshot_start = len(self._buf) - len(tail)
            self._last_snapshot_len = len(tail)
            events.append(SegEvent("interim", tail, self._seq))

        # Finalize on any of:
        #  - a long-enough pause (normal end of turn),
        #  - a runaway-length safety flush (non-stop speaker), or
        #  - sentence punctuation + a tiny pause (the server told us the latest
        #    interim ended a sentence; we just need a brief breath to confirm it
        #    wasn't a mid-word whisper misfire). This is what lets a 1-2 min
        #    monologue finalize per-sentence instead of waiting out the pause.
        # Incomplete-sentence hold: if the latest interim text did NOT look
        # sentence-final, a bare pause must last LONGER (hold x min_silence)
        # before it cuts — a mid-thought breath ("저희가 검토한 <숨> 방안은")
        # no longer splits the sentence. Sentence-final text keeps the normal
        # threshold, and the punctuation path below finalizes even faster.
        hold = 1.0 if self._sentence_complete else max(1.0, ENDPOINT["incomplete_hold"])
        long_pause = self._silence_ms >= ENDPOINT["min_silence_ms"] * hold
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
