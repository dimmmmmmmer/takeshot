# Architecture

How TakeShot is put together, and the hardware behaviour the code depends on.
Read this before changing anything on the capture path.

## Targets

| Target | What it is |
| --- | --- |
| `CaptureCore` | The SDK-free core, compiled in **Swift 6 language mode** |
| `CDeckLink` | Obj-C++ bridge to the DeckLink SDK: `CDLCapture` (input), `CDLPlayout` (hardware monitor output) |
| `CBraw` | Obj-C++ bridge to the Blackmagic RAW SDK (`CBRClip`) |
| `TakeShotKit` | The application layer, as a library so tests can reach it |
| `TakeShot` | The executable entry point and nothing else |

`CaptureCore` holds `Timecode` (drop-frame math, `dayFrames` for the midnight
wrap), `RecDetector` (the REC/IDLE state machine), `LTCDecoder` (SMPTE 12M
biphase decode from PCM), `NamingEngine`, `TakeWriter` (AVAssetWriter: video,
audio and a possibly multi-sample timecode track — one file is one take),
`CapturePipeline` (the per-frame path), `TenBitConverter`, `MetalPreviewLayer`
with `PreviewSinkRegistry`, `ScopeAnalyzer`, `CompareCompositor`, `CubeLUT`,
the exporters, and the `CaptureBackend` protocol that keeps a future AJA
backend possible. `Sendability.swift` states the cross-thread contracts in one
place rather than boxing at a hundred call sites.

`TakeShotKit` holds `CaptureController` and its domain extensions (`+Capture`,
`+Playback`, `+Transport`, `+Compare`, `+LUT`, `+Markers`, `+Library`,
`+Offload`, `+Windows`, `+Settings`, `+Takes`, `+Thumbnails`, `+Audio`,
`+Naming`, `+Viewer`), the two playback engines (`PlaybackFrameTap` for AVPlayer
video and stills, `RawPlayerModel` for BRAW and CinemaDNG), `PlayoutFeeder`, and
the SwiftUI views.

`+Transport` exists because there are two playback engines and one menu bar:
each engine has a transport bar wired straight to it, and `AppCommands` needs
one set of items for whichever is loaded.

`CaptureController` and `CapturePipeline` were 2615 and 1315 lines before they
were split — the size at which nobody reads a type top to bottom any more. New
behaviour goes into the matching domain extension, not back into the class.

## Threading

Backend callbacks arrive on a background thread and are hopped onto the
MainActor. The queues that must never be blocked:

- **The capture queue** owns per-frame work.
- **Presentation**, **scope analysis** and **playout** each run on their own
  queue with latest-wins coalescing.

Anything doing GPU work or file I/O belongs off the capture queue — including
UI-triggered redraws, because `nextDrawable()` parks for up to a second on an
occluded window.

Closure properties that cross threads go behind a lock. A closure is two words
with an ARC-managed context: read it on one thread while another writes it and
the caller gets a function pointer paired with the wrong context, which crashes
with whatever signal the garbage earns. `displayFrameHandler` and the take
callbacks in `CapturePipeline` are locked for exactly this reason — it cost a
week of red CI to learn once.

## Preview display rule

A CALayer can be hosted by **one** NSView. Every preview mount registers its own
`MetalPreviewLayer` as a sink (`CapturePipeline.addDisplaySink`,
`PlaybackFrameTap.addSink`, `RawPlayerModel.addSink`); never share a layer
between views.

The main viewer is a single `ViewerSurface` whose frame source is re-routed
between live, playback and RAW. Do not mount separate per-mode surfaces there —
their letterboxes round independently and the image shifts by a pixel when the
operator switches modes.

### Which stage a display-only tool belongs in

There are two of them and they answer different questions.

- Inside the render, per sink (`MetalPreviewLayer+Assist`): false color, EL
  Zone, zebra, peaking, desqueeze, punch-in. These are what the OPERATOR reads
  off the glass, and they reach every surface that draws a frame — including
  the fullscreen and external-display windows, which are sinks like any other.
  They do **not** reach the DeckLink playout, which mirrors the pipeline's
  display frame rather than a layer.
- In the pipeline's display stage (`CapturePipeline+ChromaKey`, and the pinned
  reference compare beside it): the chroma key. It is composited into the frame
  that the sinks and the hardware monitor receive, one step after the viewing
  LUT — which is the rule the LUT itself follows.
  Everything that is a deliverable is taken from earlier in the frame path:
  the writer gets the record buffer, the still grab the leveled one, the scopes
  the wire. That ordering is why a keyed monitor cannot end up in a take, and
  `ChromaKeyIntegrityTests` is what keeps it that way.

The phone camera grid (`/cameras`) is deliberately NOT on either list. It is a
monitoring surface, not an assist one: it is handed the clean processed frame
from `enqueuePreview`, so the operator's compare wipe and chroma-key preview
never reach it, and the layer-drawn aids — false colour, EL Zone, zebra,
peaking, desqueeze, punch-in — cannot, because it is not one of the layer's
surfaces. `MultiviewEncoder` then encodes it with Rec.709 declared on both
ends, so the tile is the app's own picture rather than a gamma conversion of
it (owner item 13).

The chroma key runs on the display queue and never on the capture queue, it
costs one `Bool` read per frame while it is off, and a frame that reaches the
stage older than one frame interval is shown WITHOUT the key rather than held
up for it. Measured on an M-series laptop, release build: 1.5 ms a frame at
1080p, 3.3 ms at UHD, plus 0.5 ms on any frame where a control moved and the
32³ cube had to be rebuilt.

## Color pipeline

RGB 4:4:4 sources are captured as 10-bit `r210` by default. `TenBitConverter`
splits each wire frame in one pass into two products, built from two different
tables because the picture and the deliverable want opposite things:

- a full-range 8-bit BGRA **display** buffer (preview, LUTs, scopes, grabs,
  playout mirror, multiview), expanded on the NOMINAL pair — studio swing puts
  wire 64 on 0 and 940 on 1023, and the excursions clip;
- a **record** `r210` buffer carrying the WIRE codes, precompensated for
  VideoToolbox's measured convention and nothing else — VT treats `r210`
  content as video-range 64–960 and expands it inside the codec, so the table
  is `64 + code · 896/1023`.

Measured result: the decoded file returns the camera's codes within ±1 in
10-bit units, unbiased — exact on the five probe codes, footroom and headroom
included. The levels mode cannot reach the file at all, so a display decision
can no longer destroy a code in the deliverable.

Because the file carries studio swing, the player expands it again: takes are
written with a `com.takeshot.levels = wire` metadata key and
`PlaybackFrameTap+Levels` applies the same 8-bit table the live path uses
(`StudioSwing`). Foreign clips, stills and takes recorded before that key
existed are left alone. `PlaybackLevelsParityTests` records a synthetic frame,
plays it back and compares the two pictures code for code.

### Input levels, and where each answer lands

`InputLevels` resolves the `videoLevels` setting into what the DISPLAY does;
`auto` means limited for RGB 4:4:4.

| Mode | Wire window onto 0–1023 (display) | In the file | On the scopes |
| --- | --- | --- | --- |
| `full` | 0–1023 (identity) | wire codes | as sent |
| `limited` (default) | 64–940, excursions clipped | wire codes | as sent |

An operator judges exposure against a black that is black, which is why the
picture clips; the codes outside the nominal pair are kept where they are
useful — in the deliverable and on the scopes, neither of which reads the
display buffer. `LevelsExcursionTests` pins both halves, numerically and
through a real encode/decode round trip.

### What the scopes measure

For a 10-bit RGB wire the analyzer reads the **wire frame**, not the display
buffer (`CapturePipeline.LevelledFrame.scopeSource`; the only cost on the
capture queue is retaining the buffer). Two reasons, and the operator reported
both as symptoms:

- the display buffer is 8-bit, so a scope reading it is quantized to 256 levels
  however good the source is — the "8-bit, undetailed" parade;
- the display expansion clips everything outside 64–940 on purpose, so the
  sub-blacks and super-whites a scope exists to reveal are not in that buffer
  at all.

`ScopeData.nominal` says where 0% and 100% sit on the trace map, and every
graticule, value number and histogram mark is placed through it — so on a wire
frame the trace legitimately runs past the nominal lines and the bands beyond
them are shaded, the way Resolve draws below-0 / above-100. Every other format
still reaches the analyzer already expanded, and reads as `.full`, which is the
geometry the scopes always had.

## Recording integrity

These are load-bearing. A change that touches one belongs in its own commit
with the reasoning stated.

- `movieFragmentInterval` is set: a crash or power loss mid-take must not lose
  the whole file.
- A mid-take format change, a signal loss, or a dead writer closes the take
  with a **sticky** alarm. The writer returning `false` is ambiguous between
  "busy encoder" and "volume detached"; `TakeWriter.hasFailed` disambiguates.
- A take joins the list only after a successful finalize. A failed finalize is
  renamed `*_FAILED.mov` rather than re-adopted by the folder scan as healthy
  footage.
- The audio channel mask is latched per take — the writer's channel count is
  fixed at take start, and changing it live kills the file.
- Pre-roll carries audio as well as picture.
- Dropped video, audio and pre-roll frames are counted and shown.
- Free space is watched: a warning under 5 GB, the take is closed under 0.5 GB.

## Hard-won facts

Each of these cost a session on real hardware. The code comments at the sites
carry the detail.

- **Format-detection restart loop.** Restarting the streams from the format
  callback re-arms detection, which fires the callback again — an endless loop
  that pins stream time at 0, so every frame gets PTS 0 and takes come out
  0 bytes. Guard on an actual mode or pixel-format change.
- **Input levels state the SOURCE's range.** Limited (16–235, or 64–940 in
  10-bit) is expanded exactly once, on gamma-encoded values — a CoreImage
  matrix in linear space crushes the shadows. Full passes through untouched.
  Auto assumes limited for RGB 4:4:4 HDMI, the CTA-861 default.
- **Never tag writer-bound buffers with a non-standard transfer.** The encoder
  color-converts on tag mismatch, and CVBuffer attachments leak between buffers
  that share an IOSurface. Both measured on device.
- **`AVSampleBufferDisplayLayer` is off-limits for the viewer.** Composited
  (rounded corners, overlays) it shows video-range codes unexpanded — washed
  blacks that no pixel format or tagging fixes.
- **Detection defaults to VANC-only.** Running timecode alone is not evidence a
  camera is rolling: a Resolve playout feeding the board runs timecode too, and
  it must never start a take.
- **Stills are deliverables, not screenshots.** Grabs never bake the preview
  LUT, and stills in the player go through the same tap render as video —
  SwiftUI's `Image` is color-managed differently and never matched.
- **Ad-hoc signing changes the cdhash on every rebuild**, so TCC grants die and
  the app hangs at first launch. Until there is a stable signing identity, run
  the binary directly from the shell.

## Demo source

`MockCaptureBackend` is hidden from the production UI. It appears in the device
list only when the app is launched as `TakeShot --demo` (or with
`TAKESHOT_DEMO=1`), and generates a 1080p25 signal with Rec Run timecode; a
"REC demo camera" button shows up when it is selected. This is how the GUI and
the take logic are exercised end to end without a board.

## UI layout

The capture device is chosen in Settings, not in the main window. Above the
player: timecode on the left, resolution and frame rate on the right. Below it:
a large red REC button dead centre; settings, the VANC monitor and the folder
picker bottom-left; the Prefix/Cam/Roll/Clip fields on the right. Changing the
roll resets the clip number. The title bar is hidden. Theme and the player
background colour live in Settings.

The takes panel has an "open folder" button and an Other content block for
files that arrive in the record folder from outside the app. The metadata CSV
uses a Reel Name column, which is the roll.

The offload and verify sheets are set in one type family — three sizes and two
weights in `OffloadChrome`, applied by the single `offloadText(_:)` modifier, so
a label added later cannot drift off it. Neither sheet holds its run hostage:
both close over a live job, and while one is going the takes-panel utility strip
carries it (`OffloadStatusStrip` — percent, the file in flight, a bar and Stop),
with the strip itself the way back into the sheet. That is why the models and
the history store are owned by `CaptureController` and not by a view: the run
outlives every render of the sheet it was started from.

The menu bar is built in `AppCommands.swift` from SwiftUI command groups (File,
View, a Playback menu, Help; Edit is left alone because the naming fields are
typed with it). Every item calls the controller method the on-screen button
calls. A binding becomes a menu key equivalent only if it carries ⌘ or ⌃: AppKit
offers the main menu a key before the first responder sees it, so a bare "M"
would drop a marker while a roll name is being typed.

## Sidecars in the record folder

- `takeshot-log.csv` — the Resolve metadata table (File Name, Reel Name, Take,
  Good Take, Comments). Good Take is a checkbox, and the rating is ternary, so
  the third state is the absence of a value: `true` for good, `false` plus a
  `Bad` marker in Comments for a rejected take, and EMPTY for one nobody has
  rated. Writing `false` for unrated told Resolve the whole day was rejected.
  The written marker used to be `NG`; the parser reads both spellings forever,
  so logs from older builds still restore their ratings.
- `takeshot-markers.csv` — File Name, Timecode, Color, Note. It carries the
  takes' markers and, keyed the same way, the markers of anything else in the
  record folder (`CaptureController.otherMarkers`): the marker controls live in
  the transport, the transport runs for whatever is loaded, and a clip copied
  off a card is a clip somebody wants to flag. Such a file has no start timecode
  we read, so its positions are offsets from zero. The timecode is the
  position; there is no seconds column (there was, and the two records of one
  value drifted apart). Reading is two steps — `parseMarkerRows` for the file,
  then `markers(_:of:)` once the take's own start timecode is known. A take with
  NO start timecode stores offsets from zero instead, on both sides of the file:
  there is nothing to subtract an absolute camera timecode from, so writing one
  out would place the marker hours past the end of the take. The conversion
  itself lives in `+MarkerTime`, shared with the shift report's duration
  counting and with the controller's anchoring of a recording's markers.
- Offload writes three files into each destination:
  `ascmhl/NNNN_<name>_<stamp>.mhl` (an ASC MHL v2.0 hashlist outside tools can
  verify), `offload-summary_<stamp>.txt` (the human-readable verdict) and
  `offload-summary_<stamp>.png` (the same verdict as a picture to hand over —
  see `OffloadReportCard` for why an image and not a PDF). All three are
  recognized by `OffloadVerify.isReportFile`, or every one of them would be
  reported as a stray by the pass that reads the disk back.
  `OffloadHashAlgorithm` still carries both hashes and the verify pass reads a
  manifest of either, but the UI no longer asks: a run is xxHash64, which is
  what the DIT tools re-verify against. "Check a disk copy…" re-reads a copy
  against the newest manifest generation.
- The log of past offloads is NOT a sidecar: it is
  `Application Support/TakeShot/offload-history.json` (`OffloadHistoryStore`,
  capped at 20). The record folder is emptied and re-pointed between shooting
  days, and the card being copied has nothing to do with it.

## Localization

The base language is English. UI strings go through `L("key")`
(`Sources/TakeShotKit/L10n.swift`) with the tables in
`Sources/TakeShotKit/Resources/{en,ru}.lproj/Localizable.strings`. The language
switch swaps the `.lproj` bundle and is stored in `CaptureSettings.appLanguage`
(nil means follow the system).

Make new settings fields **Optional** — otherwise saved JSON from an older
build will not decode. Core errors (`CaptureCore`, `CDeckLink`) are English and
not localized. Add every new string to both tables.

The help page is the exception: it is prose, several pages of it, so it lives as
`Help.md` in each `.lproj` rather than as escaped one-line strings. `HelpDocument`
reads it from the bundle L10n currently holds — `Bundle.module` would give the
system language and ignore the in-app switch — and parses the small Markdown
subset it is written in.

## CI

- `ci.yml` — build, lint (`--strict`), tests, and a `TakeShot.zip` artifact on
  every push and pull request, plus a separate ThreadSanitizer job.
- `codacy-coverage.yml` — uploads lcov coverage. The token lives in the
  `CODACY_PROJECT_TOKEN` repository secret and is never committed.
- `release.yml` — on a `v*` tag, builds the app and publishes a GitHub Release
  with a DMG.

The runners are two major versions behind a current developer machine, which is
a feature: it is where timing-dependent bugs surface.
