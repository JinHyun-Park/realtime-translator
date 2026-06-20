"""Unit tests for the English-target sentence gate + KO/JA sentence-final
detection added to fix English (SVO) sentences being chopped at a mid-utterance
Korean breath. Run from backend/:  python3 test_en_gate.py

We stub webrtcvad so speech/silence frames are scripted deterministically — no
audio, no GPU. Each "frame" is FRAME_MS of either speech or silence.
"""
import sys
import types

# --- Make the VAD deterministic: a frame of all 0xFF bytes == speech, all 0x00
#     == silence. We monkeypatch the webrtcvad.Vad the Segmenter constructs. ---
import webrtcvad

_real_vad = webrtcvad.Vad


class FakeVad:
    def __init__(self, *a, **k):
        pass

    def is_speech(self, frame, rate):
        # speech frames are nonzero; silence frames are all-zero
        return any(frame)


webrtcvad.Vad = FakeVad

from config import settings           # noqa: E402
from segmenter import Segmenter, ENDPOINT, ends_sentence  # noqa: E402

FB = settings.frame_bytes
SPEECH = b"\xff" * FB
SILENCE = b"\x00" * FB


def feed(seg, frames):
    """Feed a list of ('s'|'q', count) runs; return all events emitted."""
    events = []
    for kind, n in frames:
        chunk = (SPEECH if kind == "s" else SILENCE) * n
        events.extend(seg.add_audio(chunk))
    return events


def ms_to_frames(ms):
    return ms // settings.FRAME_MS


def n_finals(events):
    return sum(1 for e in events if e.kind == "final")


passed = 0
failed = 0


def check(name, cond):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}")


print("== ends_sentence: KO/JA endings + punctuation, NOT connective particles ==")
# Completed sentences
check("KO -요 complete", ends_sentence("모두 연락은 갈 것 같아요"))
check("KO -다 complete", ends_sentence("내일 회의를 합니다"))
check("KO punctuation complete", ends_sentence("그래요?"))
check("JA -ます complete", ends_sentence("よろしくお願いします"))
check("EN punctuation complete", ends_sentence("I think everyone will be contacted."))
# The screenshot's mid-sentence fragment must NOT look complete (조사 한테)
check("KO 조사 '한테' NOT complete", not ends_sentence("핏이 맞을 것 같은 부서들한테"))
check("KO 조사 '에서' NOT complete", not ends_sentence("저번 회의에서"))
check("empty NOT complete", not ends_sentence(""))


print("\n== English gate: bare pause does NOT finalize; sentence-complete does ==")
# A pause long enough to normally finalize (min_silence_ms), but no sentence
# completion signal. With the gate ON (English pair), this must NOT finalize.
seg = Segmenter()
seg.set_english_target(True)
pause_frames = ms_to_frames(ENDPOINT["min_silence_ms"]) + 2
ev = feed(seg, [
    ("s", ms_to_frames(2000)),   # 2s of speech (a partial clause)
    ("q", pause_frames),         # a breath longer than min_silence
])
check("EN gate: breath alone does NOT finalize", n_finals(ev) == 0)

# Now the server marks the sentence complete (Whisper punctuated/ended it) and a
# tiny pause follows -> SHOULD finalize even under the gate.
seg2 = Segmenter()
seg2.set_english_target(True)
ev2 = feed(seg2, [("s", ms_to_frames(2000))])
seg2.mark_sentence_complete(seg2._seq)   # server feedback: sentence done
ev2 += feed(seg2, [("q", ms_to_frames(ENDPOINT["punct_silence_ms"]) + 2)])
check("EN gate: sentence-complete + tiny pause DOES finalize", n_finals(ev2) == 1)

# Max-segment safety net still fires under the gate (runaway speaker).
seg3 = Segmenter()
seg3.set_english_target(True)
ev3 = feed(seg3, [("s", ms_to_frames(ENDPOINT["max_segment_ms"]) + 4)])
check("EN gate: max-segment still force-finalizes", n_finals(ev3) >= 1)


print("\n== English gate: interim preview covers the FULL long sentence ==")
# Speak 7s continuously (longer than the 6s default interim window) under the
# gate. The latest interim must reflect ~the whole utterance, not just the last
# 6s tail — otherwise the preview jumps when the full-buffer final lands.
seg_iw = Segmenter()
seg_iw.set_english_target(True)
speak_ms = 7000
ev_iw = feed(seg_iw, [("s", ms_to_frames(speak_ms))])
interims = [e for e in ev_iw if e.kind == "interim"]
check("EN gate: interim emitted while speaking", len(interims) > 0)
# the longest interim payload should exceed the 6s default window (i.e. window
# was widened to max_segment). Compare against what the default window would cap.
default_win_bytes = int(settings.INTERIM_WINDOW_MS / settings.FRAME_MS) * FB
longest = max(len(e.pcm) for e in interims)
check("EN gate: interim window widened past default 6s",
      longest > default_win_bytes)

# Control: a KO<->JA session keeps the cheap fixed 6s interim window.
seg_iw2 = Segmenter()
seg_iw2.set_english_target(False)
ev_iw2 = feed(seg_iw2, [("s", ms_to_frames(speak_ms))])
interims2 = [e for e in ev_iw2 if e.kind == "interim"]
longest2 = max(len(e.pcm) for e in interims2)
check("KO<->JA: interim window stays capped at default",
      longest2 <= default_win_bytes)


print("\n== KO<->JA (no English): bare pause STILL finalizes (unchanged) ==")
seg4 = Segmenter()
seg4.set_english_target(False)
ev4 = feed(seg4, [
    ("s", ms_to_frames(2000)),
    ("q", ms_to_frames(ENDPOINT["min_silence_ms"]) + 2),
])
check("KO<->JA: breath finalizes as before", n_finals(ev4) == 1)


print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
