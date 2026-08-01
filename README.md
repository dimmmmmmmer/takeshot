# TakeShot

On-set capture and video assist for macOS. TakeShot records a camera feed
through a Blackmagic DeckLink or UltraStudio, splits it into takes
automatically as the camera rolls, names the files from your metadata, and
gives the operator the review tools a video assist needs — playback, compare,
scopes, exposure aids, markers and reports.

Built for DITs and video-assist operators who want the take-collecting of
Resolve Capture with the review layer of a proper assist station.

[![CI](https://github.com/dimmmmmmmer/takeshot/actions/workflows/ci.yml/badge.svg)](https://github.com/dimmmmmmmer/takeshot/actions/workflows/ci.yml)
[![Code quality](https://app.codacy.com/project/badge/Grade/5223b50b77af47e3a35f9d49b9b9c9e9)](https://app.codacy.com/gh/dimmmmmmmer/takeshot/dashboard)
[![Coverage](https://app.codacy.com/project/badge/Coverage/5223b50b77af47e3a35f9d49b9b9c9e9)](https://app.codacy.com/gh/dimmmmmmmer/takeshot/coverage/dashboard)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Download

Grab the latest DMG from [Releases](https://github.com/dimmmmmmmer/takeshot/releases)
and drag TakeShot to Applications.

Builds are ad-hoc signed, so the first launch needs a right-click → **Open**
instead of a double-click; macOS then remembers the choice.

## Features

### Recording

- Auto-takes from the camera's REC state — VANC trigger by default, running
  timecode or manual as alternatives.
- Pre-roll buffer: every take opens with picture *and* sound from before the
  REC press, so nothing is lost to trigger latency.
- 10-bit RGB capture for RGB 4:4:4 sources; ProRes Proxy/LT/422/HQ, H.264 and
  HEVC.
- Timecode track per take, with a second anchor written when the camera's
  Rec Run starts mid-take, so the overlap conforms frame-accurately against
  the camera original.
- LTC decode from an embedded audio channel when the camera sends no RP188.
- Multicam: every additional board records in sync on one REC press.
- Recording integrity: fragmented files (a crash cannot lose the take), takes
  closed on format change or signal loss, disk-space watch, sticky alarms for
  anything that threatens a recording.

### Review

- One render path for live, playback, stills and RAW — what you compare is
  what you recorded, pixel for pixel.
- BRAW and CinemaDNG playback; R3D is recognized (SDK integration pending).
- Compare against the live signal, a pinned reference frame, or another take,
  with wipe, blend and A/B.
- Waveform, RGB parade, histogram and vectorscope, as an overlay or in their
  own window.
- Viewing looks for preview and/or baked into the recording: `.cube` lattices,
  mirrored into the DaVinci Resolve LUT folder on import, and ASC CDL grades
  (`.cdl`, `.ccc`, `.cc`), which take the same path and keep their slope,
  offset, power and saturation for the selects EDL.

### Operator tools

- False color, EL Zone, zebra and focus peaking — stacking, with a legend.
- Framelines, safe areas, anamorphic desqueeze, punch-in with drag-to-pan.
- Hardware monitor output: the viewer mirrors to a DeckLink SDI/HDMI out.
- Markers with timecode while recording and while reviewing.
- Keyboard shortcuts for everything on the shot floor, all remappable.

### Handover

- Resolve-compatible metadata CSV, selects EDL from good takes with markers as
  locators and the active ASC CDL as `*ASC_SOP`/`*ASC_SAT`, an Avid log (ALE)
  of every take for a Media Composer bin, shift report as PDF and CSV.
- DIT offload of a camera card to several SSDs at once: the card is read once
  and written to every destination in the same pass, each copy is verified by
  re-reading it off the disk, and every destination gets a report — a picture
  to hand over and the same thing as plain text — beside the ASC MHL checksum
  list that post re-verifies it against. xxHash64, which is what Silverstack,
  OffShoot and Hedge check against. A destination that fails does so alone; the
  others finish. The sheet closes over a running copy (the takes panel keeps
  reporting it) and opens showing the last twenty offloads made from this Mac.

## Requirements

- macOS 14 (Sonoma) or newer, Apple Silicon or Intel.
- A Blackmagic capture device — DeckLink or UltraStudio — with
  [Desktop Video](https://www.blackmagicdesign.com/support/) installed.
- For `.braw` playback:
  [Blackmagic RAW](https://www.blackmagicdesign.com/products/blackmagicraw)
  (the free player installs the runtime TakeShot uses).

Without a capture device the app still opens and plays back existing footage;
a built-in demo signal covers everything else.

## Usage

1. Pick the capture device in Settings.
2. Set the project name, camera letter and roll; the clip number steps itself.
3. Roll the camera. TakeShot starts and stops takes with it, or use the REC
   button for manual takes.

Takes land in the destination folder with a Resolve-compatible CSV beside
them. Anything else that appears in that folder shows up under Other content,
so a card copied in by hand is one double-click from playback.

## Documentation

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — building from source, testing, and how
  to submit changes.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the app is put together
  and the hardware behaviour it depends on.

## License

MIT — see [LICENSE](LICENSE). The vendor SDKs TakeShot builds against are not
included here and stay under their own terms; [NOTICE](NOTICE) lists them.
