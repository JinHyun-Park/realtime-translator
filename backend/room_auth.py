"""
Per-room secrets (opt-in privacy on a shared box).

Model — Trust On First Use (TOFU), secrets are opt-in:
  - A room with NO secret set is OPEN (anyone with the relay token can join) —
    this keeps existing app/links working (back-compat).
  - The FIRST connection that presents a secret for an unclaimed room CLAIMS it:
    the room is now locked to that secret. Afterwards every connection (capture
    AND viewer) to that room must present the matching secret, or it's refused.
  - Whoever knows the current secret can CHANGE it.

Secrets are NEVER stored in plaintext: we keep a salted PBKDF2 hash. The map is
persisted to S3 (rooms/<room>.json) so locks survive box restart/redeploy, with
an in-memory cache. All S3 ops are best-effort + off-thread; if S3 is
unavailable the lock still works for the box's current lifetime (in-memory).
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import logging

from config import settings

log = logging.getLogger("rt.room_auth")

_ITERATIONS = 120_000
# room -> {"salt": b64, "hash": b64} ; None-cache for "known to have no secret"
_CACHE: dict[str, dict | None] = {}
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
            log.warning("room_auth: boto3 unavailable (%s) — S3 persistence off",
                        e.__class__.__name__)
            _s3 = None
    return _s3


def _key(room: str) -> str:
    return f"rooms/{room.replace('/', '_')}.json"


def _hash(secret: str, salt: bytes) -> str:
    dk = hashlib.pbkdf2_hmac("sha256", secret.encode(), salt, _ITERATIONS)
    return base64.b64encode(dk).decode()


def _make_record(secret: str) -> dict:
    import os
    salt = os.urandom(16)
    return {"salt": base64.b64encode(salt).decode(), "hash": _hash(secret, salt)}


def _verify_record(rec: dict, secret: str) -> bool:
    try:
        salt = base64.b64decode(rec["salt"])
        return hmac.compare_digest(_hash(secret, salt), rec["hash"])
    except Exception:
        return False


# --- S3 persistence (sync, called via to_thread) ---------------------------

def _load_sync(room: str) -> dict | None:
    if not settings.SESSION_BUCKET:
        return None
    c = _client()
    if not c:
        return None
    try:
        o = c.get_object(Bucket=settings.SESSION_BUCKET, Key=_key(room))
        return json.loads(o["Body"].read())
    except Exception:
        return None   # no object => unclaimed


def _save_sync(room: str, rec: dict):
    if not settings.SESSION_BUCKET:
        return
    c = _client()
    if not c:
        return
    try:
        c.put_object(Bucket=settings.SESSION_BUCKET, Key=_key(room),
                     Body=json.dumps(rec).encode(), ContentType="application/json")
    except Exception as e:
        log.warning("room_auth save failed (%s): %s", room, e.__class__.__name__)


async def _get_record(room: str) -> dict | None:
    if room in _CACHE:
        return _CACHE[room]
    rec = await asyncio.to_thread(_load_sync, room)
    _CACHE[room] = rec
    return rec


# --- public API -------------------------------------------------------------

async def check_access(room: str, secret: str) -> bool:
    """Can a connection presenting `secret` (may be '') join `room`?
    Open if the room has no secret (opt-in). If it does, the secret must match.
    A non-empty secret for an UNCLAIMED room CLAIMS it (TOFU)."""
    rec = await _get_record(room)
    if rec is None:
        # Unclaimed. If a secret was offered, claim the room with it.
        if secret:
            new = _make_record(secret)
            _CACHE[room] = new
            await asyncio.to_thread(_save_sync, room, new)
            log.info("room %s claimed with a secret", room)
        return True
    return _verify_record(rec, secret)


async def is_locked(room: str) -> bool:
    return (await _get_record(room)) is not None


async def change_secret(room: str, current: str, new_secret: str) -> bool:
    """Owner-style rotation: succeeds only if `current` matches (or the room is
    unclaimed). `new_secret` must be non-empty. Returns True on success."""
    if not new_secret:
        return False
    rec = await _get_record(room)
    if rec is not None and not _verify_record(rec, current):
        return False
    new = _make_record(new_secret)
    _CACHE[room] = new
    await asyncio.to_thread(_save_sync, room, new)
    log.info("room %s secret changed", room)
    return True
