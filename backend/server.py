"""
Realtime translation relay — WebSocket server.

Protocol (client <-> server), all text frames are JSON; binary frames are audio:
  client -> server:
    - binary frame: raw PCM16 mono little-endian @ RT_SAMPLE_RATE (default 16k)
    - {"type":"config","pair":["ko","ja"]}   # set the translation pair
    - {"type":"end"}                          # flush & finalize

  server -> client:
    - {"type":"ready"}
    - {"type":"interim","seq":N,"src":"ko","tgt":"ja","source":"...","translation":"..."}
    - {"type":"final",  "seq":N,"src":"ko","tgt":"ja","source":"...","translation":"..."}
    - {"type":"error","message":"..."}

Each connection gets its own Segmenter + Translator (context history is
per-connection). ASR runs as a POOL of N replicas (RT_ASR_WORKERS) so many
users transcribe concurrently instead of serializing through one model.
"""
from __future__ import annotations

import asyncio
import collections
import concurrent.futures
import json
import logging

import websockets

from asr import Asr
from config import settings
from segmenter import Segmenter, ENDPOINT, ends_sentence
from translator import Translator

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)
log = logging.getLogger("relay")

# Single WhisperModel replicated across GPUs (device_index=[...]) with
# num_workers internal CTranslate2 workers. CTranslate2 routes each concurrent
# .transcribe() onto a free worker/GPU; we just submit N concurrent calls from a
# thread pool and bound concurrency with a semaphore. (One-model-per-GPU behind
# a shared pool is the pattern that crashed with "CUDA invalid argument".)
ASR: Asr | None = None
ASR_SEM: asyncio.Semaphore | None = None
ASR_EXEC: concurrent.futures.ThreadPoolExecutor | None = None

# Lightweight live metrics (for load testing / ops visibility).
METRICS = {
    "asr_inflight": 0,     # transcriptions currently running
    "asr_waiting": 0,      # coroutines blocked on the semaphore
    "active_connections": 0,
    "asr_wait_ms_p95": 0.0,
    # --- reliability counters (the "silent failures" we couldn't see before) ---
    "finals_total": 0,     # finalized utterances that produced a translation
    "finals_dropped": 0,   # finals that yielded NO usable translation (lost!)
    "asr_errors": 0,       # ASR calls that failed after retry
    "llm_errors": 0,       # translation calls that failed after retry
    "e2e_ms_p95": 0.0,     # final-translation end-to-end latency p95
    "uptime_s": 0,
    "vllm_up": False,      # is the translation backend actually answering?
    "vllm_consecutive_fail": 0,
}
_wait_samples: list[float] = []
_e2e_samples: list[float] = []   # end-to-end latency (ms) of finals
import time as _time
_START_TS = _time.time()

# Runtime-mutable idle-stop controls. Seeded from config (env vars set at boot)
# but the app can flip these live via /control/idle WITHOUT a redeploy:
#   - enabled=False  => the box NEVER auto-stops (stays up until manually stopped)
#   - seconds        => how long with zero capture before self-stop
# The idle loop re-reads this dict every cycle, so changes take effect within
# one IDLE_CHECK_S tick. NOTE: a stop/start resets this to the env defaults, so
# the app re-applies the user's preference on every wake.
IDLE = {
    "enabled": settings.IDLE_STOP_ENABLED,
    "seconds": settings.IDLE_STOP_S,
}


async def run_asr(pcm: bytes, interim: bool):
    # Retry a transient ASR failure once; never let it bubble up and kill the
    # session. Returns None on hard failure so the caller skips this segment.
    METRICS["asr_waiting"] += 1
    t0 = asyncio.get_running_loop().time()
    async with ASR_SEM:                       # bound in-flight == worker count
        wait_ms = (asyncio.get_running_loop().time() - t0) * 1000.0
        METRICS["asr_waiting"] -= 1
        METRICS["asr_inflight"] += 1
        _wait_samples.append(wait_ms)
        if len(_wait_samples) > 500:
            del _wait_samples[:len(_wait_samples) - 500]
        try:
            loop = asyncio.get_running_loop()
            for attempt in range(2):
                try:
                    return await loop.run_in_executor(
                        ASR_EXEC, ASR.transcribe, pcm, interim
                    )
                except Exception:
                    if attempt == 1:
                        METRICS["asr_errors"] += 1
                        log.exception("ASR failed, skipping segment")
                        return None
                    await asyncio.sleep(0.2)
        finally:
            METRICS["asr_inflight"] -= 1


# Read-only viewers (browsers). Every capture connection's interim/final JSON is
# fanned out to viewers IN THE SAME ROOM. Broadcast mode: one app captures Zoom
# system audio, the relay transcribes/translates ONCE, and many browsers watch.
#
# ROOM ISOLATION: one box can host several INDEPENDENT meetings at once. Every
# connection carries a room id (?room=... on the WS URL); a capture session's
# subtitles only reach viewers in the SAME room. Two people in different rooms
# (the app picks a distinct room per install) never see each other's captions.
# Viewers are bucketed per room; the default room keeps old single-room links
# working.
DEFAULT_ROOM = "default"
VIEWERS_BY_ROOM: dict[str, set] = {}

# Per-room CAPTURE session registry, for operator metrics. Keyed by room ->
# {capture sessions}. Each capture session is a dict the handler updates live
# (stream side me/them, language pair, counts, last-activity timestamp). This is
# metadata only — no transcript content is kept here.
CAPTURES_BY_ROOM: dict[str, list] = {}

# Per-room shared translation context. The mic ("me") and system-audio ("them")
# captures are separate WS connections, but they are two sides of ONE
# conversation — each side's Translator gets the same deque so pronouns/topic
# carry across speakers. Sized 2x the per-connection window since two streams
# feed it. Dropped when the room's last capture leaves.
CONTEXT_BY_ROOM: dict[str, collections.deque] = {}


def _total_viewers() -> int:
    # Viewers across ALL rooms (for metrics + the idle-stop capture math).
    return sum(len(s) for s in VIEWERS_BY_ROOM.values())


def _rooms_snapshot() -> list:
    # Operator view: one entry per active room with capture + viewer metadata.
    # Sorted by most-recently-active first. No transcript text — privacy by design.
    rooms = set(VIEWERS_BY_ROOM) | set(CAPTURES_BY_ROOM)
    out = []
    for room in rooms:
        caps = CAPTURES_BY_ROOM.get(room, [])
        last = max((c.get("last_ts", 0) for c in caps), default=0)
        out.append({
            "room": room,
            "captures": len(caps),
            "streams": sorted({c.get("stream") for c in caps if c.get("stream")}),
            "pairs": sorted({"-".join(c["pair"]) for c in caps if c.get("pair")}),
            "finals": sum(c.get("finals", 0) for c in caps),
            "viewers": len(VIEWERS_BY_ROOM.get(room, ())),
            "idle_s": (int(_time.time() - last) if last else None),
        })
    out.sort(key=lambda r: (r["idle_s"] is None, r["idle_s"] or 0))
    return out


async def broadcast(payload: dict, room: str):
    # Fan one interim/final payload out to viewers IN `room`; drop dead sockets.
    viewers = VIEWERS_BY_ROOM.get(room)
    if not viewers:
        return
    data = json.dumps(payload)
    dead = []
    for v in viewers:
        try:
            await v.send(data)
        except Exception:
            dead.append(v)
    for v in dead:
        viewers.discard(v)


async def kick_viewers(room: str, code: int = 4403, reason: str = "room locked") -> int:
    # Force-close EVERY currently-connected viewer in `room`. Used when a room
    # secret is set/rotated: the on-connect check only runs at handshake, so live
    # sockets survive a secret change until we actively drop them. After this,
    # their auto-reconnect re-hits the secret gate and is refused (4403) unless
    # they present the new secret. Captures are untouched.
    viewers = list(VIEWERS_BY_ROOM.get(room, ()))
    for v in viewers:
        try:
            await v.close(code=code, reason=reason)
        except Exception:
            pass
    return len(viewers)


def _ws_path(ws) -> str:
    return (getattr(getattr(ws, "request", None), "path", None)
            or getattr(ws, "path", "") or "")


def _ws_room(ws) -> str:
    # The meeting/room id from ?room=... — partitions captures and viewers so
    # concurrent meetings on one box stay isolated. Empty -> DEFAULT_ROOM.
    from urllib.parse import urlparse, parse_qs
    try:
        r = (parse_qs(urlparse(_ws_path(ws)).query).get("room") or [""])[0].strip()
        return r or DEFAULT_ROOM
    except Exception:
        return DEFAULT_ROOM


def _ws_room_secret(ws) -> str:
    # Optional per-room secret from ?rs=... (opt-in room privacy). Empty if none.
    from urllib.parse import urlparse, parse_qs
    try:
        return (parse_qs(urlparse(_ws_path(ws)).query).get("rs") or [""])[0]
    except Exception:
        return ""


def _is_viewer(ws) -> bool:
    # CloudFront forwards the path; viewers connect to /viewsock (capture uses /).
    path = _ws_path(ws).split("?", 1)[0]
    return path.rstrip("/").endswith("/viewsock") or "role=viewer" in _ws_path(ws)


def _authorized(ws) -> bool:
    # Shared-token gate. Token may come as ?token=... on the WS URL (browsers
    # can't set WS headers) or as Authorization: Bearer <token> (native app).
    #
    # Fail-closed: with NO token set, we allow connections only when it's safe to
    # be open (loopback bind, or explicit RT_ALLOW_OPEN=1). A tokenless relay
    # bound to a public interface refuses everything — a forgotten token must not
    # silently expose a cloud box. (See settings.auth_open.)
    if not settings.RELAY_TOKEN:
        return settings.auth_open
    import secrets as _secrets
    from urllib.parse import urlparse, parse_qs
    # 1) query param
    try:
        q = parse_qs(urlparse(_ws_path(ws)).query)
        tok = (q.get("token") or [""])[0]
        if tok and _secrets.compare_digest(tok, settings.RELAY_TOKEN):
            return True
    except Exception:
        pass
    # 2) Authorization header
    try:
        hdr = ws.request.headers.get("Authorization", "")
        if hdr.startswith("Bearer ") and _secrets.compare_digest(hdr[7:], settings.RELAY_TOKEN):
            return True
    except Exception:
        pass
    return False


async def handle(ws):
    # Top-level guard: no single client session can ever take down the server.
    METRICS["active_connections"] += 1
    try:
        if not _authorized(ws):
            log.warning("unauthorized connection rejected: %s",
                        getattr(ws, "remote_address", "?"))
            await ws.close(code=4401, reason="unauthorized")
            return
        # Per-room secret gate (opt-in): a locked room requires a matching ?rs=.
        # An unlocked room is open; offering a secret to an unclaimed room claims
        # it. Both captures and viewers must pass.
        from room_auth import check_access
        if not await check_access(_ws_room(ws), _ws_room_secret(ws)):
            log.warning("room secret mismatch: room=%s peer=%s",
                        _ws_room(ws), getattr(ws, "remote_address", "?"))
            await ws.close(code=4403, reason="room locked")
            return
        if _is_viewer(ws):
            await _handle_viewer(ws)
        else:
            await _handle(ws)
    except Exception:
        log.exception("unhandled session error (server stays up)")
    finally:
        METRICS["active_connections"] -= 1


async def _handle_viewer(ws):
    # Read-only subscriber: receives broadcasts for ITS ROOM only.
    peer = getattr(ws, "remote_address", "?")
    room = _ws_room(ws)
    viewers = VIEWERS_BY_ROOM.setdefault(room, set())
    viewers.add(ws)
    log.info("viewer connected: %s room=%s (room viewers=%d)", peer, room, len(viewers))
    try:
        await ws.send(json.dumps({"type": "ready", "role": "viewer"}))
        async for _ in ws:      # ignore anything a viewer sends; keepalive read
            pass
    except websockets.ConnectionClosed:
        pass
    finally:
        viewers.discard(ws)
        if not viewers:
            VIEWERS_BY_ROOM.pop(room, None)   # don't leak empty room buckets
        log.info("viewer disconnected: %s room=%s", peer, room)


async def _handle(ws):
    peer = getattr(ws, "remote_address", "?")
    room = _ws_room(ws)           # this capture's meeting; its finals go here only
    log.info("client connected: %s room=%s", peer, room)
    seg = Segmenter()
    ctx = CONTEXT_BY_ROOM.setdefault(
        room, collections.deque(maxlen=settings.CONTEXT_WINDOW * 2)
    )
    tr = Translator(history=ctx)
    pair: tuple[str, str] = ("ko", "ja")
    stream: str | None = None     # "me" | "them" — set via config, tags broadcasts
    # Register this capture session for operator metrics (metadata only).
    _started = _time.time()
    cap_info = {"stream": None, "pair": list(pair), "finals": 0, "lang": "ko",
                "started_ts": _started, "last_ts": _started}
    CAPTURES_BY_ROOM.setdefault(room, []).append(cap_info)
    # Accumulate this session's finalized lines in memory (capped) for the
    # end-of-session archive (full transcript + summary -> S3). Source + target
    # so the saved record is a complete bilingual transcript. The cap protects
    # memory on a very long meeting; we log if it's hit.
    transcript: list[dict] = []
    TRANSCRIPT_CAP = settings.ARCHIVE_MAX_LINES
    # Interim scheduling: interims tick every INTERIM_INTERVAL_MS but the
    # pipeline (ASR + translate) can take LONGER than one tick on a long
    # sentence. The old cancel-the-inflight-one policy then starved the screen:
    # every interim was cancelled by the next tick and the grey preview froze
    # mid-sentence. Instead run ONE worker per seq that always processes the
    # LATEST pending event to completion — the preview updates at the
    # pipeline's natural rate and never starves.
    interim_pending: dict[int, object] = {}    # seq -> latest unprocessed event
    interim_workers: dict[int, asyncio.Task] = {}

    await ws.send(json.dumps({"type": "ready"}))

    async def refine_later(seq: int, text: str, fast: str, res_lang: str,
                           tgt: str, line_ref: dict | None):
        """Fast-then-refine: the quick translation is already on screen; this
        re-translates with conversation context and pushes a same-seq "refine"
        frame so the app/viewer swap the line in place. Best-effort — any
        failure just leaves the fast subtitle as-is."""
        try:
            better = await tr.refine(text, fast, res_lang, tgt,
                                     speaker="ME" if stream == "me" else "THEM")
            if not better:
                return
            if line_ref is not None:       # archive gets the refined text too
                line_ref["translation"] = better
            payload = {
                "type": "refine", "seq": seq, "src": res_lang, "tgt": tgt,
                "source": text, "translation": better, "stream": stream,
            }
            await ws.send(json.dumps(payload))
            await broadcast(payload, room)
        except websockets.ConnectionClosed:
            pass
        except Exception:
            log.exception("refine error (subtitle keeps fast translation)")

    async def process(ev, is_final: bool):
        t0 = _time.time()
        try:
            res = await run_asr(ev.pcm, interim=not is_final)
            if res is None or not res.text.strip():
                # A final that produced no transcription = a lost sentence.
                if is_final:
                    METRICS["finals_dropped"] += 1
                    log.warning("final dropped (no ASR text) seq=%s stream=%s",
                                ev.seq, stream)
                return
            # Punctuation-aware endpointing: if this INTERIM transcription looks
            # like a completed sentence, tell the segmenter so it finalizes early
            # (after a tiny pause) instead of waiting out MIN_SILENCE/MAX_SEGMENT.
            # Lets a long no-pause monologue break per-sentence.
            if not is_final and ends_sentence(res.text):
                seg.mark_sentence_complete(ev.seq)
            translation, tgt = await tr.translate(
                res.text, res.language, pair, final=is_final,
                speaker="ME" if stream == "me" else "THEM",
            )
            if is_final:
                if translation.strip():
                    METRICS["finals_total"] += 1
                    cap_info["finals"] += 1            # operator metric counter
                    cap_info["last_ts"] = _time.time()  # room activity timestamp
                    # Accumulate the bilingual line for the end-of-session archive.
                    line_ref = None
                    if len(transcript) < TRANSCRIPT_CAP:
                        line_ref = {
                            "ts": int(_time.time() * 1000),
                            "stream": stream, "src": res.language, "tgt": tgt,
                            "source": res.text, "translation": translation,
                        }
                        transcript.append(line_ref)
                    elif len(transcript) == TRANSCRIPT_CAP:
                        transcript.append({"truncated": True})  # marker; logged below
                    # Fast-then-refine: show this translation NOW, then improve
                    # it in the background with conversation context.
                    if settings.REFINE_ENABLED:
                        asyncio.create_task(refine_later(
                            ev.seq, res.text, translation, res.language, tgt,
                            line_ref))
                    # end-to-end latency: process start -> ready to send
                    dt = (_time.time() - t0) * 1000.0
                    _e2e_samples.append(dt)
                    if len(_e2e_samples) > 500:
                        del _e2e_samples[:len(_e2e_samples) - 500]
                else:
                    # ASR gave text but translation came back empty = lost.
                    METRICS["finals_dropped"] += 1
                    log.warning("final dropped (empty translation) seq=%s src='%s'",
                                ev.seq, res.text[:40])
            payload = {
                "type": "final" if is_final else "interim",
                "seq": ev.seq,
                "src": res.language,
                "tgt": tgt,
                "source": res.text,
                "translation": translation,
                "stream": stream,
            }
            await ws.send(json.dumps(payload))   # to the capture client (app UI)
            await broadcast(payload, room)       # to viewers in THIS room only
        except Exception as e:  # noqa
            if is_final:
                METRICS["finals_dropped"] += 1
            log.exception("process error")
            try:
                await ws.send(json.dumps({"type": "error", "message": str(e)}))
            except Exception:
                pass

    async def interim_worker(seq: int):
        # Drain the latest pending interim for this seq until none remain.
        # Each iteration processes ONE event fully (ASR + translate + send);
        # ticks that arrived meanwhile just overwrite interim_pending[seq],
        # so we always work on the freshest audio and skip stale ones.
        while True:
            ev = interim_pending.pop(seq, None)
            if ev is None:
                interim_workers.pop(seq, None)
                return
            await process(ev, False)

    async def dispatch(events):
        for ev in events:
            if ev.kind == "interim":
                interim_pending[ev.seq] = ev
                w = interim_workers.get(ev.seq)
                if w is None or w.done():
                    interim_workers[ev.seq] = asyncio.create_task(
                        interim_worker(ev.seq))
            else:  # final
                interim_pending.pop(ev.seq, None)
                w = interim_workers.pop(ev.seq, None)
                if w and not w.done():
                    w.cancel()
                # Finals are awaited in order so context history stays coherent.
                await process(ev, True)

    try:
        async for message in ws:
            # A bad single frame must never drop the whole session.
            try:
                if isinstance(message, bytes):
                    await dispatch(seg.add_audio(message))
                else:
                    try:
                        msg = json.loads(message)
                    except json.JSONDecodeError:
                        continue
                    if msg.get("type") == "config":
                        p = msg.get("pair")
                        if isinstance(p, list) and len(p) == 2:
                            pair = (p[0], p[1])
                            cap_info["pair"] = list(pair)   # operator metric
                            # English (SVO) needs whole clauses, so activate the
                            # sentence-gate when either side of the pair is EN.
                            # KO<->JA pairs leave it off (snappy pause-based).
                            seg.set_english_target("en" in pair)
                            log.info("pair set to %s (english_gate=%s)",
                                     pair, "en" in pair)
                        s = msg.get("stream")
                        if s in ("me", "them"):
                            stream = s
                            cap_info["stream"] = s          # operator metric
                        lg = msg.get("lang")
                        if lg in ("ko", "ja", "en"):
                            cap_info["lang"] = lg           # UI lang -> summary lang
                    elif msg.get("type") == "end":
                        await dispatch(seg.flush())
            except websockets.ConnectionClosed:
                raise
            except Exception:
                log.exception("error handling frame, continuing")
    except websockets.ConnectionClosed:
        pass
    except Exception:
        log.exception("session loop error")
    finally:
        try:
            await dispatch(seg.flush())
        except Exception:
            pass
        # Deregister this capture from the metrics registry; drop empty room lists.
        caps = CAPTURES_BY_ROOM.get(room)
        if caps and cap_info in caps:
            caps.remove(cap_info)
            if not caps:
                CAPTURES_BY_ROOM.pop(room, None)
                CONTEXT_BY_ROOM.pop(room, None)   # meeting over — drop its context
        log.info("client disconnected: %s room=%s", peer, room)
        # Append this ended session's METADATA (no transcript) to S3 history, so
        # the operator can review past sessions across box restarts. Only log
        # sessions that actually produced something (finals>0) to skip noise.
        if cap_info["finals"] > 0:
            ended = _time.time()
            import datetime as _dt
            day = _dt.datetime.utcfromtimestamp(ended).strftime("%Y-%m-%d")
            record = {
                "room": room,
                "stream": cap_info["stream"],
                "pair": cap_info["pair"],
                "lang": cap_info.get("lang", "ko"),
                "finals": cap_info["finals"],
                "started_ms": int(cap_info["started_ts"] * 1000),
                "ended_ms": int(ended * 1000),
                "duration_s": int(ended - cap_info["started_ts"]),
            }
            try:
                from session_log import log_session
                asyncio.create_task(log_session(record, day, record["ended_ms"]))
            except Exception:
                pass
            # Archive the FULL bilingual transcript + an auto summary/next-actions.
            # Off-loaded so it never delays the disconnect path. Strips the
            # truncation marker (if any) and notes it on the record.
            if settings.ARCHIVE_TRANSCRIPT and transcript:
                truncated = bool(transcript and transcript[-1].get("truncated"))
                lines = [t for t in transcript if not t.get("truncated")]
                try:
                    from session_log import archive_session
                    asyncio.create_task(archive_session(
                        record, day, record["ended_ms"], lines, truncated))
                except Exception:
                    pass


def _metrics_snapshot() -> dict:
    def _p95(xs):
        s = sorted(xs)
        return round(s[int(len(s) * 0.95)], 1) if s else 0.0
    finals = METRICS["finals_total"]
    dropped = METRICS["finals_dropped"]
    drop_rate = round(dropped / (finals + dropped), 4) if (finals + dropped) else 0.0
    from translator import LLM
    return {**METRICS,
            "asr_wait_ms_p95": _p95(_wait_samples),
            "e2e_ms_p95": _p95(_e2e_samples),
            "finals_drop_rate": drop_rate,      # the headline reliability number
            "llm_errors": Translator.llm_errors,
            "llm_provider": LLM["provider"],         # vllm | bedrock (live)
            "bedrock_fallbacks": Translator.bedrock_fallbacks,
            "endpoint": dict(ENDPOINT),              # live sentence-seg knobs
            "uptime_s": int(_time.time() - _START_TS),
            "asr_workers": settings.ASR_WORKERS,
            "viewers": _total_viewers(),
            "rooms": len(VIEWERS_BY_ROOM)}


def _load_viewer_html() -> bytes:
    import pathlib
    p = pathlib.Path(__file__).parent / "viewer.html"
    try:
        return p.read_bytes()
    except Exception:
        return b"<!doctype html><h1>viewer.html missing</h1>"


_VIEWER_HTML = _load_viewer_html()


def _load_history_html() -> bytes:
    import pathlib
    p = pathlib.Path(__file__).parent / "history.html"
    try:
        return p.read_bytes()
    except Exception:
        return b"<!doctype html><h1>history.html missing</h1>"


_HISTORY_HTML = _load_history_html()

# Optional, out-of-tree operator console. admin_ext.py is NOT in git and NOT
# shipped — it exists only on the operator's own box. When absent, _ADMIN is None
# and the relay exposes NO /admin surface at all (the public code has zero admin
# logic). When present, server delegates /admin* requests to it.
try:
    import admin_ext as _ADMIN
except Exception:
    _ADMIN = None


async def _serve_http(port: int = 9000):
    # HTTP server: serves the viewer page (GET /view) AND metrics JSON (/metrics).
    # Bound to 0.0.0.0 so CloudFront can fetch the viewer page; lock :9000 to the
    # CloudFront origin-facing prefix list at the SG layer (per no-public rule).
    from urllib.parse import urlparse, parse_qs

    def _reply(writer, body: bytes, ctype: bytes, status: bytes = b"200 OK"):
        writer.write(b"HTTP/1.1 " + status + b"\r\nContent-Type: " + ctype +
                     b"\r\nContent-Length: " + str(len(body)).encode() +
                     b"\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" + body)

    def _http_token_ok(qs: dict, headers: bytes) -> bool:
        # Shared-token gate for control endpoints, mirroring _authorized() for WS.
        # Fail-closed when tokenless on a public bind (see settings.auth_open).
        # Token via ?token= or X-Wake-Token header (the app already sends
        # X-Wake-Token on /wake, so we accept the same one).
        if not settings.RELAY_TOKEN:
            return settings.auth_open
        import secrets as _secrets
        tok = (qs.get("token") or [""])[0]
        if tok and _secrets.compare_digest(tok, settings.RELAY_TOKEN):
            return True
        for line in headers.split(b"\r\n"):
            if line.lower().startswith(b"x-wake-token:"):
                hv = line.split(b":", 1)[1].strip().decode(errors="ignore")
                if hv and _secrets.compare_digest(hv, settings.RELAY_TOKEN):
                    return True
        return False

    async def _read_request(reader):
        # Read headers, then (for POST /insight) the body per Content-Length.
        # GET control endpoints have no body; /insight POSTs a JSON transcript
        # that can be tens of KB, so the old flat 2048-byte read isn't enough.
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 65536:
            chunk = await reader.read(4096)
            if not chunk:
                break
            head += chunk
        header_blob, _, rest = head.partition(b"\r\n\r\n")
        clen = 0
        for line in header_blob.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                try:
                    clen = int(line.split(b":", 1)[1].strip())
                except ValueError:
                    clen = 0
                break
        body = rest
        # Cap total body to keep a hostile client from exhausting memory.
        max_body = 2_000_000
        while len(body) < min(clen, max_body):
            chunk = await reader.read(min(65536, clen - len(body)))
            if not chunk:
                break
            body += chunk
        return header_blob, body

    async def cb(reader, writer):
        try:
            req, http_body = await _read_request(reader)
            first = req.split(b"\r\n", 1)[0]
            raw = first.split(b" ")[1] if b" " in first else b"/"
            parsed = urlparse(raw.decode(errors="ignore"))
            path = parsed.path.encode()
            qs = parse_qs(parsed.query)
            if _ADMIN and path.startswith(b"/admin"):
                # Operator-only views live in an OPTIONAL, OUT-OF-TREE module
                # (admin_ext.py) that is NOT in git and NOT shipped — present only
                # on the operator's own box. If it's absent, _ADMIN is None and
                # /admin doesn't exist at all (falls through to the 404-ish
                # default), so the public code reveals no admin surface.
                handled = await _ADMIN.handle(
                    path.decode(), qs,
                    snapshot=_rooms_snapshot,
                    viewers_by_room=VIEWERS_BY_ROOM,
                    captures_by_room=CAPTURES_BY_ROOM,
                    total_viewers=_total_viewers,
                    start_ts=_START_TS, now=_time.time,
                    settings=settings,
                )
                if handled is not None:
                    a_body, a_ctype, a_status = handled
                    _reply(writer, a_body, a_ctype, a_status)
                    await writer.drain(); return
                # not an admin sub-path the module handles -> fall through
                body = json.dumps(_metrics_snapshot()).encode()
                ctype = b"application/json"
            elif path in (b"/view", b"/view/", b"/viewer.html", b"/"):
                body, ctype = _VIEWER_HTML, b"text/html; charset=utf-8"
            elif path in (b"/history", b"/history/", b"/history/list", b"/history/get"):
                # Per-room session history for the ROOM'S USERS (not admin). A user
                # sees ONLY their own room's archived sessions (transcript + auto
                # summary). Auth = the shared relay token (?key=) AND, if the room
                # is locked, its room secret (?rs=) — same gate as joining the room.
                if path in (b"/history", b"/history/"):
                    body, ctype = _HISTORY_HTML, b"text/html; charset=utf-8"
                else:
                    room = (qs.get("room") or [DEFAULT_ROOM])[0].strip() or DEFAULT_ROOM
                    key = (qs.get("key") or qs.get("token") or [""])[0]
                    rs = (qs.get("rs") or [""])[0]
                    # token gate (box entry)
                    if not (settings.auth_open or
                            (settings.RELAY_TOKEN and key and
                             __import__("secrets").compare_digest(key, settings.RELAY_TOKEN))):
                        _reply(writer, b'{"error":"unauthorized"}', b"application/json",
                               b"401 Unauthorized"); await writer.drain(); return
                    # room-secret gate (room entry) — must match to read its archive
                    from room_auth import check_access
                    if not await check_access(room, rs):
                        _reply(writer, b'{"error":"room locked"}', b"application/json",
                               b"403 Forbidden"); await writer.drain(); return
                    import datetime as _dt
                    today = _dt.datetime.utcfromtimestamp(_time.time())
                    days = [(today - _dt.timedelta(days=i)).strftime("%Y-%m-%d") for i in range(14)]
                    if path == b"/history/list":
                        from session_log import sessions_for_room
                        sess = await sessions_for_room(room, days, limit=100)
                        body = json.dumps({"room": room, "sessions": sess,
                                           "enabled": bool(settings.SESSION_BUCKET)}).encode()
                    else:  # /history/get?id=<transcript_key>
                        from session_log import get_archive
                        akey = (qs.get("id") or [""])[0]
                        rec = await get_archive(akey)
                        # enforce the requested archive really belongs to this room
                        if rec is None or rec.get("room") != room:
                            _reply(writer, b'{"error":"not found"}', b"application/json",
                                   b"404 Not Found"); await writer.drain(); return
                        body = json.dumps(rec, ensure_ascii=False).encode()
                    ctype = b"application/json"
            elif path == b"/healthz":
                # Tiny readiness probe for the app's wake flow. Deliberately
                # leaks ONLY booleans (NOT full metrics): box stopped => the app
                # gets a CloudFront 502 (origin down); relay up but vLLM still
                # warming => {ready:false}; everything live => {ready:true} and
                # the app auto-presses Start. ASR is already loaded by the time
                # this server is listening (see main()).
                body = json.dumps({
                    "ok": True,
                    "vllm_up": METRICS["vllm_up"],
                    "ready": bool(METRICS["vllm_up"] and ASR is not None),
                }).encode()
                ctype = b"application/json"
            elif path == b"/control/room-secret":
                # Set/rotate a room's secret (opt-in room privacy). Requires the
                # relay token (box entry) AND the room's CURRENT secret (?current=)
                # unless the room is unclaimed. Params: room, current, new.
                if not _http_token_ok(qs, req):
                    _reply(writer, b'{"ok":false,"error":"unauthorized"}',
                           b"application/json", b"401 Unauthorized")
                    await writer.drain(); return
                room = (qs.get("room") or [DEFAULT_ROOM])[0].strip() or DEFAULT_ROOM
                current = (qs.get("current") or [""])[0]
                new_secret = (qs.get("new") or [""])[0]
                from room_auth import change_secret
                ok = await change_secret(room, current, new_secret)
                kicked = 0
                if ok:
                    # Drop everyone currently watching so the new secret actually
                    # takes effect NOW (live sockets bypass the handshake gate).
                    # Their reconnect without the new secret is refused (4403).
                    kicked = await kick_viewers(room)
                    log.warning("room-secret changed -> room=%s kicked %d viewers",
                                room, kicked)
                body = json.dumps({"ok": ok, "room": room, "kicked": kicked,
                                   "error": None if ok else "wrong current secret or empty new"}).encode()
                ctype = b"application/json"
            elif path in (b"/control/idle", b"/control/stop", b"/control/llm",
                          b"/control/endpoint", b"/control/clear"):
                # Token-gated controls the app drives. /control/idle flips
                # auto-stop on/off and sets the timeout live; /control/stop stops
                # the box right now; /control/llm switches the translation model
                # (Qwen <-> Claude/Bedrock). All reflect the user's explicit
                # intent, so the box obeys even mid-meeting.
                if not _http_token_ok(qs, req):
                    _reply(writer, b'{"ok":false,"error":"unauthorized"}',
                           b"application/json", b"401 Unauthorized")
                    await writer.drain()
                    return
                if path == b"/control/stop":
                    log.warning("manual /control/stop — stopping box now")
                    asyncio.create_task(_self_stop())
                    body = json.dumps({"ok": True, "stopping": True}).encode()
                elif path == b"/control/clear":
                    # PANIC WIPE: tell every viewer in this room to blank its
                    # on-screen subtitle log NOW. The relay keeps no backlog, so
                    # this only clears the live viewer DOM (long-lived browser tabs
                    # that have accumulated lines). New/reloaded viewers already
                    # start empty. Captures/transcripts on the app are untouched.
                    room = (qs.get("room") or [DEFAULT_ROOM])[0].strip() or DEFAULT_ROOM
                    n = len(VIEWERS_BY_ROOM.get(room, ()))
                    await broadcast({"type": "clear"}, room)
                    log.warning("control/clear -> room=%s viewers=%d wiped", room, n)
                    body = json.dumps({"ok": True, "room": room, "viewers": n}).encode()
                elif path == b"/control/llm":
                    # ?provider=bedrock | vllm  — live translation-model switch.
                    from translator import LLM
                    if "provider" in qs:
                        p = qs["provider"][0]
                        LLM["provider"] = "bedrock" if p == "bedrock" else "vllm"
                    log.info("control/llm -> provider=%s", LLM["provider"])
                    body = json.dumps({"ok": True, "provider": LLM["provider"]}).encode()
                elif path == b"/control/endpoint":
                    # Live sentence-segmentation tuning. Params (all optional):
                    #   silence_ms   -> ENDPOINT.min_silence_ms  (300..3000)
                    #   max_ms       -> ENDPOINT.max_segment_ms   (3000..30000)
                    #   punct        -> ENDPOINT.punct_enabled    (0/1)
                    #   punct_ms     -> ENDPOINT.punct_silence_ms (0..1500)
                    #   en_gate      -> ENDPOINT.en_sentence_gate (0/1) — keep
                    #                   English-target clauses whole (no bare-pause cut)
                    def _clamp_int(key, lo, hi):
                        if key in qs:
                            try:
                                return max(lo, min(hi, int(qs[key][0])))
                            except ValueError:
                                return None
                        return None
                    v = _clamp_int("silence_ms", 300, 3000)
                    if v is not None: ENDPOINT["min_silence_ms"] = v
                    v = _clamp_int("max_ms", 3000, 30000)
                    if v is not None: ENDPOINT["max_segment_ms"] = v
                    v = _clamp_int("punct_ms", 0, 1500)
                    if v is not None: ENDPOINT["punct_silence_ms"] = v
                    if "punct" in qs:
                        ENDPOINT["punct_enabled"] = (qs["punct"][0] not in ("0", "false", "False"))
                    if "en_gate" in qs:
                        ENDPOINT["en_sentence_gate"] = (qs["en_gate"][0] not in ("0", "false", "False"))
                    log.info("control/endpoint -> %s", ENDPOINT)
                    body = json.dumps({"ok": True, **ENDPOINT}).encode()
                else:  # /control/idle
                    if "enabled" in qs:
                        IDLE["enabled"] = (qs["enabled"][0] not in ("0", "false", "False"))
                    if "seconds" in qs:
                        try:
                            IDLE["seconds"] = max(60, int(qs["seconds"][0]))
                        except ValueError:
                            pass
                    log.info("control/idle -> enabled=%s seconds=%s",
                             IDLE["enabled"], IDLE["seconds"])
                    body = json.dumps({"ok": True, "enabled": IDLE["enabled"],
                                       "seconds": IDLE["seconds"]}).encode()
                ctype = b"application/json"
            elif path == b"/insight":
                # Live meeting copilot (SEPARATE from translation). The app POSTs
                # JSON {context, transcript:[lines], mode:"live"|"final"} only
                # while its insight toggle is ON, so this costs a Bedrock call
                # only on demand. Token-gated like the control endpoints.
                if not _http_token_ok(qs, req):
                    _reply(writer, b'{"error":"unauthorized"}',
                           b"application/json", b"401 Unauthorized")
                    await writer.drain()
                    return
                try:
                    data = json.loads(http_body or b"{}")
                except Exception:
                    _reply(writer, b'{"error":"bad json"}',
                           b"application/json", b"400 Bad Request")
                    await writer.drain()
                    return
                mode = data.get("mode") if data.get("mode") in ("live", "final") else "live"
                context = str(data.get("context", ""))
                lang = data.get("lang") if data.get("lang") in ("ko", "ja", "en") else "ko"
                transcript = data.get("transcript") or []
                if not isinstance(transcript, list):
                    transcript = []
                # Clamp line count server-side too (defense in depth; the app
                # already trims). Keep the most RECENT lines.
                cap = (settings.INSIGHT_FINAL_TRANSCRIPT_LINES if mode == "final"
                       else settings.INSIGHT_LIVE_TRANSCRIPT_LINES)
                lines = [str(x) for x in transcript][-cap:]
                from translator import generate_insight
                result = await generate_insight(context, lines, mode, lang)
                body = json.dumps({"mode": mode, **result}).encode()
                ctype = b"application/json"
            else:  # /metrics or anything else
                body = json.dumps(_metrics_snapshot()).encode()
                ctype = b"application/json"
            _reply(writer, body, ctype)
            await writer.drain()
        except Exception:
            pass
        finally:
            writer.close()
    server = await asyncio.start_server(cb, "0.0.0.0", port)
    log.info("http (viewer + metrics) on http://0.0.0.0:%d", port)
    return server


async def _vllm_health_loop():
    # Actively probe the translation backend. The dangerous failure mode is
    # "relay up, vLLM dead" — connections succeed but every translation drops
    # silently. We surface vllm_up in /metrics and, after sustained failure,
    # LOUDLY restart the rt-vllm service (best-effort; harmless if not systemd).
    import urllib.request
    base = settings.LLM_BASE_URL.rstrip("/")
    url = base[:-3] + "/v1/models" if base.endswith("/v1") else base + "/v1/models"
    while True:
        ok = False
        try:
            ok = await asyncio.to_thread(
                lambda: urllib.request.urlopen(url, timeout=4).status == 200)
        except Exception:
            ok = False
        METRICS["vllm_up"] = ok
        if ok:
            METRICS["vllm_consecutive_fail"] = 0
        else:
            METRICS["vllm_consecutive_fail"] += 1
            f = METRICS["vllm_consecutive_fail"]
            log.error("vLLM health check FAILED (consecutive=%d) at %s", f, url)
            # ~6 consecutive failures (~60s) => attempt a loud auto-recovery.
            if f == 6:
                log.error("vLLM down ~60s — restarting rt-vllm.service")
                try:
                    await asyncio.create_subprocess_exec(
                        "systemctl", "restart", "rt-vllm.service")
                except Exception:
                    log.exception("could not restart rt-vllm (not systemd?)")
        await asyncio.sleep(10)


async def _imds(path: str, token: str | None = None) -> str:
    # IMDSv2: stdlib urllib only. token=None => PUT to fetch the session token.
    import urllib.request
    base = "http://169.254.169.254/latest"
    def _get():
        if token is None:
            req = urllib.request.Request(
                base + "/api/token", method="PUT",
                headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"})
        else:
            req = urllib.request.Request(
                base + "/meta-data/" + path,
                headers={"X-aws-ec2-metadata-token": token})
        return urllib.request.urlopen(req, timeout=2).read().decode()
    return await asyncio.to_thread(_get)


async def _self_stop():
    # Best-effort: stop THIS instance to save money. Never raises into the loop.
    try:
        tok = await _imds("api/token")
        iid = await _imds("instance-id", tok)
        region = await _imds("placement/region", tok)
        log.warning("self-stop: stopping %s in %s", iid, region)
        try:
            import boto3
            await asyncio.to_thread(
                lambda: boto3.client("ec2", region_name=region)
                            .stop_instances(InstanceIds=[iid]))
        except ImportError:
            await asyncio.create_subprocess_exec(
                "aws", "ec2", "stop-instances",
                "--region", region, "--instance-ids", iid)
    except Exception:
        log.exception("self-stop failed (box stays up; retry next cycle)")


async def _idle_stop_loop():
    # Self-stop after IDLE["seconds"] of ZERO capture sessions. A meeting keeps
    # active_connections>=1 (mic+system sockets), so this never fires mid-meeting.
    # Viewers (read-only browser tabs) do NOT count — capture sessions only.
    #
    # IDLE is runtime-mutable (see /control/idle): the app can disable auto-stop
    # entirely (keep the box up) or change the timeout live. So unlike before we
    # do NOT return early when disabled — we keep looping and re-check every tick,
    # which lets the user toggle it back ON without a redeploy.
    idle_since = None
    booted = _time.time()
    log.info("idle-stop loop running: enabled=%s, stop after %ds idle, %ds boot grace",
             IDLE["enabled"], IDLE["seconds"], settings.IDLE_GRACE_S)
    while True:
        await asyncio.sleep(settings.IDLE_CHECK_S)
        if not IDLE["enabled"]:
            idle_since = None          # disarmed: never accumulate idle time
            continue
        if _time.time() - booted < settings.IDLE_GRACE_S:
            idle_since = None          # don't even arm the clock during grace
            continue
        capture = METRICS["active_connections"] - _total_viewers()
        if capture > 0 or METRICS["asr_inflight"] > 0:
            idle_since = None
            continue
        if idle_since is None:
            idle_since = _time.time()
            log.info("idle window started (no capture sessions)")
        elif _time.time() - idle_since >= IDLE["seconds"]:
            log.warning("idle %ds with zero capture sessions — self-stopping",
                        IDLE["seconds"])
            await _self_stop()
            return


async def main():
    global ASR, ASR_SEM, ASR_EXEC
    n = max(1, settings.ASR_WORKERS)
    gpus = max(1, settings.ASR_NUM_GPUS)
    # device_index = [0,1,..,gpus-1] (these are CUDA-VISIBLE indices; the relay's
    # CUDA_VISIBLE_DEVICES already maps them onto the physical whisper GPUs).
    dev_index = list(range(gpus)) if gpus > 1 else 0
    log.info("loading 1 ASR model '%s' on device_index=%s with %d workers ...",
             settings.ASR_MODEL, dev_index, n)
    ASR = await asyncio.to_thread(Asr, dev_index, n)
    ASR_SEM = asyncio.Semaphore(n)
    ASR_EXEC = concurrent.futures.ThreadPoolExecutor(max_workers=n)
    log.info("ASR ready: %d workers across %d GPU(s) on device=%s",
             n, gpus, ASR.device)
    log.info("LLM endpoint: %s model=%s", settings.LLM_BASE_URL, settings.LLM_MODEL)

    await _serve_http()
    asyncio.create_task(_vllm_health_loop())   # active backend watchdog
    asyncio.create_task(_idle_stop_loop())     # self-stop when idle (cost guard)
    async with websockets.serve(
        handle, settings.HOST, settings.PORT, max_size=None, ping_interval=20
    ):
        log.info("relay listening on ws://%s:%d", settings.HOST, settings.PORT)
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
