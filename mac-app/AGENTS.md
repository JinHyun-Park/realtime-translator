# macOS App Agent Guide

## Structure

- `AppModel.swift`: `@MainActor` application state, capture lifecycle, wake and
  health polling, transcript persistence, controls, and insight requests.
- `Audio/`: microphone and ScreenCaptureKit capture, resampling, device
  observation, and echo suppression.
- `Net/RelayClient.swift`: reconnecting WebSocket client and relay protocol.
- `Views/`: SwiftUI controls and transcript presentation.
- `Localization.swift`: Korean, Japanese, and English UI strings.

The app opens separate relay connections for microphone (`me`) and system audio
(`them`). Keep those streams separate through capture and transport.

## Constraints

- `AppModel` state updates belong on the main actor.
- AVAudioEngine setup can block through CoreAudio. Keep microphone engine work
  off the main thread as the existing lifecycle does.
- ScreenCaptureKit can stop producing frames without an error. Preserve the
  flow watchdog and recovery path when changing system capture.
- RelayClient reconnects and re-sends the active language pair after `ready`.
- New visible strings must have `ko`, `ja`, and `en` entries.
- Preserve the `// RT_DEFAULT_SERVER_URL`, `// RT_VERSION`, and
  `// RT_BUILD_DATE` marker lines. `bundle.sh` rewrites and restores them.
- Do not bake access tokens into source, app bundles, or DMGs.

## Build And Permissions

Fast compile check:

```bash
swift build --package-path mac-app
```

Runnable app bundle:

```bash
cd mac-app
./bundle.sh
```

The bundle step and stable signing identity matter for Microphone and Screen
Recording grants. A plain Swift build proves compilation but not capture,
permissions, signing, wake behavior, or live audio flow. Verify those manually
when a change touches them and inspect `/tmp/rt-app.log` for runtime diagnostics.
