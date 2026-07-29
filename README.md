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

## Features

**Recording**

- Auto-takes from the camera's REC state — VANC trigger by default, running
  timecode or manual as alternatives.
- Pre-roll buffer: every take opens with picture *and* sound from before the
  REC press, so nothing is lost to trigger latency.
- 10-bit RGB capture (`r210`) for RGB 4:4:4 sources; ProRes Proxy/LT/422/HQ,
  H.264 and HEVC.
- Timecode track per take, with a second anchor written when the camera's
  Rec Run starts mid-take, so the overlap conforms frame-accurately against
  the camera original.
- LTC decode from an embedded audio channel when the camera sends no RP188.
- Multicam: every additional board records in sync on one REC press.
- Recording integrity: fragmented files (a crash cannot lose the take), takes
  closed on format change or signal loss, disk-space watch, sticky alarms for
  anything that threatens a recording.

**Review**

- One render path for live, playback, stills and RAW — what you compare is
  what you recorded, pixel for pixel.
- BRAW and CinemaDNG playback; R3D is recognized (SDK integration pending).
- Compare against the live signal, a pinned reference frame, or another take,
  with wipe, blend and A/B.
- Waveform, RGB parade, histogram and vectorscope, as an overlay or in their
  own window.
- Viewing LUTs (.cube) for preview and/or baked into the recording, mirrored
  into the DaVinci Resolve LUT folder on import.

**Operator tools**

- False color, EL Zone, zebra and focus peaking — stacking, with a legend.
- Framelines, safe areas, anamorphic desqueeze, punch-in with drag-to-pan.
- Hardware monitor output: the viewer mirrors to a DeckLink SDI/HDMI out.
- Markers with timecode while recording and while reviewing.

**Handover**

- Resolve-compatible metadata CSV, selects EDL from good takes with markers as
  locators, shift report as PDF and CSV.
- Verified offload of a camera card: recursive copy with SHA-256 on both sides
  and a manifest.

## Requirements

- macOS 14 or newer.
- Xcode Command Line Tools (Xcode itself is not required).
- A Blackmagic capture device plus
  [Desktop Video](https://www.blackmagicdesign.com/support/) for hardware
  capture. Without one, the app runs against a built-in demo source.

## Build

```bash
git clone https://github.com/dimmmmmmmer/takeshot.git
cd takeshot
swift build
scripts/bundle-app.sh          # produces build/TakeShot.app
```

`scripts/test.sh` runs the test suites (Swift Testing; the script adds the
framework search paths that a bare `swift test` misses on the Command Line
Tools).

### SDKs

Neither SDK is redistributable, so neither is committed. Both targets build as
stubs without them, and the app runs — it just cannot open the corresponding
hardware or files.

| SDK | Headers go in | Without it |
| --- | --- | --- |
| [DeckLink](https://www.blackmagicdesign.com/developer/) | `vendor/DeckLinkSDK/include/` | no capture devices, demo source only |
| [Blackmagic RAW](https://www.blackmagicdesign.com/developer/) | `vendor/BRAWSDK/include/` | `.braw` files do not open |

Both runtimes are loaded dynamically at launch — no framework linking, so a
build made without the SDKs still runs on a machine that has them.

## Usage

1. Pick the capture device in Settings.
2. Set the project name, camera letter and roll; the clip number steps itself.
3. Roll the camera. TakeShot starts and stops takes with it, or use the REC
   button for manual takes.

Takes land in the destination folder with a Resolve-compatible CSV beside
them. Anything else that appears in that folder shows up under Other content,
so a card copied in by hand is one double-click from playback.

### Keyboard

| Key | Action |
| --- | --- |
| `⌘R` | Start / stop recording |
| `⌘S` | Grab still |
| `⌘E` | Instant replay of the last take |
| `M` / `⇧M` | Add / delete marker |
| `⌘G` / `⌘B` | Mark last take good / NG |
| `Z` | Punch-in zoom |
| `F` | Fullscreen |

All bindings are remappable in Settings.

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — architecture, the color pipeline, and the
  hard-won facts about capture hardware that the code depends on.
- [`ROADMAP.md`](ROADMAP.md) — feature status and open work.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to build, test and submit changes.

## License

MIT — see [LICENSE](LICENSE). The Blackmagic SDKs it builds against are
covered by Blackmagic Design's own terms.
