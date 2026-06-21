#!/usr/bin/env bash
# Builds the SwiftPM binary and wraps it into a proper RealtimeTranslator.app
# bundle. A bundle (with Info.plist usage strings + code signature) is REQUIRED
# for macOS to grant Microphone and Screen Recording (system audio) permissions.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="RealtimeTranslator.app"
BUNDLE_ID="dev.hjeongho.realtimetranslator"
ENTITLEMENTS="RealtimeTranslator.entitlements"
CONFIG_SWIFT="Sources/RealtimeTranslator/AppModel.swift"

# Optionally bake a default relay URL into this build (the marker line in
# AppModel.swift). Used for a build shared with one trusted person who should
# use an existing box. NEVER bakes the token. Empty (default) => no URL baked
# in, which is correct for a public distributable. We restore the file after.
# Version + build date are ALWAYS stamped into AppConfig (from the VERSION file
# and today's date). RT_DEFAULT_SERVER_URL is baked in only when set. All are
# marker-line rewrites; we restore the source file afterwards (trap).
RT_VERSION="$(cat VERSION 2>/dev/null | head -1 | tr -d '[:space:]')"
RT_VERSION="${RT_VERSION:-dev}"
RT_BUILD_DATE="$(date +%Y-%m-%d)"
RESTORE_CONFIG=""
cleanup() { [ -n "$RESTORE_CONFIG" ] && mv "$RESTORE_CONFIG" "$CONFIG_SWIFT" || true; }
trap cleanup EXIT
echo "==> stamping version=$RT_VERSION build=$RT_BUILD_DATE${RT_DEFAULT_SERVER_URL:+, baking server URL=$RT_DEFAULT_SERVER_URL}"
RESTORE_CONFIG="$(mktemp)"
cp "$CONFIG_SWIFT" "$RESTORE_CONFIG"
# Rewrite each marked AppConfig line (trailing tag makes it unambiguous/idempotent).
RT_DEFAULT_SERVER_URL="${RT_DEFAULT_SERVER_URL:-}" \
RT_VERSION="$RT_VERSION" RT_BUILD_DATE="$RT_BUILD_DATE" \
python3 - "$CONFIG_SWIFT" <<'PY'
import os, sys
path = sys.argv[1]
subs = {
    "// RT_DEFAULT_SERVER_URL": ("defaultServerURL", os.environ.get("RT_DEFAULT_SERVER_URL", "")),
    "// RT_VERSION":            ("version",          os.environ.get("RT_VERSION", "dev")),
    "// RT_BUILD_DATE":         ("buildDate",        os.environ.get("RT_BUILD_DATE", "")),
}
out = []
for line in open(path).read().splitlines(keepends=True):
    rewrote = False
    for tag, (name, val) in subs.items():
        if line.rstrip().endswith(tag):
            indent = line[:len(line) - len(line.lstrip())]
            esc = val.replace("\\", "\\\\").replace('"', '\\"')
            out.append(f'{indent}static let {name} = "{esc}"  {tag}\n')
            rewrote = True
            break
    if not rewrote:
        out.append(line)
open(path, "w").write("".join(out))
PY

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/RealtimeTranslator"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RealtimeTranslator"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>RealtimeTranslator</string>
  <key>CFBundleDisplayName</key><string>Realtime Translator</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>${RT_BUILD_DATE}</string>
  <key>CFBundleShortVersionString</key><string>${RT_VERSION#v}</string>
  <key>CFBundleExecutable</key><string>RealtimeTranslator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Captures microphone audio to transcribe and translate speech in real time.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Captures system audio (what you hear) to translate it in real time.</string>
</dict>
</plist>
PLIST

# Sign with a STABLE identity so the code-signing hash (cdhash) stays constant
# across rebuilds — otherwise macOS TCC treats every rebuild as a new app and
# Screen Recording / Microphone grants silently stop matching.
#
# Prefer a real signing identity (Apple Development cert, or one named via
# RT_SIGN_IDENTITY). Fall back to ad-hoc only if none exists (which reintroduces
# the per-build permission reset — avoid for Screen Recording).
#
# RT_ADHOC=1 FORCES ad-hoc signing even when a cert exists — used for a PUBLIC
# distributable .dmg so the author's Apple ID / TeamID isn't embedded in a build
# that strangers download. (Recipients get the same Gatekeeper prompt either
# way, since the author's cert isn't trusted on their Macs anyway.)
SIGN_ID="${RT_SIGN_IDENTITY:-}"
if [ "${RT_ADHOC:-0}" = "1" ]; then
  SIGN_ID=""
  echo "==> RT_ADHOC=1 — forcing ad-hoc signature (no personal identity embedded)"
elif [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')
fi

# Hardened runtime (--options runtime) is KEPT on purpose: the mic entitlement
# com.apple.security.device.audio-input is only meaningful under hardened runtime,
# and it matches how the Apple Development identity signs by default. Under
# hardened runtime, the mic is SILENTLY denied unless this entitlement is present,
# so --entitlements is mandatory. (Screen Recording / system audio via
# ScreenCaptureKit needs NO entitlement — it is a pure TCC user grant.)
if [ -n "$SIGN_ID" ]; then
  echo "==> codesign with: $SIGN_ID"
  codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    --sign "$SIGN_ID" "$APP"
else
  echo "==> codesign (ad-hoc — WARNING: Screen Recording permission will reset each build)"
  codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - "$APP"
fi

# Show the resulting identity + cdhash so we can confirm it's stable.
codesign -dvv "$APP" 2>&1 | grep -E "Authority|CDHash|Identifier|flags" | head -5
# Confirm hardened runtime is on AND the mic entitlement actually landed.
echo "==> entitlements:"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -o "com.apple.security.device.audio-input" || echo "  !! audio-input entitlement MISSING"

echo "==> done: $APP"
echo "Launch with:  open $APP    (or ./$APP/Contents/MacOS/RealtimeTranslator for logs)"
