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
# fanned out to all of these. Broadcast mode: one app captures Zoom system audio,
# the relay transcribes/translates ONCE, and many browsers watch the subtitles.
VIEWERS: set = set()


async def broadcast(payload: dict):
    # Fan one interim/final payload out to all viewers; drop dead sockets.
    if not VIEWERS:
        return
    data = json.dumps(payload)
    dead = []
    for v in VIEWERS:
        try:
            await v.send(data)
        except Exception:
            dead.append(v)
    for v in dead:
        VIEWERS.discard(v)


def _ws_path(ws) -> str:
    return (getattr(getattr(ws, "request", None), "path", None)
            or getattr(ws, "path", "") or "")


def _is_viewer(ws) -> bool:
    # CloudFront forwards the path; viewers connect to /viewsock (capture uses /).
    path = _ws_path(ws).split("?", 1)[0]
    return path.rstrip("/").endswith("/viewsock") or "role=viewer" in _ws_path(ws)


def _authorized(ws) -> bool:
    # Simple shared-token gate. Open if RELAY_TOKEN unset (dev). Token may come
    # as ?token=... on the WS URL (browsers can't set WS headers) or as
    # Authorization: Bearer <token> (native app).
    if not settings.RELAY_TOKEN:
        return True
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
        if _is_viewer(ws):
            await _handle_viewer(ws)
        else:
            await _handle(ws)
    except Exception:
        log.exception("unhandled session error (server stays up)")
    finally:
        METRICS["active_connections"] -= 1


async def _handle_viewer(ws):
    # Read-only subscriber: receives broadcasts, sends nothing meaningful.
    peer = getattr(ws, "remote_address", "?")
    VIEWERS.add(ws)
    log.info("viewer connected: %s (viewers=%d)", peer, len(VIEWERS))
    try:
        await ws.send(json.dumps({"type": "ready", "role": "viewer"}))
        async for _ in ws:      # ignore anything a viewer sends; keepalive read
            pass
    except websockets.ConnectionClosed:
        pass
    finally:
        VIEWERS.discard(ws)
        log.info("viewer disconnected: %s (viewers=%d)", peer, len(VIEWERS))


async def _handle(ws):
    peer = getattr(ws, "remote_address", "?")
    log.info("client connected: %s", peer)
    seg = Segmenter()
    tr = Translator()
    pair: tuple[str, str] = ("ko", "ja")
    stream: str | None = None     # "me" | "them" — set via config, tags broadcasts
    # Drop stale interim work if a newer one for the same seq arrives.
    interim_tasks: dict[int, asyncio.Task] = {}

    await ws.send(json.dumps({"type": "ready"}))

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
                res.text, res.language, pair, final=is_final
            )
            if is_final:
                if translation.strip():
                    METRICS["finals_total"] += 1
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
            await broadcast(payload)             # to all read-only viewers
        except Exception as e:  # noqa
            if is_final:
                METRICS["finals_dropped"] += 1
            log.exception("process error")
            try:
                await ws.send(json.dumps({"type": "error", "message": str(e)}))
            except Exception:
                pass

    async def dispatch(events):
        for ev in events:
            if ev.kind == "interim":
                old = interim_tasks.get(ev.seq)
                if old and not old.done():
                    old.cancel()
                interim_tasks[ev.seq] = asyncio.create_task(process(ev, False))
            else:  # final
                old = interim_tasks.pop(ev.seq, None)
                if old and not old.done():
                    old.cancel()
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
                            # English (SVO) needs whole clauses, so activate the
                            # sentence-gate when either side of the pair is EN.
                            # KO<->JA pairs leave it off (snappy pause-based).
                            seg.set_english_target("en" in pair)
                            log.info("pair set to %s (english_gate=%s)",
                                     pair, "en" in pair)
                        s = msg.get("stream")
                        if s in ("me", "them"):
                            stream = s
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
        log.info("client disconnected: %s", peer)


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
            "viewers": len(VIEWERS)}


def _load_viewer_html() -> bytes:
    import pathlib
    p = pathlib.Path(__file__).parent / "viewer.html"
    try:
        return p.read_bytes()
    except Exception:
        return b"<!doctype html><h1>viewer.html missing</h1>"


_VIEWER_HTML = _load_viewer_html()


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
        # Open if RELAY_TOKEN unset (dev). Token via ?token= or X-Wake-Token header
        # (the app already sends X-Wake-Token on /wake, so we accept the same one).
        if not settings.RELAY_TOKEN:
            return True
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

    async def cb(reader, writer):
        try:
            req = await reader.read(2048)
            first = req.split(b"\r\n", 1)[0]
            raw = first.split(b" ")[1] if b" " in first else b"/"
            parsed = urlparse(raw.decode(errors="ignore"))
            path = parsed.path.encode()
            qs = parse_qs(parsed.query)
            if path in (b"/view", b"/view/", b"/viewer.html", b"/"):
                body, ctype = _VIEWER_HTML, b"text/html; charset=utf-8"
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
            elif path in (b"/control/idle", b"/control/stop", b"/control/llm",
                          b"/control/endpoint"):
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
        capture = METRICS["active_connections"] - len(VIEWERS)
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
