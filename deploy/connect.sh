#!/usr/bin/env bash
# Supervised, self-healing SSM port-forward so the Mac app can reach the relay
# at ws://localhost:18765 WITHOUT exposing any inbound port on the instance
# (per the no-public-exposure rule — SSM only, no security-group inbound).
#
#   deploy/connect.sh            # forward localhost:18765 -> instance:8765
#   deploy/connect.sh 19000      # use a different local port
#
# Leave this running while you use the app. The single point of failure for the
# app is the tunnel process dying (sleep/wake, idle timeout, credential expiry).
# This wrapper:
#   - starts the tunnel and waits for the local listener to actually answer
#   - watches localhost:<port> with a real TCP health check
#   - on a dead tunnel: kills the stale session-manager-plugin, frees the port,
#     and restarts with capped exponential backoff
#   - on an AUTH / credential failure: STOPS and tells you how to log in,
#     instead of crash-looping (per the no-silent-SSO-loop rule)
#   - Ctrl-C tears the child down cleanly
#
# bash 3.2 / zsh-invocable, macOS-only tooling (nc, lsof, pgrep/pkill).
set -uo pipefail
cd "$(dirname "$0")"

# ---- config ----------------------------------------------------------------
REGION="${REGION:-ap-northeast-1}"
IID="$(cat .instance-id)"
REMOTE_PORT="${REMOTE_PORT:-8765}"
LOCAL_PORT="${1:-18765}"

HEALTH_INTERVAL="${HEALTH_INTERVAL:-10}"   # seconds between watchdog probes
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-20}"   # seconds to wait for listener on (re)start
BACKOFF_START="${BACKOFF_START:-2}"        # initial restart backoff (s)
BACKOFF_MAX="${BACKOFF_MAX:-60}"           # backoff cap (s)
PROBE_TIMEOUT=2                            # per-probe TCP timeout (s)

# NB: under `set -u`, bash 3.2 (stock macOS) errors on expanding an EMPTY array.
# So every use below is guarded with the ${arr[@]+"${arr[@]}"} idiom.
PROFILE_ARGS=()
[ -n "${AWS_PROFILE:-}" ] && PROFILE_ARGS=(--profile "$AWS_PROFILE")

LOG_PREFIX="[ssm-tunnel]"
log()  { printf '%s %s %s\n' "$(date '+%H:%M:%S')" "$LOG_PREFIX" "$*" >&2; }
fail() { printf '%s %s ERROR: %s\n' "$(date '+%H:%M:%S')" "$LOG_PREFIX" "$*" >&2; }

# ---- health probe ----------------------------------------------------------
# Returns 0 if something is accepting TCP on localhost:LOCAL_PORT.
# This proves the plugin's local listener is up; the Mac app's own WebSocket
# reconnect then handles the app<->relay handshake. We deliberately do NOT send
# WebSocket bytes here — a bare TCP accept is the right liveness signal for the
# forwarder, and the app re-handshakes on its own when the tunnel returns.
port_alive() {
  if nc -z -G "$PROBE_TIMEOUT" -w "$PROBE_TIMEOUT" 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
    return 0
  fi
  # Pure-bash fallback if nc flags ever differ across macOS builds.
  /bin/bash -c "exec 3<>/dev/tcp/127.0.0.1/$LOCAL_PORT" >/dev/null 2>&1
}

# ---- auth check ------------------------------------------------------------
# Cheap, non-mutating credential probe. On failure we STOP (do not loop):
# auth/SSO remediation is interactive and must be surfaced to the user.
auth_ok() {
  aws sts get-caller-identity ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --region "$REGION" >/dev/null 2>&1
}

# Print the right login hint for whatever auth this profile uses, then exit 1.
abort_on_auth() {
  local err
  err="$(aws sts get-caller-identity ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --region "$REGION" 2>&1 || true)"
  fail "AWS credentials are missing or expired — refusing to crash-loop."
  printf '\n  %s\n\n' "$err" >&2
  if printf '%s' "$err" | grep -qiE 'sso|token.*expired|getRoleCredentials'; then
    fail "This looks like an SSO session. Re-authenticate, then re-run this script:"
    if [ -n "${AWS_PROFILE:-}" ]; then
      printf '      aws sso login --profile %s\n' "$AWS_PROFILE" >&2
    else
      printf '      aws sso login        # (or: aws sso login --profile <your-profile>)\n' >&2
    fi
  else
    fail "Fix your AWS credentials (expired/invalid), then re-run this script. e.g.:"
    printf '      aws configure                 # static keys\n' >&2
    printf '      aws sso login [--profile X]   # SSO\n' >&2
    [ -n "${AWS_PROFILE:-}" ] && printf '      (current AWS_PROFILE=%s)\n' "$AWS_PROFILE" >&2
  fi
  exit 1
}

# ---- cleanup: free our local port before each (re)start --------------------
# Kills any session-manager-plugin holding THIS local port (orphaned by a hard
# parent kill / sleep), then any remaining listener on the port. Scoped to our
# port so concurrent tunnels on other ports are untouched.
cleanup_port() {
  pkill -f "session-manager-plugin.*localPortNumber.*$LOCAL_PORT" >/dev/null 2>&1 || true
  local pids
  pids="$(lsof -ti tcp:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    log "freeing local port $LOCAL_PORT (pids: $(echo $pids | tr '\n' ' '))"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 1
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
  fi
}

# ---- graceful shutdown -----------------------------------------------------
SSM_PID=""
shutdown() {
  log "shutting down"
  [ -n "$SSM_PID" ] && kill "$SSM_PID" 2>/dev/null || true
  cleanup_port
  exit 0
}
trap shutdown INT TERM

# ---- preflight -------------------------------------------------------------
[ -n "$IID" ] || { fail "no instance id in $(pwd)/.instance-id"; exit 1; }
command -v aws >/dev/null 2>&1 || { fail "aws CLI not found on PATH"; exit 1; }
command -v session-manager-plugin >/dev/null 2>&1 || {
  fail "session-manager-plugin not found — install it:"
  printf '      https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html\n' >&2
  exit 1
}

log "target=$IID region=$REGION  forward ws://localhost:$LOCAL_PORT -> :$REMOTE_PORT"
log "In the Mac app, set server = ws://localhost:$LOCAL_PORT   (Ctrl-C to stop)"

backoff="$BACKOFF_START"

# ---- supervised loop -------------------------------------------------------
while true; do
  # Gate every iteration on valid creds; STOP (don't loop) on auth failure.
  auth_ok || abort_on_auth

  cleanup_port

  log "starting tunnel..."
  aws ssm start-session ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} --region "$REGION" --target "$IID" \
    --document-name AWS-StartPortForwardingSession \
    --parameters "{\"portNumber\":[\"$REMOTE_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
    >"/tmp/rt-ssm-tunnel.$LOCAL_PORT.log" 2>&1 &
  SSM_PID=$!

  # Wait for the listener to actually answer before declaring success.
  up=false
  i=0
  while [ "$i" -lt "$STARTUP_TIMEOUT" ]; do
    if ! kill -0 "$SSM_PID" 2>/dev/null; then
      break                       # aws exited during startup
    fi
    if port_alive; then up=true; break; fi
    sleep 1
    i=$((i + 1))
  done

  if [ "$up" = true ]; then
    log "tunnel UP (pid $SSM_PID)"
    backoff="$BACKOFF_START"       # reset ONLY after a confirmed-healthy start

    # Watchdog: healthy while the aws process lives AND the port answers.
    while kill -0 "$SSM_PID" 2>/dev/null; do
      if ! port_alive; then
        log "health check FAILED on localhost:$LOCAL_PORT — recycling tunnel"
        kill "$SSM_PID" 2>/dev/null || true
        break
      fi
      sleep "$HEALTH_INTERVAL"
    done
    wait "$SSM_PID" 2>/dev/null || true
    log "tunnel exited"
  else
    fail "tunnel failed to come up within ${STARTUP_TIMEOUT}s (see /tmp/rt-ssm-tunnel.$LOCAL_PORT.log)"
    kill "$SSM_PID" 2>/dev/null || true
    wait "$SSM_PID" 2>/dev/null || true
    # A fast failure to come up is often an auth problem the API surfaced after
    # we passed the cheap sts check, or a transient. Re-check creds explicitly:
    auth_ok || abort_on_auth
  fi

  SSM_PID=""
  cleanup_port

  log "restarting in ${backoff}s"
  sleep "$backoff"
  if [ "$((backoff * 2))" -gt "$BACKOFF_MAX" ]; then
    backoff="$BACKOFF_MAX"
  else
    backoff="$((backoff * 2))"
  fi
done
