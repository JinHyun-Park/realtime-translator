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

# Pool of ASR model replicas for CONCURRENT transcription. The old design used a
# single model behind one asyncio.Lock, which serialized every user's audio
# through one lane (fine for 1–2 users, a bottleneck for 20). Now N replicas run
# in parallel: a Semaphore bounds in-flight work to the pool size, a dedicated
# thread pool runs the blocking transcribe calls, and we round-robin replicas.
ASR_POOL: list[Asr] = []
ASR_SEM: asyncio.Semaphore | None = None
ASR_EXEC: concurrent.futures.ThreadPoolExecutor | None = None
_asr_rr = 0


async def run_asr(pcm: bytes, interim: bool):
    # Retry a transient ASR failure once; never let it bubble up and kill the
    # session. Returns None on hard failure so the caller skips this segment.
    global _asr_rr
    async with ASR_SEM:                       # bound in-flight == pool size
        model = ASR_POOL[_asr_rr % len(ASR_POOL)]
        _asr_rr += 1
        loop = asyncio.get_running_loop()
        for attempt in range(2):
            try:
                return await loop.run_in_executor(
                    ASR_EXEC, model.transcribe, pcm, interim
                )
            except Exception:
                if attempt == 1:
                    log.exception("ASR failed, skipping segment")
                    return None
                await asyncio.sleep(0.2)


async def handle(ws):
    # Top-level guard: no single client session can ever take down the server.
    try:
        await _handle(ws)
    except Exception:
        log.exception("unhandled session error (server stays up)")


async def _handle(ws):
    peer = getattr(ws, "remote_address", "?")
    log.info("client connected: %s", peer)
    seg = Segmenter()
    tr = Translator()
    pair: tuple[str, str] = ("ko", "ja")
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
            await ws.send(json.dumps({
                "type": "final" if is_final else "interim",
                "seq": ev.seq,
                "src": res.language,
                "tgt": tgt,
                "source": res.text,
                "translation": translation,
            }))
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


async def main():
    global ASR_POOL, ASR_SEM, ASR_EXEC
    n = max(1, settings.ASR_WORKERS)
    gpus = max(1, settings.ASR_NUM_GPUS)
    log.info("loading %d ASR replica(s) of '%s' across %d GPU(s) ...",
             n, settings.ASR_MODEL, gpus)
    # Load replicas sequentially (each pins to GPU i % gpus).
    ASR_POOL = [await asyncio.to_thread(Asr, i % gpus) for i in range(n)]
    ASR_SEM = asyncio.Semaphore(n)
    ASR_EXEC = concurrent.futures.ThreadPoolExecutor(max_workers=n)
    log.info("ASR pool ready: %d worker(s) on device=%s", n, ASR_POOL[0].device)
    log.info("LLM endpoint: %s model=%s", settings.LLM_BASE_URL, settings.LLM_MODEL)

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
