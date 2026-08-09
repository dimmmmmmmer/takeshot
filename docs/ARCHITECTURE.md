# Architecture

How TakeShot is put together, and the hardware behaviour the code depends on.
Read this before changing anything on the capture path.

## Targets

Every Swift target is compiled in **Swift 6 language mode**, so the threading
rules below are checked rather than merely written down. What stays deliberately
unchecked says so at the site: `Sendability.swift` for the CoreVideo and
CoreMedia buffer types, the `@unchecked Sendable` classes that each name the
queue they are confined to, and a handful of `nonisolated(unsafe)` declarations
with the invariant on the line above them.

It has to hold under two SDKs, which is a real constraint rather than a
formality: CI builds against the macOS 15 SDK and the development machine has
the macOS 26 one, and Apple's AVFoundation concurrency annotations are not the
same in both. Where they differ the code obeys the STRICTER of the two, and by
construction rather than by annotation — an `AVMetadataItem` or an
`AVAssetTrack` is reduced to Sendable data inside the nonisolated scope that
loaded it and never crosses at all, which is right whichever SDK is compiling.
The one place that cannot be settled that way is
`AVPlayerItem.addOutput:`/`removeOutput:`, which macOS 26 declares
`NS_SWIFT_NONISOLATED` and macOS 15 leaves inside the class's
`NS_SWIFT_UI_ACTOR`; the tap sends those two messages dynamically from its own
queue, at one site, with the reasoning written out there
(`PlaybackFrameTap.swift`).

When an older SDK is installed beside the current one — the Command Line Tools
keep both under `/Library/Developer/CommandLineTools/SDKs/` — the other half
can be checked here rather than on CI:

```sh
SDK=$(xcrun --sdk macosx15.4 --show-sdk-path)
swift build --scratch-path .build-sdk15 \
    -Xswiftc -sdk -Xswiftc "$SDK" -Xcc -isysroot -Xcc "$SDK"
```

All three parts matter. `-Xcc -isysroot` is not decoration: without it the
clang importer keeps the default sysroot while Swift uses the old one, and the
build dies on `cannot load underlying module for '_errno'` long before it
reaches anything interesting. The separate scratch path is needed because a
`.build` holding artifacts from the current SDK fails the same way. Worth doing
before touching anything that awaits AVFoundation — the newer SDK does not
diagnose what the older one will.

**It covers `Sources` and NOT the tests, which is where this bit next.** `swift
build` does not compile the test target, and the test target cannot be built
against the old SDK here at all: `Testing.framework` ships with the Command
Line Tools built for the current one, and asking for 15.4 fails on its own
interface before reaching a line of ours. So the two-SDK check above proves
nothing about `Tests/`, and CI is the only place that is checked. It has
already caught four sites there that this command called clean — a
`@MainActor` suite receiving an `NSImage`-carrying struct, an
`[AVMetadataItem]`, and a generic `T` out of an unisolated closure. The fix is
always the same one the app uses: reduce to Sendable values inside the
nonisolated scope, or state the isolation the closure was really running in.

**It is evidence, not proof.** The SDK is only half of what CI differs by: the
runner is also on an older Swift, and the compiler is what enforces
concurrency. Measured on the commit this paragraph was written for — CI (Swift
6.1) rejected eight sites; the same tree here (Swift 6.3.3) against the same
macOS 15.4 SDK rejected three, in three of the same files, with different
wording. So a clean run here means "nothing this configuration can see",
which is worth a great deal and is not the same as green.

| Target | What it is |
| --- | --- |
| `CaptureCore` | The SDK-free core |
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

There is one, and it is the pipeline's display stage — `publishDisplayFrame`,
which runs the chroma key (`CapturePipeline+ChromaKey`, and the pinned reference
compare beside it) and then the operator aids (`AssistStage`, whose filter
chains live in `AssistFilters`): false color, EL Zone, zebra, peaking,
desqueeze, punch-in. Key first, aids second — a false colour has to meter the
picture the monitor is actually showing, background and all.

The aids used to be applied inside `MetalPreviewLayer.render`, once per mounted
surface. That worked for windows and for nothing else: the hardware playout, the
NDI source and the director's monitor are handed a pixel buffer rather than a
layer, so none of them ever saw a false colour or a frameline (owner item 7).
Running one pass per FRAME instead of one per SURFACE means every mirror of the
viewer carries what the operator switched on, and there is one place to reason
about rather than two.

Everything that is a deliverable is taken from earlier in the frame path: the
writer gets the record buffer, the still grab the leveled one, the scopes the
wire. That ordering is why a keyed or false-coloured monitor cannot end up in a
take, and `ChromaKeyIntegrityTests` and `AssistIntegrityTests` are what keep it
that way.

The phone camera grid (`/cameras`) is deliberately outside all of it. It is a
monitoring surface, not an assist one, so it is handed the `clean` buffer —
the same frame before the key and the aids — and the operator's compare wipe,
chroma-key preview and exposure tools never reach it. `MultiviewEncoder` then
encodes it with Rec.709 declared on both ends, so the tile is the app's own
picture rather than a gamma conversion of it (owner item 13).

How big that tile is depends on how many of them the page is laying out, and
that is not a refinement — a cap sized for a four-up grid is what made a single
camera look like a thumbnail, and a cap sized for the single view sends four
times the bytes for tiles a quarter of the screen. One camera gets 1280 on the
long edge, two get 960, three or more get 640, which is roughly the physical
pixels each tile occupies on a phone. Measured at 1080p in, JPEG at 0.75: 42.9,
28.4 and 16.5 KB a frame at 2.6, 1.5 and 1.5 ms, so the whole page stays inside
1.7-2.6 Mbit/s at the five-frame pace whatever the camera count. The reduction
is Lanczos and not an affine transform, which is a correctness point rather
than a taste one: `transformed(by:)` does not band-limit, and on a zone plate
reduced 1920 → 640 the band past the target's Nyquist came back with 18.9 codes
of standard deviation against Lanczos' 1.5 — fine detail folding into moire.
`MultiviewPerformanceTests` prints the timings and asserts the bytes.

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

### 12-bit RGB (`R12B`)

`bmdFormat12BitRGB` is offered as a capture bit depth (`captureBitDepth`,
default 10-bit — 12 is opt-in). `TwelveBitConverter` is the sibling of
`TenBitConverter` and produces the same two products; the display half of the
policy is shared (`WireDisplayTable`), so a 12-bit black lands exactly where a
10-bit black does. Studio swing at 12 bits is 256/3760, which is the same
fraction of the scale as 64/940 at 10.

The bit layout lives in exactly one place, `R12BPacking`: eight pixels in 36
bytes, and the rule is that the 24 components sit at 12-bit offsets into the
little-endian concatenation of nine big-endian words. Six of them straddle a
word boundary. `R12BPackingTests` pins every component against Blackmagic's
published byte table, transcribed independently in `R12BFixtures`.

The record half is where this path beats the 10-bit one. The buffer is
`kCVPixelFormatType_64RGBALE`, which VideoToolbox treats as **full range** — no
window, no clamp, no precompensation, so the record table is the identity
`code << 4`. Measured through a real ProRes 4444 encode and decode: codes 16,
256, 2048, 3760 and 4079 come back **exactly**, and the range ends 0 and 4095
survive as 0 and 4095. The 10-bit file is wire-*referred*; the 12-bit file is
wire-*exact*.

ProRes 4444 (`ap4h`) was added for it and is the only codec that can carry the
sampling: on a grey ramp ProRes 422 HQ measures identically, but on alternating
colour columns the red swing between neighbours is 3506 codes through 4444
against 1761 through 422 HQ — the 4:2:2 average, measured.

Measured cost, release, 1080p/UHD noise: the split is 1.50 ms / 3.03 ms against
0.65 ms / 1.27 ms for 10-bit, so roughly 2.3x — comfortably inside a 40 ms frame
interval. The record buffer is 8 bytes per pixel rather than 4, which the
pre-roll ring's memory cap accounts for (`recordBytesPerPixel`); without that a
3 s UHD pre-roll would reach ~3 GB against a 1.5 GB budget.

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

For a 10- or 12-bit RGB wire the analyzer reads the **wire frame**, not the
display buffer (`CapturePipeline.LevelledFrame.scopeSource`; the only cost on
the capture queue is retaining the buffer). Two reasons, and the operator
reported both as symptoms:

- the display buffer is 8-bit, so a scope reading it is quantized to 256 levels
  however good the source is — the "8-bit, undetailed" parade;
- the display expansion clips everything outside 64–940 on purpose, so the
  sub-blacks and super-whites a scope exists to reveal are not in that buffer
  at all.

A 12-bit wire is read by the same tap (`ScopeAnalyzer.R12BReader`, sharing
`R12BPacking` with the converter) and rounded onto the analyzer's 10-bit sample
scale by `ScopeAnalyzer.narrowed` — rounded, not truncated, so nominal black and
white stay exactly 64 and 940 and the graticule does not move. Those two dropped
bits are a stated limit rather than an oversight: the trace maps are 512 rows and
the histograms 256 bins, so the analyzer cannot display more than about nine bits
however many it is handed. The full 12 reach the file, which is where they are
worth something. Measured cost: 23.4 ms per 1080p pass, the same as `r210`
(23.5 ms) and BGRA (23.6 ms) — the pass is dominated by the accumulator, not the
pixel fetch — and the delivered rate is unchanged at 12.5 Hz live, 20 of 20
offered passes landing.

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

## Settings: one flat record, fourteen grouped views of it

`CaptureSettings` does two jobs and they pull in opposite directions.

It is the **record**. One JSON blob in `UserDefaults` under
`TakeShot.CaptureSettings`, 84 keys, and there is no error path for getting the
shape wrong: a key that moves stops decoding, `loaded(from:)` answers the throw
with a fresh default object, and the operator's destination folder, naming
template, calibrated assist thresholds and taught REC references are silently
replaced by defaults on the first launch of the update — on a shooting day.

It is also the app's **configuration surface**, read at several hundred call
sites, and as that it had grown into a god object: 84 flat stored properties,
half of them carrying a hand-maintained prefix (`chromaKeyPlateOffsetX`)
standing in for a namespace they could not have.

The two are reconciled by grouping the TYPE while keeping the WIRE FORMAT flat.
`CaptureSettings` holds fourteen domain groups (`capture`, `naming`, `audio`,
`theme`, `assist`, `review`, `lut`, `r3d`, `chromaKey`, `visualRec`, `remote`,
`ndi`, `dailies`, `offload`) plus `schemaVersion`. Each group carries its own
**synthesized** `Codable`; `CaptureSettings.encode(to:)`/`init(from:)` delegate
to all fourteen against a SINGLE keyed container, so every key still lands at
the top level exactly where it always did. Nothing hand-writes a per-field
encode or decode — the field-to-key mapping is still the compiler's, which is
what makes the 84 keys unforgeable.

Flatness is load-bearing for a second consumer as well as for the stored blob:
`DiagnosticsRedaction` walks this encoding as a flat map and drops secrets by
matching the top-level key NAME, which is how `remotePIN` stays out of a bundle
that gets emailed to someone. Nest it and the filter stops seeing it.

Three suites hold all of that still, and between them the format is a fact
rather than a claim:

- `ModelSettingsFormatTests` pins the exact key set, that a default install
  writes only the eight non-Optional keys, that a blob with a distinct value in
  every field round-trips value for value, that the encoding is flat, and that
  a save/load through `UserDefaults` — migration chain included — is the
  identity. Every assertion is phrased in JSON and none names a Swift property
  path, so a rearrangement of the type cannot edit the fixture it is read
  against.
- `ModelSettingsGroupNamingTests` closes what a round trip structurally cannot
  see: two same-typed fields whose `CodingKeys` are transposed round-trip
  perfectly. It reflects each group's property labels, encodes the group, and
  requires every key to derive from its own property by one mechanical rule
  (group prefix + capitalised label, or the label verbatim for a key that
  predates its group). It also checks the fourteen groups account for the whole
  format exactly once, which is what fails if a group is declared and never
  wired into the delegation.
- `ModelSettingsMigrationTests` covers what happens to a blob written by an
  older build, against hand-written JSON.

**Adding a setting**: put it in the group it belongs to, make it Optional, and
add its key to the pinned list in `SettingsFormatFixture`. **Adding a group**
means adding it to `init(from:)` and `encode(to:)` — a group left out of either
takes all of its keys with it, loudly, in the tests above rather than quietly on
somebody's set.

## Localization

The base language is English. UI strings go through `L("key")`
(`Sources/TakeShotKit/L10n.swift`) with the tables in
`Sources/TakeShotKit/Resources/{en,ru}.lproj/Localizable.strings`. The language
switch swaps the `.lproj` bundle and is stored in `ThemeSettings.appLanguage`
(nil means follow the system).

Make new settings fields **Optional** — otherwise saved JSON from an older
build will not decode (see the settings section above for where a new field
goes and what has to be told about it). Core errors (`CaptureCore`, `CDeckLink`) are English and
not localized. Add every new string to both tables.

### What crosses the CaptureCore boundary, and what does not

Core stays localization-free, so anything it reports has to arrive as a value
the app can put words to. Two bridges do that, and they are the same shape:
`ReportLocalization` fills the label structs the report writers take, and
`AlarmLocalization` turns a `PipelineAlarm` into the sentence in the banner.

The alarms are the case worth knowing about. The app decides between the sticky
banner and the five-second toast by reading `PipelineAlarm.severity`, which
CaptureCore states with the event. It used to read it off the message instead,
by matching English substrings ("TAKE LOST", "Dropped", "ingress"), which meant
the wording was load bearing: those messages could not be translated, and
translating them anyway would have quietly demoted every take-loss alarm to a
toast. Severity and prose are now separate answers to separate questions, and
the split is pinned message by message in `ControllerAlarmSeverityTests`
against the substring list it replaced.

What does **not** get translated is anything post-production reads. The
`takeshot-log.csv` and ALE `Comments` column carries a take's audio-padding
note (`CapturePipeline+Take.describeTake`), and it is written in English
whatever the UI is set to — a frozen machine-read schema whose values must not
depend on the operator's language setting.

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
