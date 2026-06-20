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
            try:
                o = c.get_object(Bucket=settings.SESSION_BUCKET, Key=obj["Key"])
                out.append(json.loads(o["Body"].read()))
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
