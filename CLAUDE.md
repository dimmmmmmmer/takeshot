# TakeShot

On-set ingest assistant for macOS: captures a camera feed through a Blackmagic
DeckLink/UltraStudio, auto-splits it into takes by the camera's REC state
(running RP188 timecode + VANC triggers), and names files from metadata. A take
collector in the spirit of Resolve Capture / Media Express.

Project language: **all documentation, README files, and code comments are in
English.** UI strings are localized (see i18n below).

## Build and test

- Xcode is not installed — only the Command Line Tools. Everything runs through
  SwiftPM:
  - `swift build` — build
  - `scripts/test.sh` — core tests (Swift Testing; a bare `swift test` on CLT
    can't find Testing.framework — the script adds the needed -F/-rpath, and it
    degrades to a plain `swift test` when Xcode is present)
  - `swift run takeshot-devices` — CLI smoke test: list DeckLink devices
  - `scripts/bundle-app.sh` — build `build/TakeShot.app` (release + ad-hoc sign)

## DeckLink SDK

The SDK headers are not committed. Drop them into `vendor/DeckLinkSDK/include/`
(see `vendor/DeckLinkSDK/README.md`). Without them `CDeckLink` builds as a stub
(`CDLDeviceManager.isSDKAvailable == false`); with them it's the real bridge
(`DeckLinkAPIDispatch.cpp` is included directly in `CDeckLink.mm`, so no
framework linking is needed; the runtime is
`/Library/Frameworks/DeckLinkAPI.framework` from Blackmagic Desktop Video).

## Architecture

- `Sources/CaptureCore` — SDK-free core: `Timecode` (including drop-frame math),
  `RecDetector` (REC/IDLE state machine from TC-run and VANC triggers),
  `NamingEngine` (name templates), `TakeWriter` (AVAssetWriter: video + audio +
  timecode track, one file = one take), the `CaptureBackend` protocol
  (abstraction for a future AJA backend).
- `Sources/CDeckLink` — Obj-C++ bridge to the DeckLink SDK (C-family target,
  pure Obj-C surface).
- `Sources/TakeShot` — SwiftUI app; `CaptureController` is the single point that
  ties backend/detector/writer together; backend callbacks arrive on a
  background thread and are hopped onto the MainActor.

All take-detection logic is tested against synthetic TC sequences — run
`swift test` after any change to `RecDetector`/`Timecode`.

## Demo source

`MockCaptureBackend` is hidden from the production UI: it appears in the device
list only when launched via `TakeShot --demo` (or env `TAKESHOT_DEMO=1`). It
generates a 1080p25 signal with Rec Run timecode; the "REC demo camera" button
is visible when the demo source is selected. This is how the GUI and take logic
are exercised end-to-end without a board.

## UI layout (per the user's brief)

The device is chosen in Settings (not in the main window). Above the player: TC
on the left, resolution + fps on the right. Below the player: a large red REC
button dead center; bottom-left — settings/VANC monitor/folder picker (like
Resolve); right — Prefix (=projectName)/Cam/Roll/Clip fields. Changing the roll
resets the clip number. The title bar is hidden (.hiddenTitleBar). Theme
(light/dark/system) and the player background color live in Settings. Takes
panel: an "open folder" button and an Other content block (foreign video files
in the record folder, polled every 5 s). The CSV uses a Reel Name column
(=roll).

## CI

Codacy: static analysis (connected on codacy.com) + coverage
(`codacy-coverage.yml` uploads lcov; the token lives in the CODACY_PROJECT_TOKEN
secret and is never committed).

GitHub Actions (`.github/workflows/`): `ci.yml` — build + tests + a TakeShot.zip
artifact on every push/PR; `release.yml` — on a `v*` tag it builds the .app and
publishes a GitHub Release (.dmg with a symlink to /Applications). Ad-hoc
signing: open downloaded builds via right-click → Open (Gatekeeper).

## i18n

The base language is English. UI strings go through `L("key")`
(`Sources/TakeShot/L10n.swift`), with files
`Sources/TakeShot/Resources/{en,ru}.lproj/Localizable.strings`. The language
switches live in Settings (swapping the .lproj bundle); the choice is stored in
`CaptureSettings.appLanguage` (nil = system; make new settings fields Optional —
otherwise old saved JSON won't decode). Core errors (CaptureCore/CDeckLink) are
English, not localized. Add new strings to both .strings files; don't leave
hard-coded strings in views.

## Milestone status (MVP plan)

1. ✅ Scaffold + core (detector, naming, writer, UI skeleton, tests)
2. ✅ Capture in `CDeckLink`: input, format auto-detection, frames
   (IDeckLinkVideoBuffer), RP188 timecode, 48k/16-bit audio → callbacks.
   **Not verified on a live board.**
3. ✅ Preview (`AVSampleBufferDisplayLayer`), the `CapturePipeline` on a serial
   queue, manual recording, demo source
4. ✅ Auto-takes + pre-roll buffer (frames from the camera's actual start +
   configurable lead seconds; covered by synthetic e2e tests). **Needs a board
   check.**
5. ⏳ VANC metadata (Blackmagic: tally DID 0x51/SDID 0x52, camera control
   0x51/0x53), names from the camera's reel/scene/take
