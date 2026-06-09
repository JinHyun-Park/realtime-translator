#!/usr/bin/env bash
# Build + bundle + package RealtimeTranslator.app into a distributable .dmg.
# This is an AD-HOC signed build (no $99 Apple notarization) — teammates open it
# the first time via System Settings ▸ Privacy & Security ▸ "Open Anyway"
# (verified working on Amazon-MDM Macs). See TEAM_DEPLOY.md for the user steps.
set -euo pipefail
cd "$(dirname "$0")"

APP="RealtimeTranslator.app"
DMG="RealtimeTranslator.dmg"

# 1. build + sign the .app (bundle.sh signs with whatever identity is available)
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
echo "==> built $DMG ($(du -h "$DMG" | cut -f1))"
echo "Distribute this file. Teammates: see TEAM_DEPLOY.md (first-launch is via"
echo "System Settings ▸ Privacy & Security ▸ Open Anyway, then grant Mic + Screen Recording)."
