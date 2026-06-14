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
from segmenter import Segmenter
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
}
_wait_samples: list[float] = []


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
        try:
            res = await run_asr(ev.pcm, interim=not is_final)
            if res is None or not res.text.strip():
                return
            translation, tgt = await tr.translate(
                res.text, res.language, pair, final=is_final
            )
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
                            log.info("pair set to %s", pair)
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
    s = sorted(_wait_samples)
    p95 = s[int(len(s) * 0.95)] if s else 0.0
    return {**METRICS, "asr_wait_ms_p95": round(p95, 1),
            "asr_workers": settings.ASR_WORKERS, "viewers": len(VIEWERS)}


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
    async def cb(reader, writer):
        try:
            req = await reader.read(2048)
            first = req.split(b"\r\n", 1)[0]
            path = first.split(b" ")[1] if b" " in first else b"/"
            path = path.split(b"?", 1)[0]
            if path in (b"/view", b"/view/", b"/viewer.html", b"/"):
                body, ctype = _VIEWER_HTML, b"text/html; charset=utf-8"
            else:  # /metrics or anything else
                body = json.dumps(_metrics_snapshot()).encode()
                ctype = b"application/json"
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: " + ctype +
                         b"\r\nContent-Length: " + str(len(body)).encode() +
                         b"\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" + body)
            await writer.drain()
        except Exception:
            pass
        finally:
            writer.close()
    server = await asyncio.start_server(cb, "0.0.0.0", port)
    log.info("http (viewer + metrics) on http://0.0.0.0:%d", port)
    return server


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
