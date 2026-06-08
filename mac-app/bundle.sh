#!/usr/bin/env bash
# Builds the SwiftPM binary and wraps it into a proper RealtimeTranslator.app
# bundle. A bundle (with Info.plist usage strings + code signature) is REQUIRED
# for macOS to grant Microphone and Screen Recording (system audio) permissions.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="RealtimeTranslator.app"
BUNDLE_ID="dev.hjeongho.realtimetranslator"

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
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
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

# Ad-hoc sign so TCC can attach a stable identity to the permission grant.
echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - \
  --options runtime \
  "$APP" >/dev/null 2>&1 || codesign --force --deep --sign - "$APP"

echo "==> done: $APP"
echo "Launch with:  open $APP    (or ./$APP/Contents/MacOS/RealtimeTranslator for logs)"
