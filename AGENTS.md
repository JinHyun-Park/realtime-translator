# Realtime Translator Agent Guide

## Project

This is an existing realtime translation system, not a scaffold:

1. The macOS app captures microphone and system audio as separate mono PCM16
   streams at 16 kHz.
2. The Python relay performs VAD endpointing, Whisper ASR, translation, room
   isolation, and viewer fan-out.
3. AWS hosts the GPU relay and the wake/stop infrastructure.

Preserve the separate mic/system paths. Mixing them before ASR is a known
quality regression.

## Read First

- `README.md`: architecture, behavior, configuration, and operations.
- `VERSIONS.md`: known-good tags, live infrastructure notes, and rollback.
- `QUICKSTART.md` and `INSTALL.md`: user-facing behavior.
- The nearest component `AGENTS.md` before changing `backend/`, `mac-app/`, or
  `deploy/`.

Treat docs as context, then confirm behavior in code. Some infrastructure notes
are snapshots and may be stale.

## Source Map

- `backend/server.py`: WebSocket relay, HTTP endpoints, controls, metrics, and
  session lifecycle.
- `backend/segmenter.py`: VAD and sentence-finalization behavior.
- `backend/asr.py`: faster-whisper wrapper and hallucination filters.
- `backend/translator.py`: Qwen/vLLM and Bedrock translation and insight.
- `backend/config.py`: all `RT_*` runtime settings.
- `mac-app/Sources/RealtimeTranslator/AppModel.swift`: app orchestration.
- `mac-app/Sources/RealtimeTranslator/Net/RelayClient.swift`: wire protocol.
- `deploy/`: AWS provisioning and operational scripts.

## Working Rules

- Keep changes focused. Do not rewrite the working architecture while fixing a
  component.
- Preserve the relay protocol across Python, Swift, `viewer.html`, and
  `history.html`. Search all consumers before changing message fields, paths,
  auth, rooms, or controls.
- Keep runtime settings environment-driven through `backend/config.py`.
- Never commit tokens, endpoints containing credentials, AWS state files,
  generated apps, DMGs, transcripts, or local agent state.
- Do not modify Claude Code configuration as part of Codex work.
- Update user or operator docs when behavior or operations change.

## Verification

Run the repository check after code changes:

```bash
./scripts/codex-check.sh
```

Use `RT_CHECK_PYTHON=/path/to/python` when dependencies live outside
`backend/.venv`.

Also run the focused checks in the relevant component guide. If a required
dependency, macOS permission, GPU model, or AWS service is unavailable, report
the skipped verification explicitly.

For backend or deployment changes intended for the live environment, local
checks are only the first stage. Follow `deploy/AGENTS.md`, use the existing AWS
workflow, and verify readiness and the changed behavior remotely.

## Git And Remotes

- `origin` is the Codex repository:
  `git@ssh.gitlab.aws.dev:jinstar/realtime-tanslator-openai-2026jul.git`.
- `legacy` is the original `hjeongho/realtime-translator` repository. Fetching
  for history is allowed; never push Codex work there.
- Do not push any branch unless the user asks for a push.
- Keep Codex branches under the `codex/` prefix unless instructed otherwise.

## AWS Safety

Live AWS operations are part of this project, but verify the active account,
region, instance state, and local deploy state before changing resources.
`deploy/launch.sh` creates an EC2 instance; it is not a generic in-place update.
Do not use `terminate` as routine cleanup unless the task explicitly requires
deleting the instance.
