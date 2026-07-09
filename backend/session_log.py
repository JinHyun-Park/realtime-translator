"""
Session history — append-only METADATA log of capture sessions, persisted to S3
so it survives box stop/start/redeploy. NO transcript content is stored (privacy
by design): just room, start/end time, duration, finals count, language pairs,
and stream sides.

Layout in S3 (bucket = RT_SESSION_BUCKET, default = the deploy bucket):
    sessions/YYYY-MM-DD/<epoch_ms>-<room>.json     one object per ended session

The admin dashboard reads the most recent N days back via list_objects + get.
Writes are best-effort and fully async-offloaded: a failure to log a session
must never affect the live relay. If boto3/creds are missing (e.g. local dev),
logging silently no-ops.
"""
from __future__ import annotations

import asyncio
import json
import logging

from config import settings

log = logging.getLogger("rt.session_log")

_s3 = None
_s3_tried = False


def _client():
    global _s3, _s3_tried
    if _s3 is None and not _s3_tried:
        _s3_tried = True
        try:
            import boto3
            _s3 = boto3.client("s3", region_name=settings.SESSION_REGION)
        except Exception as e:
            log.warning("session-log: boto3 unavailable (%s) — logging disabled",
                        e.__class__.__name__)
            _s3 = None
    return _s3


def _put_sync(key: str, body: bytes):
    c = _client()
    if not c:
        return
    try:
        c.put_object(Bucket=settings.SESSION_BUCKET, Key=key, Body=body,
                     ContentType="application/json")
    except Exception as e:
        log.warning("session-log put failed (%s): %s", key, e.__class__.__name__)


async def log_session(record: dict, day: str, epoch_ms: int):
    """Append one ended-session metadata record to S3. Best-effort, off-thread,
    never raises into the caller. `day` = 'YYYY-MM-DD', `epoch_ms` for ordering;
    both are passed in (the relay can't call time during a clean shutdown path
    without them, and tests inject deterministic values)."""
    if not settings.SESSION_BUCKET:
        return
    room = (record.get("room") or "default").replace("/", "_")
    key = f"sessions/{day}/{epoch_ms}-{room}.json"
    body = json.dumps(record, ensure_ascii=False).encode()
    try:
        await asyncio.to_thread(_put_sync, key, body)
    except Exception:
        pass   # logging must never break the session


async def archive_session(meta: dict, day: str, epoch_ms: int,
                          lines: list[dict], truncated: bool):
    """On session end: build the full bilingual transcript + an auto summary &
    next-actions (via the insight model) and store it at
    sessions/<day>/<epoch_ms>-<room>.transcript.json. Best-effort; never raises.
    `meta` is the same metadata record written to the lightweight session log."""
    if not settings.SESSION_BUCKET:
        return
    room = (meta.get("room") or "default").replace("/", "_")
    key = f"sessions/{day}/{epoch_ms}-{room}.transcript.json"

    # Cleaned transcript FIRST: one Bedrock pass that de-fillers, fixes STT
    # mishears (similar-sounding wrong words re-classified from whole-session
    # context, terms normalized across lines), merges split sentences — for BOTH
    # source and translation. Runs BEFORE the summary so the summary digests the
    # corrected text instead of raw ASR (a misheard product name would otherwise
    # propagate into the summary/next-actions). Stored ALONGSIDE the raw
    # transcript (never replacing it); the dashboard shows cleaned by default
    # with a raw toggle. Best-effort: on any failure we omit it, the dashboard
    # falls back to raw, and the summary uses the raw lines.
    transcript_clean = None
    corrections = None
    if settings.CLEAN_TRANSCRIPT:
        try:
            from translator import clean_transcript
            cleaned = await clean_transcript(lines)
            if cleaned:
                transcript_clean, corrections = cleaned
        except Exception as e:
            log.warning("archive clean failed: %s", e.__class__.__name__)

    # Auto summary + next actions — from the CLEANED transcript when available.
    summary = {}
    try:
        from translator import generate_insight
        base = transcript_clean or lines
        convo = [f"{('ME' if x.get('stream') in ('me','mic') else 'THEM')}: "
                 f"{x.get('translation') or x.get('source','')}" for x in base]
        if convo:
            # End-of-session summary digests the WHOLE transcript at once, so it
            # needs a far longer timeout than a live insight refresh — a long
            # meeting (100+ lines) otherwise hits APITimeoutError and the archive
            # saves {"error": ...} instead of a summary (the dashboard then shows
            # one stream summarized and the other blank). Mirror clean_transcript.
            summary = await generate_insight(
                "", convo, "final", meta.get("lang", "ko"),
                timeout=settings.LLM_TIMEOUT * 3)
    except Exception as e:
        log.warning("archive summary failed: %s", e.__class__.__name__)
        summary = {"error": "summary generation failed"}

    record = {**meta, "truncated": truncated, "lines": len(lines),
              "transcript": lines, "summary": summary}
    if transcript_clean:
        record["transcript_clean"] = transcript_clean
    if corrections:
        record["corrections"] = corrections
    try:
        await asyncio.to_thread(
            _put_sync, key, json.dumps(record, ensure_ascii=False).encode())
        log.info("archived session transcript: %s (%d lines)", key, len(lines))
    except Exception:
        pass


def _get_sync(key: str) -> dict | None:
    c = _client()
    if not c:
        return None
    try:
        o = c.get_object(Bucket=settings.SESSION_BUCKET, Key=key)
        return json.loads(o["Body"].read())
    except Exception:
        return None


async def get_archive(key: str) -> dict | None:
    """Fetch one archived session transcript by its S3 key (admin detail view).
    Only keys under sessions/ are honored (caller-supplied key is constrained)."""
    if not settings.SESSION_BUCKET or not key.startswith("sessions/"):
        return None
    try:
        return await asyncio.to_thread(_get_sync, key)
    except Exception:
        return None


def _list_sync(days: list[str], limit: int) -> list[dict]:
    c = _client()
    if not c:
        return []
    out = []
    for day in days:
        try:
            resp = c.list_objects_v2(
                Bucket=settings.SESSION_BUCKET, Prefix=f"sessions/{day}/")
        except Exception:
            continue
        for obj in resp.get("Contents", []):
            key = obj["Key"]
            # History lists one entry per session = the lightweight meta object.
            # Skip the heavy *.transcript.json (fetched on demand for detail).
            if key.endswith(".transcript.json"):
                continue
            try:
                o = c.get_object(Bucket=settings.SESSION_BUCKET, Key=key)
                rec = json.loads(o["Body"].read())
                # Point at this session's transcript archive (same id, by convention)
                rec["transcript_key"] = key[:-len(".json")] + ".transcript.json"
                out.append(rec)
            except Exception:
                continue
    # newest first by end time (fall back to start)
    out.sort(key=lambda r: r.get("ended_ms", r.get("started_ms", 0)), reverse=True)
    return out[:limit]


async def recent_sessions(days: list[str], limit: int = 200) -> list[dict]:
    """Read recent session records across the given day-partitions (newest
    first). Returns [] on any failure so the dashboard degrades gracefully."""
    if not settings.SESSION_BUCKET:
        return []
    try:
        return await asyncio.to_thread(_list_sync, days, limit)
    except Exception:
        return []


async def sessions_for_room(room: str, days: list[str], limit: int = 100) -> list[dict]:
    """Sessions belonging to ONE room (for the per-room user history page).
    Same data as recent_sessions but filtered to `room` — a user only ever sees
    their own room's sessions."""
    if not settings.SESSION_BUCKET or not room:
        return []
    try:
        allrecs = await asyncio.to_thread(_list_sync, days, 1000)
    except Exception:
        return []
    return [r for r in allrecs if r.get("room") == room][:limit]
