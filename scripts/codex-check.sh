#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

phase() { printf '\n==> %s\n' "$1"; }

PYTHON="${RT_CHECK_PYTHON:-}"
if [ -z "$PYTHON" ]; then
  if [ -x backend/.venv/bin/python ]; then
    PYTHON=backend/.venv/bin/python
  else
    PYTHON=python3
  fi
fi
PYTHON="$(command -v "$PYTHON")" || {
  printf 'Python interpreter not found: %s\n' "${RT_CHECK_PYTHON:-python3}" >&2
  exit 1
}
case "$PYTHON" in
  /*) ;;
  *) PYTHON="$ROOT/$PYTHON" ;;
esac

phase "Python syntax"
git ls-files -z '*.py' | xargs -0 "$PYTHON" -m py_compile

phase "Backend endpointing behavior"
if "$PYTHON" -c 'import webrtcvad' >/dev/null 2>&1; then
  # This legacy test predates the separate incomplete-sentence hold feature.
  (cd backend && RT_INCOMPLETE_HOLD=1 "$PYTHON" test_en_gate.py)
else
  printf 'SKIP: %s does not provide webrtcvad\n' "$PYTHON"
fi

phase "Shell syntax"
bash -n "$0"
while IFS= read -r script; do
  bash -n "$script"
done < <(git ls-files '*.sh')

phase "Swift build"
swift build --package-path mac-app

printf '\nAll available checks passed.\n'
