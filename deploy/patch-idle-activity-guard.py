#!/usr/bin/env python3
"""Retrofit the activity-based idle cost guard onto a DEPLOYED server.py.

Why a patch script instead of shipping the whole file: the running box may be on
a different branch than your checkout (release dirs under
/opt/realtime-translator/releases/), so overwriting server.py wholesale would
silently revert whatever else that release carries. This edits only the three
idle-guard sites, and refuses to touch the file if any of them do not match.

Usage:  python3 patch-idle-activity-guard.py /path/to/server.py [--check]
"""
import re
import sys

NEW_IDLE_TAIL = '''    # Timestamp of the last real TRANSLATION (a final that produced a subtitle).
    # THIS - not "is a capture socket open" - is what the cost guard measures.
    # A connection-based check can never stop a box whose app was left running
    # but silent (overnight, or a forgotten window), which is how this box ended
    # up billing a GPU for days at a time.
    "last_xlate": _time.time(),
}'''

NEW_LOOP = '''def idle_stop_decision(now, last_xlate, enabled, limit_s, booted, grace_s,
                       asr_inflight, asr_waiting):
    """Pure decision for the idle cost guard. Returns (stop, reset_activity).

    Split out of _idle_stop_loop so it can be unit-tested offline: getting this
    wrong either bills a GPU forever (never stops) or kills a live meeting
    (stops too eagerly), and both failures are silent. See test_idle_stop.py.
    """
    if not enabled:
        return False, True            # disarmed: don't bank idle time
    if now - booted < grace_s:
        return False, True            # boot grace: give the user time to start
    if asr_inflight > 0 or asr_waiting > 0:
        return False, True            # mid-transcription is activity
    return (now - last_xlate) >= limit_s, False


async def _idle_stop_loop():
    # Self-stop after IDLE["seconds"] with NO TRANSLATION ACTIVITY.
    #
    # This deliberately does NOT key off open capture sockets. That older rule
    # ("stop only when zero capture sessions") could never stop a box whose app
    # sat connected and silent, so a window left open overnight billed a GPU
    # instance until someone noticed. Speech keeps producing finals, which bump
    # IDLE["last_xlate"], so an active meeting is never interrupted; a quiet one
    # for IDLE["seconds"] straight is exactly what we want to shut down.
    #
    # IDLE is runtime-mutable (see /control/idle), so we keep looping and
    # re-check every tick rather than returning early when disabled.
    booted = _time.time()
    log.info("idle-stop loop running: enabled=%s, stop after %ds with no translation, "
             "%ds boot grace", IDLE["enabled"], IDLE["seconds"], settings.IDLE_GRACE_S)
    while True:
        await asyncio.sleep(settings.IDLE_CHECK_S)
        now = _time.time()
        stop, reset = idle_stop_decision(
            now, IDLE["last_xlate"], IDLE["enabled"], IDLE["seconds"],
            booted, settings.IDLE_GRACE_S,
            METRICS["asr_inflight"], METRICS["asr_waiting"])
        if reset:
            IDLE["last_xlate"] = now
        if not stop:
            continue
        quiet_s = now - IDLE["last_xlate"]
        capture = METRICS["active_connections"] - _total_viewers()
        log.warning("no translation for %ds (limit %ds, %d capture session(s) still "
                    "open) - self-stopping", int(quiet_s), IDLE["seconds"], capture)
        await _self_stop()
        return


'''


def patch(src: str) -> str:
    # --- 1. IDLE dict: add the activity timestamp -------------------------
    if '"last_xlate"' in src:
        raise SystemExit("already patched (last_xlate present) - nothing to do")
    m = re.search(r'^IDLE = \{\n(?:.*\n)*?\}\n', src, re.M)
    if not m:
        raise SystemExit("FAIL: could not find the IDLE = { ... } block")
    idle_block = m.group(0)
    src = src.replace(idle_block, idle_block[: idle_block.rindex("}")] + NEW_IDLE_TAIL + "\n", 1)

    # --- 2. bump the timestamp wherever a final is counted ----------------
    fin = [ln for ln in src.splitlines() if 'METRICS["finals_total"] += 1' in ln]
    if len(fin) != 1:
        raise SystemExit(f"FAIL: expected exactly 1 finals_total increment, found {len(fin)}")
    line = fin[0]
    indent = line[: len(line) - len(line.lstrip())]
    src = src.replace(
        line + "\n",
        line + "\n" + indent + 'IDLE["last_xlate"] = _time.time()  # cost-guard activity signal\n',
        1,
    )

    # --- 3. replace the whole idle loop with the activity-based version ---
    lm = re.search(r'^async def _idle_stop_loop\(\):\n(?:.*\n)*?(?=^async def main\()', src, re.M)
    if not lm:
        raise SystemExit("FAIL: could not find _idle_stop_loop up to 'async def main('")
    src = src.replace(lm.group(0), NEW_LOOP, 1)
    return src


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    original = open(path).read()
    patched = patch(original)
    compile(patched, path, "exec")            # never write a file that won't parse
    for needle in ("idle_stop_decision", '"last_xlate"', "with no translation"):
        assert needle in patched, f"post-check failed: {needle} missing"
    if "--check" in sys.argv:
        print("would patch OK (no write)")
        return
    open(path + ".bak", "w").write(original)  # rollback copy next to the file
    open(path, "w").write(patched)
    print(f"patched {path} (backup at {path}.bak)")


if __name__ == "__main__":
    main()
