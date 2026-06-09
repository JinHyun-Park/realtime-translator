#!/usr/bin/env python3
"""
loadtest.py — capacity load-test harness for a realtime translation relay.

Target relay: ws://127.0.0.1:8765 on the SAME g6e.12xlarge instance.
  - vLLM Qwen3-32B (translation) on GPU0
  - 6x faster-whisper large-v3 ASR workers on GPU1-3 (asyncio.Semaphore(6) + ThreadPoolExecutor)
  - per-connection Segmenter + Translator

Protocol (client -> server):
  1. connect
  2. send  text frame {"type":"config","pair":["ko","ja"]}
  3. stream raw PCM16 mono 16kHz BINARY frames (~640 bytes / 20 ms), real-time paced
Server -> client (text JSON frames):
  {"type":"interim"|"final","seq":N,"translation":"...", ...}

What this harness does:
  * Spawns N concurrent websocket streams (CLI arg).
  * Each stream loops a pool of real KO/JA(/EN) wav clips, inserting silence between them
    so it behaves like a continuous speaker and the server-side VAD finalizes sentences.
  * Audio is paced at WALL-CLOCK rate (20 ms chunk every 20 ms) — realistic load, NOT flat-out.
  * Per stream it measures: end-to-end latency = (time the last audio byte of an utterance
    was sent) -> (time its FINAL arrived), interim cadence, and dropped/empty finals.
  * Aggregates p50/p95 end-to-end latency across all streams.
  * A background sampler polls nvidia-smi (per-GPU util+mem) every ~2 s, and optionally the
    relay's in-flight ASR semaphore depth / queue via an HTTP metrics endpoint if exposed.

Dependencies: Python stdlib + `websockets` only. NO ffmpeg. WAV decoding via the `wave`
module; resampling to 16 kHz mono via simple linear interpolation / decimation.

Run:
    python3 loadtest.py --n 8 --audio-dir ./audio --duration 120
    python3 loadtest.py --n 32 --pair ko ja --metrics-url http://127.0.0.1:9000/metrics

Fetch audio first — see the FETCH_AUDIO heredoc at the bottom of this file, or:
    python3 loadtest.py --print-fetch-script
"""

import argparse
import asyncio
import contextlib
import glob
import json
import math
import os
import statistics
import struct
import sys
import time
import wave

try:
    import websockets
    # websockets>=11 exposes connect at top level; fall back for older versions.
    ws_connect = getattr(websockets, "connect", None)
    if ws_connect is None:
        from websockets.client import connect as ws_connect  # noqa: F401
    # ConnectionClosed lives at top level across versions.
    WSClosed = websockets.ConnectionClosed
except ImportError:
    sys.exit("ERROR: pip install websockets  (this harness needs websockets only)")

import urllib.request  # only used for the optional metrics-url poll

# ----------------------------------------------------------------------------- constants
SR = 16000                      # target sample rate the relay expects
CHUNK_MS = 20                   # 20 ms frames
SAMPLES_PER_CHUNK = SR * CHUNK_MS // 1000          # 320 samples
BYTES_PER_CHUNK = SAMPLES_PER_CHUNK * 2            # 640 bytes (PCM16 mono)
SILENCE_BETWEEN_CLIPS_S = 1.2   # gap to let VAD close an utterance (tunable)
LEAD_IN_SILENCE_S = 0.3         # tiny lead-in so the first utterance isn't clipped


# ============================================================================= AUDIO
def _read_wav_as_pcm16_16k_mono(path):
    """Decode a .wav with the stdlib `wave` module and return PCM16 mono @ 16 kHz.

    Handles: 8/16/24/32-bit PCM, mono or stereo (downmixed), any sample rate
    (resampled by linear interpolation — works for 44.1k/48k which are NOT integer
    multiples of 16k, and degrades to plain decimation for integer ratios).
    """
    with wave.open(path, "rb") as w:
        n_ch = w.getnchannels()
        sampwidth = w.getsampwidth()
        sr = w.getframerate()
        n_frames = w.getnframes()
        raw = w.readframes(n_frames)

    # --- decode raw bytes -> list of int samples per frame, interleaved channels
    if sampwidth == 2:
        fmt = "<%dh" % (len(raw) // 2)
        samples = struct.unpack(fmt, raw)
    elif sampwidth == 1:
        # 8-bit WAV is unsigned; center at 0 and scale to int16 range
        samples = tuple((b - 128) * 256 for b in raw)
    elif sampwidth == 4:
        fmt = "<%di" % (len(raw) // 4)
        s32 = struct.unpack(fmt, raw)
        samples = tuple(v >> 16 for v in s32)  # 32-bit -> 16-bit
    elif sampwidth == 3:
        # 24-bit little-endian signed
        out = []
        for i in range(0, len(raw), 3):
            b0, b1, b2 = raw[i], raw[i + 1], raw[i + 2]
            val = b0 | (b1 << 8) | (b2 << 16)
            if val & 0x800000:
                val -= 0x1000000
            out.append(val >> 8)  # 24 -> 16
        samples = tuple(out)
    else:
        raise ValueError("%s: unsupported sample width %d bytes" % (path, sampwidth))

    # --- downmix to mono (average channels)
    if n_ch > 1:
        mono = [
            sum(samples[i + c] for c in range(n_ch)) // n_ch
            for i in range(0, len(samples) - n_ch + 1, n_ch)
        ]
    else:
        mono = list(samples)

    # --- resample to 16 kHz
    if sr != SR and mono:
        if sr % SR == 0:
            # exact integer ratio -> decimation
            factor = sr // SR
            mono = mono[::factor]
        else:
            # linear interpolation (handles 44100/48000/22050 cleanly)
            out_len = int(len(mono) * SR / sr)
            ratio = sr / SR
            resampled = [0] * out_len
            for i in range(out_len):
                src = i * ratio
                lo = int(src)
                hi = min(lo + 1, len(mono) - 1)
                frac = src - lo
                resampled[i] = int(mono[lo] * (1 - frac) + mono[hi] * frac)
            mono = resampled

    # --- re-encode to PCM16 little-endian bytes, clamped
    clamped = bytearray()
    for v in mono:
        if v > 32767:
            v = 32767
        elif v < -32768:
            v = -32768
        clamped += struct.pack("<h", v)
    return bytes(clamped)


def _silence_pcm(seconds):
    return b"\x00\x00" * int(SR * seconds)


def load_clips(audio_dir):
    """Load every *.wav under audio_dir as 16k-mono PCM16. Returns [(name, pcm_bytes)]."""
    paths = sorted(glob.glob(os.path.join(audio_dir, "*.wav")))
    if not paths:
        sys.exit(
            "ERROR: no .wav files in %s — run the fetch script first "
            "(python3 loadtest.py --print-fetch-script)" % audio_dir
        )
    clips = []
    for p in paths:
        try:
            pcm = _read_wav_as_pcm16_16k_mono(p)
            dur = len(pcm) / 2 / SR
            clips.append((os.path.basename(p), pcm))
            print("  loaded %-24s %6.2fs  (%d KB pcm)" % (os.path.basename(p), dur, len(pcm) // 1024))
        except Exception as e:  # noqa: BLE001
            print("  SKIP %s: %s" % (p, e))
    if not clips:
        sys.exit("ERROR: no decodable wavs.")
    return clips


def build_speaker_track(clips, stream_idx, duration_s):
    """Build one continuous speaker track for a stream by looping/rotating the clips
    with inserted silence. Returns (track_bytes, utterance_end_offsets).

    utterance_end_offsets[i] = byte offset in track where utterance i's audio ENDS
    (i.e. the last audio byte before the trailing silence). We timestamp those sends
    to anchor end-to-end latency.
    """
    track = bytearray()
    track += _silence_pcm(LEAD_IN_SILENCE_S)
    utt_ends = []  # byte offsets (into track) where each utterance's audio finishes

    # Rotate clip order per-stream so N streams aren't perfectly synchronized.
    n = len(clips)
    order = [clips[(stream_idx + i) % n] for i in range(n)]

    target_bytes = int(duration_s * SR * 2)
    i = 0
    while len(track) < target_bytes:
        _name, pcm = order[i % len(order)]
        track += pcm
        utt_ends.append(len(track))           # audio ends here
        track += _silence_pcm(SILENCE_BETWEEN_CLIPS_S)
        i += 1
    return bytes(track), utt_ends


# ============================================================================= ONE STREAM
class StreamResult:
    def __init__(self, idx):
        self.idx = idx
        self.e2e_latencies = []     # seconds: utterance audio-end -> its FINAL
        self.interim_count = 0
        self.final_count = 0
        self.empty_final_count = 0
        self.utterances_sent = 0
        self.connect_ok = False
        self.error = None
        self.first_byte_to_first_interim = None


async def run_stream(uri, pair, clips, idx, duration_s, send_started_evt, result):
    """Drive one websocket stream: config -> paced PCM -> collect interim/final timings."""
    track, utt_ends = build_speaker_track(clips, idx, duration_s)
    result.utterances_sent = len(utt_ends)

    # utterance index -> wall-clock time its last audio byte was sent
    utt_end_send_time = {}
    # FIFO of utterance indices awaiting a FINAL (server emits finals in order per conn)
    pending = asyncio.Queue()
    done_recv = asyncio.Event()
    t_first_byte = [None]

    try:
        async with ws_connect(uri, max_size=None, ping_interval=20, ping_timeout=20) as ws:
            result.connect_ok = True
            await ws.send(json.dumps({"type": "config", "pair": list(pair)}))

            async def receiver():
                first_interim_seen = False
                try:
                    async for msg in ws:
                        if isinstance(msg, (bytes, bytearray)):
                            continue  # relay shouldn't send binary; ignore
                        now = time.perf_counter()
                        try:
                            obj = json.loads(msg)
                        except Exception:  # noqa: BLE001
                            continue
                        mtype = obj.get("type")
                        if mtype == "interim":
                            result.interim_count += 1
                            if not first_interim_seen and t_first_byte[0] is not None:
                                result.first_byte_to_first_interim = now - t_first_byte[0]
                                first_interim_seen = True
                        elif mtype == "final":
                            result.final_count += 1
                            translation = (obj.get("translation") or "").strip()
                            if not translation:
                                result.empty_final_count += 1
                            # Pair this FINAL with the oldest pending utterance.
                            if not pending.empty():
                                utt_i = await pending.get()
                                sent_t = utt_end_send_time.get(utt_i)
                                if sent_t is not None:
                                    result.e2e_latencies.append(now - sent_t)
                except WSClosed:
                    pass
                finally:
                    done_recv.set()

            recv_task = asyncio.create_task(receiver())

            # --- paced sender: one 640-byte chunk every 20 ms (wall clock)
            await send_started_evt.wait()  # barrier so all N streams start together
            start = time.perf_counter()
            next_utt = 0
            sent_bytes = 0
            total = len(track)
            chunk_idx = 0
            while sent_bytes < total:
                chunk = track[sent_bytes:sent_bytes + BYTES_PER_CHUNK]
                await ws.send(chunk)
                if t_first_byte[0] is None:
                    t_first_byte[0] = time.perf_counter()
                sent_bytes += len(chunk)

                # If this chunk crossed an utterance-end boundary, stamp it.
                while next_utt < len(utt_ends) and sent_bytes >= utt_ends[next_utt]:
                    utt_end_send_time[next_utt] = time.perf_counter()
                    await pending.put(next_utt)
                    next_utt += 1

                # Pace to wall clock: chunk_idx-th chunk should depart at start + idx*20ms.
                chunk_idx += 1
                target = start + chunk_idx * (CHUNK_MS / 1000.0)
                sleep = target - time.perf_counter()
                if sleep > 0:
                    await asyncio.sleep(sleep)
                # if sleep < 0 we're behind real-time (relay backpressure) — keep going,
                # the negative drift itself is a capacity signal captured in latency.

            # Drain: give the relay time to flush trailing finals.
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self_drain(pending, done_recv), timeout=15.0)

            await ws.close()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(recv_task, timeout=5.0)

    except Exception as e:  # noqa: BLE001
        result.error = "%s: %s" % (type(e).__name__, e)


async def self_drain(pending, done_recv):
    """Wait until all pending utterances have been matched to a final, or receiver ends."""
    while not pending.empty() and not done_recv.is_set():
        await asyncio.sleep(0.2)


# ============================================================================= SERVER SAMPLER
def _nvidia_smi_sample():
    """Return list of per-GPU dicts via nvidia-smi, or [] if unavailable."""
    import shutil
    import subprocess

    if shutil.which("nvidia-smi") is None:
        return None  # signal "not present"
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=index,utilization.gpu,memory.used,memory.total,power.draw",
                "--format=csv,noheader,nounits",
            ],
            timeout=3.0,
        ).decode()
    except Exception:  # noqa: BLE001
        return None
    gpus = []
    for line in out.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 5:
            continue
        try:
            gpus.append(
                {
                    "gpu": int(parts[0]),
                    "util": float(parts[1]),
                    "mem_used": float(parts[2]),
                    "mem_total": float(parts[3]),
                    "power": float(parts[4]),
                }
            )
        except ValueError:
            continue
    return gpus


def _metrics_sample(metrics_url):
    """Optionally poll the relay's metrics endpoint for ASR semaphore depth / queue.

    Expected (best-effort) JSON shape, e.g.:
        {"asr_inflight": 4, "asr_queue": 2, "active_connections": 12}
    Returns dict or None. The relay does NOT have to expose this — it's a bonus signal.
    To expose it server-side, add a tiny aiohttp/http.server handler that returns:
        sem._value style counters around the Semaphore(6).
    """
    if not metrics_url:
        return None
    try:
        with urllib.request.urlopen(metrics_url, timeout=2.0) as r:
            return json.loads(r.read().decode())
    except Exception:  # noqa: BLE001
        return None


async def server_sampler(metrics_url, interval, stop_evt, samples_out):
    """Every `interval` s, snapshot nvidia-smi + optional relay metrics until stop_evt."""
    nvsmi_missing_warned = False
    t0 = time.perf_counter()
    while not stop_evt.is_set():
        gpus = await asyncio.get_event_loop().run_in_executor(None, _nvidia_smi_sample)
        metrics = await asyncio.get_event_loop().run_in_executor(
            None, _metrics_sample, metrics_url
        )
        if gpus is None and not nvsmi_missing_warned:
            print("  [sampler] nvidia-smi not found — GPU sampling disabled "
                  "(run this harness ON the g6e instance).")
            nvsmi_missing_warned = True
        snap = {"t": round(time.perf_counter() - t0, 1), "gpus": gpus, "metrics": metrics}
        samples_out.append(snap)
        # live one-liner
        if gpus:
            g = " | ".join(
                "G%d %3.0f%% %5.0f/%5.0fMB" % (x["gpu"], x["util"], x["mem_used"], x["mem_total"])
                for x in gpus
            )
        else:
            g = "GPU n/a"
        m = ""
        if metrics:
            m = "  asr_inflight=%s asr_queue=%s conns=%s" % (
                metrics.get("asr_inflight", "?"),
                metrics.get("asr_queue", "?"),
                metrics.get("active_connections", "?"),
            )
        print("  [t=%5.1fs] %s%s" % (snap["t"], g, m))
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(stop_evt.wait(), timeout=interval)


# ============================================================================= AGGREGATION
def _pct(values, q):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * q
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return s[int(k)]
    return s[lo] * (hi - k) + s[hi] * (k - lo)


def report(results, samples, args, wall_elapsed):
    all_e2e = [x for r in results for x in r.e2e_latencies]
    ok = [r for r in results if r.connect_ok and not r.error]
    failed = [r for r in results if r.error or not r.connect_ok]

    print("\n" + "=" * 78)
    print("LOAD-TEST REPORT  —  N=%d streams, pair=%s->%s, ran %.1fs"
          % (args.n, args.pair[0], args.pair[1], wall_elapsed))
    print("=" * 78)
    print("Streams: %d connected ok, %d failed" % (len(ok), len(failed)))
    for r in failed:
        print("  stream %d FAILED: %s" % (r.idx, r.error or "connect failed"))

    print("\n-- End-to-end latency (utterance audio-end -> FINAL), across all streams --")
    if all_e2e:
        print("  count=%d  min=%.2fs  p50=%.2fs  p95=%.2fs  p99=%.2fs  max=%.2fs  mean=%.2fs"
              % (len(all_e2e), min(all_e2e), _pct(all_e2e, 0.50), _pct(all_e2e, 0.95),
                 _pct(all_e2e, 0.99), max(all_e2e), statistics.mean(all_e2e)))
    else:
        print("  NO finals matched to utterances — relay produced no usable FINALs.")

    tot_utt = sum(r.utterances_sent for r in results)
    tot_final = sum(r.final_count for r in results)
    tot_interim = sum(r.interim_count for r in results)
    tot_empty = sum(r.empty_final_count for r in results)
    matched = len(all_e2e)
    print("\n-- Throughput / drops --")
    print("  utterances sent : %d" % tot_utt)
    print("  finals received : %d  (empty: %d)" % (tot_final, tot_empty))
    print("  interims        : %d  (%.1f per final)"
          % (tot_interim, (tot_interim / tot_final) if tot_final else 0.0))
    print("  matched finals  : %d   => DROPPED/unmatched utterances: %d"
          % (matched, max(0, tot_utt - matched)))

    fbi = [r.first_byte_to_first_interim for r in results if r.first_byte_to_first_interim]
    if fbi:
        print("\n-- Interim cadence --")
        print("  first-audio -> first-interim: p50=%.2fs p95=%.2fs"
              % (_pct(fbi, 0.50), _pct(fbi, 0.95)))

    print("\n-- Per-stream e2e p50/p95 --")
    for r in sorted(results, key=lambda x: x.idx):
        if r.e2e_latencies:
            print("  stream %2d: n=%2d p50=%.2fs p95=%.2fs finals=%d empty=%d"
                  % (r.idx, len(r.e2e_latencies), _pct(r.e2e_latencies, 0.50),
                     _pct(r.e2e_latencies, 0.95), r.final_count, r.empty_final_count))
        else:
            print("  stream %2d: no matched finals (finals=%d err=%s)"
                  % (r.idx, r.final_count, r.error))

    print("\n-- Server samples (every ~%ss) --" % args.sample_interval)
    if samples and any(s["gpus"] for s in samples):
        peak = {}
        for s in samples:
            for g in (s["gpus"] or []):
                d = peak.setdefault(g["gpu"], {"util": 0, "mem": 0})
                d["util"] = max(d["util"], g["util"])
                d["mem"] = max(d["mem"], g["mem_used"])
        for gpu, d in sorted(peak.items()):
            print("  GPU%d peak util=%.0f%% peak mem=%.0f MB" % (gpu, d["util"], d["mem"]))
    else:
        print("  (no GPU samples — nvidia-smi absent or run off-instance)")
    if samples and any(s["metrics"] for s in samples):
        max_inflight = max((s["metrics"].get("asr_inflight", 0) or 0)
                           for s in samples if s["metrics"])
        max_queue = max((s["metrics"].get("asr_queue", 0) or 0)
                        for s in samples if s["metrics"])
        print("  relay: peak asr_inflight=%s (semaphore cap is 6), peak asr_queue=%s"
              % (max_inflight, max_queue))

    # machine-readable dump
    if args.json_out:
        blob = {
            "n": args.n, "pair": list(args.pair), "wall_elapsed": wall_elapsed,
            "e2e": {"count": len(all_e2e), "p50": _pct(all_e2e, 0.50),
                    "p95": _pct(all_e2e, 0.95), "p99": _pct(all_e2e, 0.99),
                    "max": max(all_e2e) if all_e2e else None},
            "utterances_sent": tot_utt, "finals": tot_final, "empty_finals": tot_empty,
            "interims": tot_interim, "matched": matched,
            "dropped": max(0, tot_utt - matched),
            "per_stream": [
                {"idx": r.idx, "n": len(r.e2e_latencies),
                 "p50": _pct(r.e2e_latencies, 0.50), "p95": _pct(r.e2e_latencies, 0.95),
                 "finals": r.final_count, "empty": r.empty_final_count, "error": r.error}
                for r in results
            ],
            "samples": samples,
        }
        with open(args.json_out, "w") as f:
            json.dump(blob, f, indent=2)
        print("\n  wrote machine-readable report -> %s" % args.json_out)
    print("=" * 78)


# ============================================================================= MAIN
async def amain(args):
    print("Loading audio clips from %s ..." % args.audio_dir)
    clips = load_clips(args.audio_dir)
    total_audio = sum(len(p) for _, p in clips) / 2 / SR
    print("  %d clips, %.1fs of source audio total" % (len(clips), total_audio))
    print("\nStarting %d streams against %s (pair %s->%s), target run ~%ds"
          % (args.n, args.uri, args.pair[0], args.pair[1], args.duration))

    results = [StreamResult(i) for i in range(args.n)]
    samples = []
    start_evt = asyncio.Event()
    stop_sampler = asyncio.Event()

    sampler = asyncio.create_task(
        server_sampler(args.metrics_url, args.sample_interval, stop_sampler, samples)
    )

    stream_tasks = [
        asyncio.create_task(
            run_stream(args.uri, args.pair, clips, i, args.duration, start_evt, results[i])
        )
        for i in range(args.n)
    ]

    # ramp: optionally stagger connects so we don't SYN-flood the relay
    if args.ramp > 0:
        await asyncio.sleep(args.ramp)

    t0 = time.perf_counter()
    start_evt.set()  # release the barrier — all streams begin pacing audio now
    await asyncio.gather(*stream_tasks)
    wall = time.perf_counter() - t0

    stop_sampler.set()
    with contextlib.suppress(Exception):
        await asyncio.wait_for(sampler, timeout=5.0)

    report(results, samples, args, wall)


FETCH_SCRIPT = r"""#!/usr/bin/env bash
# fetch_audio.sh — grab a few REAL 16k-mono speech wavs for the load test.
# No ffmpeg required for jfk.wav (already 16k mono). For others we keep them as-is;
# loadtest.py resamples/downmixes any rate/channels via the stdlib `wave` module.
set -euo pipefail
mkdir -p audio && cd audio

# 1) Whisper's canonical sample: EN, 16kHz mono, ~11s. (public, ships with openai/whisper)
curl -fL -o jfk.wav \
  https://raw.githubusercontent.com/openai/whisper/main/tests/jfk.wav

# 2) Mozilla Common Voice / public-domain style short clips via HF datasets mirror.
#    These are CC-0 / CC-BY single-utterance clips. If a URL 404s, drop it — the
#    harness runs with whatever wavs are present (even just jfk.wav looped).
#
#    Korean (ko) — Common Voice sample hosted on HF:
curl -fL -o ko_sample.wav \
  "https://huggingface.co/datasets/google/fleurs/resolve/main/data/ko_kr/audio/dev/dev_sample_ko.wav" || true

#    Japanese (ja):
curl -fL -o ja_sample.wav \
  "https://huggingface.co/datasets/google/fleurs/resolve/main/data/ja_jp/audio/dev/dev_sample_ja.wav" || true

# 3) GUARANTEED fallback: if the HF clips above failed, synthesize a couple of
#    SILENCE+TONE wavs so the harness still has multiple clips to rotate. These are
#    NOT speech (won't produce real translations) but exercise the pacing/VAD path.
python3 - <<'PY'
import os, wave, struct, math
SR=16000
def write_tone(path, secs, freq):
    if os.path.exists(path): return
    with wave.open(path,"wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        frames=bytearray()
        for i in range(int(SR*secs)):
            v=int(8000*math.sin(2*math.pi*freq*i/SR))
            frames+=struct.pack("<h",v)
        w.writeframes(bytes(frames))
# only create fallbacks if we have <2 real clips
import glob
if len([p for p in glob.glob("*.wav")]) < 2:
    write_tone("fallback_a.wav", 3.0, 220)
    write_tone("fallback_b.wav", 2.5, 330)
    print("added fallback tone wavs (no real HF speech clips downloaded)")
PY

echo "---- audio/ contents ----"
ls -la
echo
echo "NOTE: For best signal use REAL KO/JA speech. Easy ways to get more:"
echo "  * pip install datasets soundfile  &&  python3 -c \"" \
     "from datasets import load_dataset as L; import soundfile as sf;" \
     "d=L('google/fleurs','ko_kr',split='validation',streaming=True);" \
     "x=next(iter(d)); sf.write('audio/ko_real.wav', x['audio']['array'], 16000)\""
echo "  * Or record/save any KO/JA clip as 16k mono WAV; loadtest.py resamples otherwise."
"""


def build_parser():
    p = argparse.ArgumentParser(description="Realtime translation relay load-test harness.")
    p.add_argument("--n", type=int, default=4, help="number of concurrent streams")
    p.add_argument("--uri", default="ws://127.0.0.1:8765", help="relay websocket URI")
    p.add_argument("--pair", nargs=2, default=["ko", "ja"], metavar=("SRC", "DST"),
                   help="language pair, e.g. --pair ko ja")
    p.add_argument("--audio-dir", default="./audio", help="dir of source .wav clips")
    p.add_argument("--duration", type=int, default=120,
                   help="approx seconds of audio each stream sends (real-time paced)")
    p.add_argument("--ramp", type=float, default=0.0,
                   help="seconds to wait after connecting before all streams start (stagger)")
    p.add_argument("--sample-interval", type=float, default=2.0,
                   help="server sampling interval (s)")
    p.add_argument("--metrics-url", default=None,
                   help="optional relay metrics endpoint (JSON: asr_inflight/asr_queue/...)")
    p.add_argument("--json-out", default=None, help="write machine-readable report to this path")
    p.add_argument("--print-fetch-script", action="store_true",
                   help="print the audio-fetch shell script and exit")
    return p


def main():
    args = build_parser().parse_args()
    if args.print_fetch_script:
        print(FETCH_SCRIPT)
        return
    try:
        asyncio.run(amain(args))
    except KeyboardInterrupt:
        print("\ninterrupted.")


if __name__ == "__main__":
    main()
