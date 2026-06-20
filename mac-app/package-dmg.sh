#!/usr/bin/env bash
# Build + bundle + package RealtimeTranslator.app into a distributable .dmg.
#
# Two flavors (the token is NEVER baked in — the user always types the password):
#
#   ./package-dmg.sh public
#       Public/open-source build. No server URL baked in (recipient enters their
#       own box URL), ad-hoc signed (no author identity embedded). Output:
#       RealtimeTranslator-public.dmg
#
#   RT_DEFAULT_SERVER_URL="wss://<your>.cloudfront.net" ./package-dmg.sh shared
#       For sharing with one trusted person who should use YOUR existing box.
#       Bakes in the relay URL only (still no token). Output:
#       RealtimeTranslator-shared.dmg
#
#   ./package-dmg.sh           # defaults to "public"
#
# Both are AD-HOC signed (no $99 Apple notarization), so first launch is via
# System Settings > Privacy & Security > "Open Anyway". See INSTALL.md.
set -euo pipefail
cd "$(dirname "$0")"

FLAVOR="${1:-public}"
APP="RealtimeTranslator.app"

case "$FLAVOR" in
  public)
    DMG="RealtimeTranslator-public.dmg"
    export RT_DEFAULT_SERVER_URL=""        # no URL baked in
    ;;
  shared)
    DMG="RealtimeTranslator-shared.dmg"
    if [ -z "${RT_DEFAULT_SERVER_URL:-}" ]; then
      echo "ERROR: 'shared' flavor needs RT_DEFAULT_SERVER_URL set, e.g.:"
      echo "  RT_DEFAULT_SERVER_URL=\"wss://xxxx.cloudfront.net\" ./package-dmg.sh shared"
      exit 1
    fi
    echo "==> shared build will bake in server URL: $RT_DEFAULT_SERVER_URL (token NOT baked)"
    ;;
  *)
    echo "Unknown flavor '$FLAVOR' (use: public | shared)"; exit 1 ;;
esac

# Always ad-hoc for distribution so the author's Apple ID isn't embedded.
export RT_ADHOC=1

# 1. build + sign the .app  (bundle.sh honors RT_DEFAULT_SERVER_URL + RT_ADHOC)
./bundle.sh release

# 2. (re)create the dmg
rm -f "$DMG"
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg not found — install with:  brew install create-dmg"; exit 1
fi
create-dmg \
  --volname "Realtime Translator" \
  --window-size 540 380 \
  --icon "$APP" 140 190 \
  --app-drop-link 400 190 \
  "$DMG" "$APP" || true   # create-dmg returns nonzero on cosmetic warnings

[ -f "$DMG" ] || { echo "DMG build failed"; exit 1; }
echo "==> built $DMG ($(du -h "$DMG" | cut -f1)), flavor=$FLAVOR"
echo "Distribute this file. First launch: System Settings > Privacy & Security >"
echo "Open Anyway, then grant Mic + Screen Recording (see INSTALL.md)."
