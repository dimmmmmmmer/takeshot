# Roadmap and feature status

Status of every feature in the app, and what is still open. Updated when work
lands, not when it is planned.

## Shipped

### Capture and recording
- DeckLink/UltraStudio input: format auto-detection, RP188 timecode, up to 16
  channels of embedded audio. Verified on UltraStudio 4K Mini and 3G Recorder.
- **10-bit RGB capture** (`r210`) for RGB 4:4:4 sources, on by default, with a
  record buffer precompensated for the encoder (see CLAUDE.md → Color pipeline).
- Auto-takes from the camera's REC state (VANC trigger by default; TC-run and
  manual modes available), pre-roll buffer carrying **picture and audio**.
- ProRes Proxy/LT/422/HQ and H.264/HEVC; per-take timecode track, with a second
  tc32 sample written when the camera's Rec Run starts mid-take so the overlap
  conforms frame-accurately against the camera original.
- **LTC timecode source**: SMPTE 12M decode from a selectable embedded audio
  channel when RP188 is absent.
- Name templates, roll/clip stepping, collision warning, Resolve-compatible
  metadata CSV.
- **Multicam**: every additional DeckLink board records in sync on one REC.
- Recording-integrity rules (fragmented files, take closed on format change or
  signal loss, sticky alarms, disk-space watch) — listed in CLAUDE.md.

### Playback and review
- Unified viewer surface: live, AVPlayer video, stills and RAW all render
  through the same Metal path, so rec and playback are pixel-identical.
- **BRAW** playback (Blackmagic RAW SDK bridge) and **CinemaDNG** folders
  (a reel plays as one clip). R3D is recognized with a clear "SDK not
  integrated" message.
- Transport in timecode, in/out loop range, instant replay of the last take.
- Compare: wipe (vertical/horizontal/diagonal), blend, A/B — against the live
  signal, a **pinned reference** still, or **another take** (slaved player).
- Scopes: waveform, RGB parade, histogram, vectorscope — overlay or separate
  window, channel modes, 100/1023 scales, brightness controls, drag-reorder.
- Viewing LUTs (.cube) for preview and/or baked into the recording, mirrored
  into the DaVinci Resolve LUT folder on import.

### Operator tools
- Exposure assists: false color, EL Zone, zebra (adjustable threshold), focus
  peaking (adjustable gain) — stacking, with an on-screen color legend.
- Framelines (1.85/2.00/2.35/2.39/4:3/9:16), safe areas nested inside them,
  anamorphic desqueeze (1.33/1.5/1.8/2×), punch-in 2×/4× with drag-to-pan.
- **Hardware monitor output**: the viewer mirrors to a DeckLink SDI/HDMI out.
- Markers with timecode during recording and playback: colors, notes,
  navigation, deletion, clear-all; hotkeys throughout.

### Exports
- Selects EDL (CMX 3600) from good takes, markers as locators.
- Shift report as A4 PDF (thumbnails, TC in/out, ratings, notes, markers) and
  as CSV.
- **Verified offload** of an arbitrary folder (camera card, sound): recursive
  copy with SHA-256 on both sides, read-back through `F_NOCACHE`, CSV manifest.

## Open

### Needs something from outside the repo
- **R3D (RED)** — the decoder is scaffolded and the format recognized; needs
  the REDCODE SDK from <https://www.red.com/developers> (free registration)
  dropped into `vendor/` to be integrated like DeckLink and BRAW.
- **ProRes RAW** — unverified. Recent macOS decodes it system-side; drop a
  ProRes RAW .mov in the record folder and try to open it. If AVFoundation
  takes it, the feature already works; if not, it needs its own path.
- **Stable code signing** — ad-hoc signing changes the cdhash on every rebuild,
  which kills TCC grants (camera/disk access) and hangs first launch. Needs an
  Apple Developer ID certificate; the bundle script is ready for it.
- **Hardware verification** still outstanding: LTC against a real generator,
  multicam recording on both boards at once, hardware output on a monitor,
  offload from a real camera card.

### Planned features
- **Web remote control** — phone-friendly page over an embedded HTTP server:
  REC/stop, instant replay, marker, rating, live status.
- **NDI output** — the viewer as an NDI source for iPads on set (the NDI SDK
  is free; the send path is a straight frame push from the display queue).
- **VANC metadata beyond the REC trigger** — Blackmagic camera-control packets
  (DID 0x51/SDID 0x53) carrying reel/scene/take for automatic naming. The one
  originally planned MVP item never built.
- **CDL grading** with `.cdl` export (deferred by the operator).
- **Chroma key preview** with a plate (deferred by the operator).

### Engineering debt
- **`TakeShotKit` on Swift 6** — `CaptureCore` migrated; the app layer is still
  Swift 5 (about 61 errors at last count: main-actor sending and app-level
  global state).
- **SwiftLint** — runs locally through `scripts/lint.sh` and in CI with
  `--strict`, so the tree cannot regress.
- **Codacy** — grade A, coverage ~62%; duplication is the remaining lever.
