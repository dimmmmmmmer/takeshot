# TakeShot

On-set capture and video assist for macOS. TakeShot records a camera feed
through a Blackmagic DeckLink or UltraStudio, splits it into takes
automatically as the camera rolls, names the files from your metadata, and
gives the operator the review tools a video assist needs — playback, compare,
scopes, exposure aids, markers and reports.

[![CI](https://github.com/dimmmmmmmer/takeshot/actions/workflows/ci.yml/badge.svg)](https://github.com/dimmmmmmmer/takeshot/actions/workflows/ci.yml)
[![Code quality](https://app.codacy.com/project/badge/Grade/5223b50b77af47e3a35f9d49b9b9c9e9)](https://app.codacy.com/gh/dimmmmmmmer/takeshot/dashboard)
[![Coverage](https://app.codacy.com/project/badge/Coverage/5223b50b77af47e3a35f9d49b9b9c9e9)](https://app.codacy.com/gh/dimmmmmmmer/takeshot/coverage/dashboard)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Download

Grab the latest DMG from [Releases](https://github.com/dimmmmmmmer/takeshot/releases)
and drag TakeShot to Applications. [`CHANGELOG.md`](CHANGELOG.md) says what
changed in each one.

Three things about the published build:

- **It cannot record from a capture board.** The vendor SDKs cannot be
  redistributed, so the DeckLink bridge ships as a stub and no capture device
  is visible. Everything downstream of the picture works, and a built-in demo
  camera stands in for a board. To capture, build with Blackmagic's SDK —
  [`CONTRIBUTING.md`](CONTRIBUTING.md) says where it goes.
- **Ad-hoc signed, not notarized.** Gatekeeper blocks the first launch:
  System Settings → Privacy & Security → **Open Anyway**, or `xattr -d
  com.apple.quarantine TakeShot.app`.
- **Apple Silicon.** The DMG is `arm64`; an Intel Mac builds from source. Each
  release page lists that build's architectures and bridges, and so does the
  app's **Collect diagnostics**.

## Features

### Recording

- Auto-takes from the camera's REC state — VANC trigger by default, running
  timecode or manual as alternatives.
- …and from the camera's own **record indicator on the monitoring output**, for
  a camera that sends no VANC: mark a box on the live picture, capture it once
  rolling and once idle, and the take follows the dot.
- Pre-roll buffer: every take opens with picture *and* sound from before the
  REC press, so nothing is lost to trigger latency.
- 10-bit capture by default, at whatever the wire carries: `v210` for 4:2:2
  SDI, `r210` for RGB 4:4:4, 12-bit `R12B` when the source sends it. ProRes
  Proxy/LT/422/HQ/4444, H.264 and HEVC.
- Sound from the board's embedded audio or a USB interface — the cart's mix
  straight into the take, falling back loudly if the interface disappears.
- Timecode track per take, with a second anchor written when the camera's
  Rec Run starts mid-take, so the overlap conforms frame-accurately against
  the camera original.
- LTC decode from an embedded audio channel when the camera sends no RP188.
- Multicam: every additional board records in sync on one REC press.
- Recording integrity: fragmented files (a crash cannot lose the take), takes
  closed on format change or signal loss, a disk-space watch, and sticky alarms
  for anything that threatens a recording.

### Review

- One render path for live, playback, stills and RAW — what you compare is
  what you recorded, pixel for pixel.
- BRAW and CinemaDNG playback, and R3D — RED clips including spanned ones,
  developed to Rec.709 with the camera's metadata and edge timecode. Needs
  RED's SDK (`vendor/R3DSDK/README.md`); without it an `.r3d` is reported as
  unsupported rather than ignored.
- Compare against the live signal, a pinned reference frame, or another take,
  with wipe, blend, A/B and a per-pixel difference at ×1/×4/×16 gain.
- Sync-play: two to four takes in one transport-locked grid, aligned from each
  take's first frame or on the timecode they share.
- Waveform, RGB parade, histogram and vectorscope, as an overlay or in their
  own window.
- Viewing looks for preview and/or baked into the recording: `.cube` lattices,
  mirrored into Resolve's LUT folder on import, and ASC CDL grades (`.cdl`,
  `.ccc`, `.cc`), which keep their slope, offset, power and saturation for the
  selects EDL.

### Operator tools

- False color, EL Zone, zebra and focus peaking — stacking, with a legend that
  is burned into the picture, so the hardware monitor gets it too.
- Framelines, safe areas, and the nine sizing controls a colourist has in
  Resolve — anamorphic desqueeze, punch-in with drag-to-pan, rotate, flip,
  pitch and yaw. They reach every output, not just the operator's window, and
  a checkbox bakes them into the recording.
- A clean feed on one key: every overlay off, the picture and nothing else.
- Hardware monitor output: the viewer mirrors to a DeckLink SDI/HDMI out.
- SRT output: the mirrored viewer as H.264 in an MPEG-TS, with a stereo AAC
  fold of the recorded channels. Caller or listener, bitrate, optional AES
  passphrase and a stream ID; the delivery buffer sizes itself from the link's
  round trip. Off by default; needs libsrt (`vendor/SRTSDK/README.md`).
- NDI output: the mirrored viewer announced on the set network, for a
  director's iPad or a client feed — a receiver picks it out of a list, no
  address to type. Off by default; needs the NDI SDK
  (`vendor/NDISDK/README.md`) and an NDI runtime.
- Chroma key: pull the green screen with an eyedropper, tolerance, softness
  and spill, and put a checkerboard, a colour or a still behind the actor. A
  preview tool by default; **Bake into recording** makes the next take a
  composite instead, and says what that costs before you throw it.
- Digital slate: a fullscreen card with a running timecode and the rolling
  take's name to point a camera at, with a white sync flash on click.
- Markers with timecode while recording and while reviewing.
- Keyboard shortcuts for everything on the shot floor, all remappable.
- A menu bar item, off by default, keeping the recorder's state and the
  running take's timecode visible — and stoppable — with the window closed.
- **Collect diagnostics** (Help menu) writes a folder to the Desktop with the
  build, the board, the signal, the takes and the settings. Nothing is
  uploaded; the remote PIN is dropped and the home directory is written as `~`.

### The phone on set

Off until you switch it on, four pages behind one four-digit PIN, and nothing
loaded from the internet — the pages work on a set network with no route out.
Settings shows a QR code for each.

- `/` — the operator remote: REC and STOP, marker, good/bad, timecode, free
  disk and a poster frame of the last take.
- `/script` — the script supervisor's take log, live, with the rating and a
  comment typed straight into the take.
- `/live` — the viewer as video: H.264 over WebRTC at the signal's own rate.
  **The phone chooses what it watches** — Monitor (the operator's picture,
  aids and key included, which is what SRT carries), Camera (the clean signal
  with the settled framing — desqueeze, flips, rotation — and none of the
  tools), or Grid (every camera at once). Remembered per phone, switched
  without the picture dropping, and nothing is encoded while nobody watches.
  Needs libdatachannel (`vendor/libdatachannel/README.md`).
- `/slate` — the digital slate on a phone held in front of the lens: running
  timecode, the scene and take card, and a sync flash.

### Handover

- Resolve-compatible metadata CSV; selects EDL from the circled takes with
  markers as locators and the active ASC CDL as `*ASC_SOP`/`*ASC_SAT`; an Avid
  log (ALE) carrying the same grade in its own columns; shift report as PDF and
  CSV.
- Timeline of the circled takes with their markers, each clip pointing at its
  own file — so an edit suite opens with the picture on the timeline instead of
  a relink dialog. A clip is placed over the part review marked while the media
  stays whole, so the editor can pull the head or tail back out. Two formats:
  FCP7 `xmeml` (`.xml`), which almost everything reads, and FCPXML 1.10
  (`.fcpxml`) for Resolve and Premiere.
- Scene, shot and take per take beside the rating and the comment, written into
  the file and the sidecars — a correction typed after the fact still reaches
  post.
- Contact sheet: the day as one PDF of poster frames, a cell per take.
- Dailies: the day's takes batch-transcoded with timecode, clip name, project
  and camera burned in, the source's timecode carried over as a track, and the
  on-set markers written in as CHAPTERS. The queue pauses while a take rolls.
- DIT offload of several cards to several SSDs at once: each card is read once
  and written to every destination in the same pass, each copy verified by
  re-reading it off the disk. Every destination gets a report (PDF and text)
  beside an ASC MHL checksum list — xxHash64, what Silverstack, OffShoot and
  Hedge check against. A destination that fails does so alone. The sheet closes
  over a running copy and reopens on the last twenty offloads.
- A card plugged in while the app runs is recognised (DCIM, XDROOT, BPAV,
  M4ROOT, AVCHD, CONTENTS…) and **offered** — Offload, Ignore or Never, with
  the reason shown. Nothing is copied without that answer and nothing is asked
  during a take; a card already offloaded is not offered again unless it has
  been shot on since.

## Requirements

- macOS 15 (Sequoia) or newer, Apple Silicon (an Intel Mac builds from source).
- To capture: a Blackmagic DeckLink or UltraStudio with
  [Desktop Video](https://www.blackmagicdesign.com/support/), **and a build
  made against the DeckLink SDK** — Desktop Video alone is not enough.
- For `.braw`:
  [Blackmagic RAW](https://www.blackmagicdesign.com/products/blackmagicraw)
  installs the runtime, plus a build made against its SDK.

### What works with no SDK and no hardware

Everything downstream of the picture: playback of takes and foreign clips,
compare, scopes, LUTs and CDLs, the operator aids, markers, stills, reports and
exports, dailies, the card offload and the whole web remote. A built-in demo
camera generates 1080p25, so recording a take and everything after it can be
exercised end to end without a board — except auto-takes, which want a real
camera's running timecode or a VANC trigger.

What needs a vendor SDK is the hardware: capture and monitor output
(DeckLink), `.braw` (Blackmagic RAW), `.r3d` (RED) and NDI (Vizrt). SRT needs
libsrt (MPL-2.0, `brew install srt`); `/live` needs libdatachannel (MPL-2.0,
carried inside published builds — see `NOTICE`).
[`CONTRIBUTING.md`](CONTRIBUTING.md) says where each goes.

## Usage

1. Pick the capture device in Settings.
2. Set the project name, camera letter and roll; the clip number steps itself.
3. Roll the camera. TakeShot starts and stops takes with it, or use the REC
   button for manual takes.

Takes land in the destination folder with a Resolve-compatible CSV beside
them. Anything else in that folder shows up under Other content, so a card
copied in by hand is one double-click from playback.

## Documentation

- [`CHANGELOG.md`](CHANGELOG.md) — what changed in each release, and what is
  known not to work yet.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — building from source, testing, and
  submitting changes.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the app is put together
  and the hardware behaviour it depends on.
- [`docs/coverage.md`](docs/coverage.md) — how coverage is measured and gated,
  and what cannot be covered without a board or a UI session.

## License

MIT — see [LICENSE](LICENSE). The vendor SDKs are not included and stay under
their own terms. The web remote embeds **Resist Sans Display** (Groteskly
Yours, Eugene Tantsurin) under a licence held by the project owner, not covered
by the MIT License. [NOTICE](NOTICE) lists both.
