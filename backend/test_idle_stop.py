"""Offline checks for the idle cost guard (no deps, no network).

Run: python3 backend/test_idle_stop.py

Why this exists: the guard decides whether to shut down a ~$2.2/h GPU box.
Too lazy and it bills forever (the bug this replaced); too eager and it kills a
live meeting. Both failure modes are silent, so they get a test.
"""
import ast
import pathlib

# Load ONLY the pure decision function out of server.py, so this test needs
# none of the relay's runtime deps (websockets, faster-whisper, ...).
_src = pathlib.Path(__file__).with_name("server.py").read_text()
_fn = next(n for n in ast.parse(_src).body
           if isinstance(n, ast.FunctionDef) and n.name == "idle_stop_decision")
_ns: dict = {}
exec(compile(ast.Module(body=[_fn], type_ignores=[]), "server.py", "exec"), _ns)
decide = _ns["idle_stop_decision"]

H = 3600.0
LIMIT = 4 * H          # the deployed window: 4h with no translation
GRACE = 600.0          # RT_IDLE_GRACE_S default


def case(name, *, quiet_s, enabled=True, up_s=GRACE + 1, inflight=0, waiting=0):
    """Evaluate the guard `quiet_s` after the last translation."""
    now = 1_000_000.0
    stop, reset = decide(now, now - quiet_s, enabled, LIMIT,
                         now - up_s, GRACE, inflight, waiting)
    return name, stop, reset


def main():
    # --- must NOT stop -----------------------------------------------------
    for name, stop, _ in [
        case("just translated", quiet_s=5),
        case("quiet 3h59m (under the limit)", quiet_s=LIMIT - 60),
        case("disarmed, quiet for a week", quiet_s=7 * 24 * H, enabled=False),
        case("still inside boot grace", quiet_s=10 * H, up_s=GRACE - 1),
        case("transcription in flight", quiet_s=10 * H, inflight=1),
        case("transcription queued", quiet_s=10 * H, waiting=2),
    ]:
        assert stop is False, f"MUST NOT STOP but did: {name}"
        print(f"  ok  keeps running: {name}")

    # --- must stop ---------------------------------------------------------
    for name, stop, _ in [
        case("quiet exactly 4h", quiet_s=LIMIT),
        case("quiet 6h (app left connected but silent)", quiet_s=6 * H),
        case("quiet overnight", quiet_s=14 * H),
    ]:
        assert stop is True, f"MUST STOP but did not: {name}"
        print(f"  ok  self-stops:    {name}")

    # --- the activity clock must be reset while disarmed/grace/busy --------
    # Otherwise re-arming after a long quiet spell would stop the box instantly.
    for name, _, reset in [
        case("disarmed resets clock", quiet_s=10 * H, enabled=False),
        case("grace resets clock", quiet_s=10 * H, up_s=GRACE - 1),
        case("busy resets clock", quiet_s=10 * H, inflight=1),
    ]:
        assert reset is True, f"MUST reset activity clock: {name}"
        print(f"  ok  resets clock:  {name}")

    # A plain quiet tick must NOT reset the clock, or idle time never accrues.
    _, _, reset = case("quiet tick keeps banking idle time", quiet_s=60)
    assert reset is False, "a quiet tick must not reset the activity clock"
    print("  ok  quiet tick keeps banking idle time")

    print("\nall idle-stop checks passed")


if __name__ == "__main__":
    main()
