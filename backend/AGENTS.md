# Backend Agent Guide

## Runtime And Flow

The backend is Python asyncio with two listeners:

- WebSocket relay on `RT_PORT` (default `8765`).
- HTTP control and status server on port `9000`.

Each capture WebSocket owns a `Segmenter`, ASR work, and ordered final queue.
Room-level state shares translation context and fans messages out to viewers.
Avoid blocking the event loop; model and storage calls already use async
clients, executors, or worker queues where needed.

The wire path is:

```text
PCM16 -> Segmenter -> ASR -> Translator -> app + room viewers + archive
```

## Important Contracts

- Audio is mono PCM16 little-endian at 16 kHz in 30 ms VAD frames.
- Capture uses `/`; viewers use `/viewsock`. Both are token- and room-gated.
- Client messages configure `pair`, `stream`, and UI `lang`.
- Server messages include `ready`, `interim`, `final`, `refine`, and `error`.
- Finals must remain ordered. Interim work may be replaced or skipped, but it
  must not delay or reorder finals.
- Endpointing behavior is intentionally coupled to interim ASR feedback. Review
  `segmenter.py`, its callers in `server.py`, and `test_en_gate.py` together.
- An empty relay token is open only on loopback unless `RT_ALLOW_OPEN=1`.

## Editing

- Add new runtime knobs to `config.py` with an `RT_*` environment override.
- Preserve vLLM fallback behavior when changing Bedrock translation.
- Keep room state isolated and remove empty room buckets.
- Treat subtitle text as untrusted model output and keep sanitization in the
  translation path.
- Keep `viewer.html` and `history.html` dependency-free unless the project
  intentionally adopts a frontend toolchain.

## Verification

Syntax:

```bash
git ls-files -z '*.py' | xargs -0 python3 -m py_compile
```

Endpointing behavior, using an interpreter that has `webrtcvad`:

```bash
cd backend
RT_INCOMPLETE_HOLD=1 python3 test_en_gate.py
```

The override isolates this English-gate test from the later incomplete-sentence
hold feature. Test default hold behavior separately when changing that feature.

For relay behavior, use `run_local.sh` only when Ollama and the model dependency
are intentionally available. Model-backed translation, Bedrock, S3 history, and
EC2 self-stop require targeted integration or live-environment checks.
