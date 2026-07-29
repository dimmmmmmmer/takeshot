# TakeShot

On-set capture and video-assist tool for macOS: records a camera feed through a
Blackmagic DeckLink/UltraStudio, auto-splits it into takes by the camera's REC
state (running RP188 timecode + VANC triggers), names files from metadata, and
gives the operator a review layer on top — playback, compare, scopes, exposure
assists, markers, exports, hardware monitor output.

`ROADMAP.md` carries the feature status and everything still open.

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
  - `scripts/lint.sh` — SwiftLint (`brew install swiftlint` first). The script
    exists because SourceKitten looks for sourcekitd inside a toolchain
    directory, and the Command Line Tools have no `Toolchains` folder — it
    points `TOOLCHAIN_DIR` at the CLT root. CI runs it with `--strict`.

Two test targets: `CaptureCoreTests` (core logic, synthetic signals) and
`TakeShotKitTests` (the session driven end to end through the mock backend, no
hardware and no window). Keep the build at zero warnings — it is a
zero-warning build today, and warnings are how the concurrency bugs announced
themselves.

## DeckLink SDK

The SDK headers are not committed. Drop them into `vendor/DeckLinkSDK/include/`
(see `vendor/DeckLinkSDK/README.md`). Without them `CDeckLink` builds as a stub
(`CDLDeviceManager.isSDKAvailable == false`); with them it's the real bridge
(`DeckLinkAPIDispatch.cpp` is included directly in `CDeckLink.mm`, so no
framework linking is needed; the runtime is
`/Library/Frameworks/DeckLinkAPI.framework` from Blackmagic Desktop Video).

## Blackmagic RAW SDK

Same pattern for `CBraw` (BRAW playback): headers go in
`vendor/BRAWSDK/include/` (see `vendor/BRAWSDK/README.md`); without them the
target is a stub (`CBRClip.isSDKAvailable == NO`). The runtime
BlackmagicRawAPI.framework is loaded dynamically — app bundle Frameworks/
first, then the Blackmagic RAW install location under /Applications.

## Preview display rule

A CALayer can be hosted by ONE NSView. Every preview mount registers its own
`MetalPreviewLayer` as a sink (`CapturePipeline.addDisplaySink`,
`PlaybackFrameTap.addSink`, `RawPlayerModel.addSink`); never share a layer
between views. The main viewer is a single `ViewerSurface` whose frame source
is re-routed between live/playback/RAW — do not mount separate per-mode
surfaces there (independent letterbox rounding shifts the image by a pixel).

## Architecture

- `Sources/CaptureCore` (**Swift 6 language mode**) — SDK-free core: `Timecode`
  (drop-frame math, `dayFrames` for midnight wrap), `RecDetector` (REC/IDLE
  state machine), `LTCDecoder` (SMPTE 12M biphase decode from PCM),
  `NamingEngine`, `TakeWriter` (AVAssetWriter: video + audio + a possibly
  multi-sample timecode track, one file = one take), `CapturePipeline` (the
  per-frame path; `+Take`, `+Preview`, `+Audio` extensions), `TenBitConverter`,
  `MetalPreviewLayer` + `PreviewSinkRegistry`, `ScopeAnalyzer`,
  `CompareCompositor`, `CubeLUT`, the exporters, and the `CaptureBackend`
  protocol (abstraction for a future AJA backend). `Sendability.swift` states
  the cross-thread contracts in one place instead of boxing at call sites.
- `Sources/CDeckLink` — Obj-C++ bridge to the DeckLink SDK: `CDLCapture`
  (input) and `CDLPlayout` (hardware monitor output), pure Obj-C surface.
- `Sources/CBraw` — Obj-C++ bridge to the Blackmagic RAW SDK (`CBRClip`).
- `Sources/TakeShotKit` — the application layer as a **library** (SwiftPM can't
  import an executable from tests, so this used to be untestable):
  `CaptureController` plus its domain extensions (`+Capture`, `+Playback`,
  `+Compare`, `+LUT`, `+Markers`, `+Library`, `+Offload`, `+Windows`), the two
  playback engines (`PlaybackFrameTap` for AVPlayer video and stills,
  `RawPlayerModel` for BRAW/CinemaDNG), `PlayoutFeeder`, and the SwiftUI views.
- `Sources/TakeShot` — the executable entry point and nothing else.

Backend callbacks arrive on a background thread and are hopped onto the
MainActor. Queues that must not be blocked: the capture queue owns per-frame
work; presentation, scope analysis and playout each run on their own queue with
latest-wins coalescing. Anything doing GPU work or file I/O belongs off the
capture queue — UI-triggered redraws included (`nextDrawable()` parks up to a
second on an occluded window).

Keep types from growing back into god objects: `CaptureController` and
`CapturePipeline` were 2615 and 1315 lines before the split; new behaviour goes
into the matching domain extension.

## Color pipeline

RGB 4:4:4 sources are captured as 10-bit `r210` by default. `TenBitConverter`
splits each wire frame in one pass into a full-range 8-bit BGRA **display**
buffer (preview/LUT/scopes/grabs) and a **record** r210 buffer precompensated
for VideoToolbox's measured convention — it treats r210 content as video-range
64–960 and expands it inside the codec. Measured result: decoded files return
to intended values within ±1 in 10-bit units, unbiased; the old 8-bit BGRA path
carried a systematic +0.4-code lift that steep viewing LUTs amplified into a
visible rec/playback mismatch.

## Recording integrity (do not regress)

- `movieFragmentInterval` is set — a crash or power loss mid-take must not lose
  the whole file.
- A mid-take input format change, a signal loss, or a dead writer closes the
  take with a **sticky** alarm (the writer returning false is ambiguous between
  "busy encoder" and "volume detached"; `TakeWriter.hasFailed` disambiguates).
- A take joins the list only after a successful finalize; a failed finalize is
  renamed `*_FAILED.mov` rather than re-adopted by the folder scan.
- The audio channel mask is latched per take; pre-roll carries audio as well as
  picture; dropped video, audio and pre-roll frames are all counted and shown.
- Free space is watched: a warning under 5 GB, the take is closed under 0.5 GB.

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
(`Sources/TakeShotKit/L10n.swift`), with files
`Sources/TakeShotKit/Resources/{en,ru}.lproj/Localizable.strings`. The language
switches live in Settings (swapping the .lproj bundle); the choice is stored in
`CaptureSettings.appLanguage` (nil = system; make new settings fields Optional —
otherwise old saved JSON won't decode). Core errors (CaptureCore/CDeckLink) are
English, not localized. Add new strings to both .strings files; don't leave
hard-coded strings in views.

## Hard-won facts (do not relearn these)

Each of these cost a session on real hardware; the code comments at the sites
carry the detail.

- **Format-detection restart loop**: restarting streams from the format
  callback re-arms detection and loops forever — stream time stays pinned at 0,
  every frame gets PTS 0, takes come out 0 bytes. Guard on an actual
  mode/pixel-format change.
- **Input levels state the SOURCE's range**: limited (16–235 / 64–940) is
  expanded ONCE on gamma-encoded values (a CI matrix in linear space crushes
  shadows); full passes through untouched. Auto assumes limited for RGB 4:4:4
  HDMI (CTA-861 default).
- **Never tag writer-bound buffers with a non-standard transfer**: the encoder
  color-converts on tag mismatch, and CVBuffer attachments leak between buffers
  sharing an IOSurface (both measured on device).
- **`AVSampleBufferDisplayLayer` is off-limits for the viewer**: composited
  (rounded corners, overlays) it shows video-range codes unexpanded — washed
  blacks that no pixel format or tagging fixes.
- **Detection default is VANC-only**: running timecode alone (a Resolve playout
  feeding the board) must never start a take.
- **Stills are deliverables, not screenshots**: grabs never bake the preview
  LUT, and stills in the player go through the same tap render as video —
  SwiftUI `Image` is color-managed differently and never matched.
- **Ad-hoc signing changes the cdhash on every rebuild**, so TCC grants die and
  the app hangs at first launch; launching the binary directly from the shell
  is the workaround until a stable signing identity exists.

## Status

Build clean, zero warnings, 93 tests green. `CaptureCore` is on Swift 6;
`TakeShotKit` is still Swift 5 (see `Package.swift`). Feature status and open
work live in `ROADMAP.md`.
