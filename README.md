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
and drag TakeShot to Applications. [`CHANGELOG.md`](CHANGELOG.md) says what
changed in each one.

Three things to know before you download, because they decide whether the
build is any use to you:

- **It cannot record from a capture board.** The published builds are made on a
  machine with none of the vendor SDKs on it — Blackmagic's and RED's licences
  both forbid redistributing them — so the DeckLink bridge is compiled
  as a stub and no capture device is visible to it at all. It opens, plays back
  and exports footage you already have, and it runs its built-in demo camera,
  which is enough to see whether you like the tool. To capture, build from
  source with Blackmagic's SDK: [`CONTRIBUTING.md`](CONTRIBUTING.md) says where
  it goes and it is a five-minute job. Every release page lists which bridges
  that particular build has, and so does the app's own **Collect diagnostics**
  report.
- **Ad-hoc signed, not notarized.** The first launch needs a right-click →
  **Open** instead of a double-click; macOS then remembers the choice. A
  Developer ID signature is on the list, not done.
- **Apple Silicon.** The DMG is an `arm64` build — a plain SwiftPM build of
  the machine it was made on, and that machine is an Apple Silicon runner. An
  Intel Mac has to build from source. Every release page states the
  architectures of that particular build, read off the binary rather than
  assumed.

## Features

### Recording

- Auto-takes from the camera's REC state — VANC trigger by default, running
  timecode or manual as alternatives.
- …and from the camera's own **record indicator on the monitoring output**, for
  a camera that sends no VANC at all: mark a small box on the live picture,
  capture it once rolling and once idle, and the take follows the dot. A switch
  beside the modes rather than one of them, opt-in only, and the REC mark over
  the player says which of the three triggers rolled the take.
- Pre-roll buffer: every take opens with picture *and* sound from before the
  REC press, so nothing is lost to trigger latency.
- 10-bit capture by default, at whatever the wire is carrying: `v210` for the
  ordinary 4:2:2 SDI signal, `r210` for RGB 4:4:4, with 12-bit (`R12B`) as an
  opt-in for RGB 4:4:4 only. A depth the board refuses falls back visibly
  rather than producing black frames. ProRes Proxy/LT/422/HQ/4444, H.264 and
  HEVC.
- Sound from the board's embedded audio or from a USB audio interface — the
  sound cart's mix straight into the take, falling back to embedded audio,
  loudly, if the interface disappears.
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
- BRAW and CinemaDNG playback, and R3D — RED clips including spanned ones,
  developed to Rec.709 with the camera's metadata and edge timecode. Needs a
  build made against RED's SDK (`vendor/R3DSDK/README.md`); without it an
  `.r3d` is recognised and reported as unsupported rather than ignored.
- Compare against the live signal, a pinned reference frame, or another take,
  with wipe, blend, A/B and a per-pixel difference at ×1/×4/×16 gain.
- Sync-play: two to four takes in one transport-locked grid, aligned from each
  take's first frame or on the timecode they share.
- Waveform, RGB parade, histogram and vectorscope, as an overlay or in their
  own window.
- Viewing looks for preview and/or baked into the recording: `.cube` lattices,
  mirrored into the DaVinci Resolve LUT folder on import, and ASC CDL grades
  (`.cdl`, `.ccc`, `.cc`), which take the same path and keep their slope,
  offset, power and saturation for the selects EDL.

### Operator tools

- False color, EL Zone, zebra and focus peaking — stacking, with a legend that
  is burned into the picture, so the hardware monitor gets it too.
- Framelines, safe areas, anamorphic desqueeze, punch-in with drag-to-pan.
- Hardware monitor output: the viewer mirrors to a DeckLink SDI/HDMI out.
- SRT output: the same mirrored viewer, H.264 in an MPEG-TS, sent to an address
  on the set network — VLC on a director's laptop, OBS, a Resolve station, a
  cloud gateway. Caller or listener, with the latency, the bitrate and an
  optional AES passphrase as the only knobs. Off by default; needs libsrt at
  build time (`vendor/SRTSDK/README.md`) and installed to send.
- Chroma key for the monitor: pull the green screen with an eyedropper,
  tolerance, softness and spill, and put a checkerboard, a colour or a still
  behind the actor. Preview and monitor output only — the take, the grabs and
  the exports keep the original picture, deliberately.
- Digital slate: a fullscreen card with a running timecode and the rolling
  take's name to point a camera at, with a white sync flash on click.
- Markers with timecode while recording and while reviewing.
- Keyboard shortcuts for everything on the shot floor, all remappable.
- A menu bar item, off by default, that keeps the recorder's state and the
  running take's timecode visible — and stoppable — with the window closed.
- **Collect diagnostics** (Help menu) writes a folder to the Desktop with the
  build, the board, the signal, the takes and the settings in it. Nothing is
  uploaded; the remote PIN is dropped and the home directory is written as `~`.

### The phone on set

The web remote is off until you switch it on, serves five pages behind one
four-digit PIN, and loads nothing from the internet — the pages work on a set
network with no route out. Settings shows a QR code for each.

- `/` — the operator remote: REC and STOP, marker, good/bad, timecode, free
  disk and a poster frame of the last take.
- `/script` — the script supervisor's take log, live, with the rating and a
  comment typed straight into the take.
- `/cameras` — every board's live signal as tiles, each labelled and with its
  own REC light. No frames are encoded at all unless somebody has it open.
- `/live` — the viewer as actual video: H.264 over WebRTC, at the signal's own
  rate, the same decorated picture the SRT output carries. One encode serves
  it, the SRT link and every other watcher between them, and nothing is encoded
  at all while nobody is watching. Needs libdatachannel
  (`vendor/libdatachannel/README.md`); a build made without it says so on the
  page and the tiles above keep working.
- `/slate` — the digital slate on a phone held in front of the lens: running
  timecode, the scene and take card, and a sync flash.

### Handover

- Resolve-compatible metadata CSV, selects EDL from good takes with markers as
  locators and the active ASC CDL as `*ASC_SOP`/`*ASC_SAT`, an Avid log (ALE)
  of every take for a Media Composer bin, shift report as PDF and CSV.
- Scene, shot and take recorded per take beside the rating and the comment,
  written into the file and into the sidecars — a correction typed after the
  fact still reaches post.
- Contact sheet: the day as one PDF of poster frames, a cell per take.
- Dailies: the day's takes batch-transcoded to H.264 with timecode, clip name,
  project and camera burned in. The queue pauses itself while a take rolls.
- DIT offload of a camera card to several SSDs at once: the card is read once
  and written to every destination in the same pass, each copy is verified by
  re-reading it off the disk, and every destination gets a report — a picture
  to hand over and the same thing as plain text — beside the ASC MHL checksum
  list that post re-verifies it against. xxHash64, which is what Silverstack,
  OffShoot and Hedge check against. A destination that fails does so alone; the
  others finish. The sheet closes over a running copy (the takes panel keeps
  reporting it) and opens showing the last twenty offloads made from this Mac.
- A card plugged in while the app is running is recognised (DCIM, XDROOT, BPAV,
  M4ROOT, AVCHD, CONTENTS…) and **offered** in the takes panel — Offload,
  Ignore or Never, with the reason it was recognised shown so the operator can
  judge. Nothing is ever copied without that answer, and nothing is asked
  during a take: a card that mounts mid-take is offered when the take closes.
  A card already offloaded is not offered again unless it has been shot on
  since.

## Requirements

- macOS 15 (Sequoia) or newer. The published DMG is Apple Silicon; an Intel Mac
  has to build from source.
- To capture: a Blackmagic DeckLink or UltraStudio with
  [Desktop Video](https://www.blackmagicdesign.com/support/) installed, **and a
  build made against the DeckLink SDK** — see the note under
  [Download](#download). Desktop Video alone is not enough for a build that has
  no SDK in it.
- For `.braw` playback:
  [Blackmagic RAW](https://www.blackmagicdesign.com/products/blackmagicraw)
  (the free player installs the runtime TakeShot uses), plus a build made
  against the Blackmagic RAW SDK.

### What works with no SDK and no hardware at all

Everything downstream of the picture: playback of existing takes and foreign
clips, compare, scopes, LUTs and CDLs, false colour and the other assists,
markers, stills, the reports and exports, dailies, the contact sheet, the DIT
card offload, and the whole web remote. The device list carries a built-in demo
camera generating a 1080p25 signal, so recording a take and everything you
would do with it afterwards can be exercised end to end without a board.
Auto-takes cannot: the demo camera's timecode is parked, and REC detection
wants a real camera's running timecode or a VANC trigger.

What needs a vendor SDK you obtain yourself — free, but from the vendor, under
their terms — is the hardware itself: capture and monitor output (DeckLink),
`.braw` playback (Blackmagic RAW) and `.r3d` playback (RED). The SRT output
needs libsrt, which is the one exception to "from the vendor, under their terms":
it is MPL-2.0 and `brew install srt` away. The `/live` page needs
libdatachannel, MPL-2.0 as well but in no package manager — which is why a
published build carries the dylib inside the app rather than hoping to find one
(`vendor/libdatachannel/README.md`, and the licence note in `NOTICE`).
[`CONTRIBUTING.md`](CONTRIBUTING.md) says where each SDK goes. R3D, BRAW and SRT
each say so at the point of use; a build with no DeckLink SDK simply lists no
capture device, and **Collect diagnostics** is where it explains itself.

## Usage

1. Pick the capture device in Settings.
2. Set the project name, camera letter and roll; the clip number steps itself.
3. Roll the camera. TakeShot starts and stops takes with it, or use the REC
   button for manual takes.

Takes land in the destination folder with a Resolve-compatible CSV beside
them. Anything else that appears in that folder shows up under Other content,
so a card copied in by hand is one double-click from playback.

## Documentation

- [`CHANGELOG.md`](CHANGELOG.md) — what changed in each release, and what is
  known not to work yet, written for the operator rather than the reviewer.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — building from source, testing, and how
  to submit changes.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the app is put together
  and the hardware behaviour it depends on.
- [`docs/coverage.md`](docs/coverage.md) — how coverage is measured and gated,
  the seams that make hardware-bound code testable, and what genuinely cannot be
  covered without a board or a UI session.

## License

MIT — see [LICENSE](LICENSE). The vendor SDKs TakeShot builds against are not
included here and stay under their own terms; [NOTICE](NOTICE) lists them.
The web remote's pages embed **Resist Sans Display** (Groteskly Yours, Eugene
Tantsurin), included under a licence held by the project owner and not covered
by the MIT License — see [NOTICE](NOTICE).
