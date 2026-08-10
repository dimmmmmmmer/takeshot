# Changelog

Written for the person who has to use the thing on a shooting day, not for the
person who wrote it: what you will see that is new, what has changed under a
workflow you already have, and what is known not to work yet.

No dates here — the release page carries the day each version was published.
`scripts/release-notes.sh` lifts a version's section out of this file and posts
it as the body of that release, together with a measured description of the
download itself (which vendor SDKs that particular build was made against, and
how it was signed). That part is not written here on purpose: it is a fact
about the machine the artifact was built on, and it would go stale the first
time a build came from somewhere else.

## 0.2.0

The first published build. Everything below is new to anyone whose last copy
of TakeShot was hand-built before this.

### Read this before you roll

**What lands in the file changed.** The whole colour path was rebuilt around
one rule: the picture you judge and the picture you deliver answer to different
questions, so they are now produced separately from the same wire frame. Two
consequences you will meet.

- Your monitor is unchanged in intent but exact now: nominal black sits on 0 and
  nominal white on the top of the scale, at every bit depth and in both colour
  spaces. If you were looking at blacks that sat a few per cent up the scale,
  that was the bug, and it is gone.
- The recorded file carries the **wire's own codes** — nothing the display does
  can reach it. For a YCbCr take that is ordinary video-range footage and every
  tool already knows what to do with it. For an **RGB 4:4:4** take the file is
  studio-swing R'G'B' with no standard way to say so, so TakeShot writes a
  private key beside it and expands it on playback itself: inside TakeShot the
  take looks like the monitor did while it was recording, and in another
  application it needs the usual once-only 64–940 expansion. Say so when you
  hand RGB takes over.

Takes shot on an older hand-built copy have different levels baked in. When you
compare live against playback, compare against a take made with **this** build
— an older one is not evidence of anything.

**10-bit is now the default, and 4:2:2 signals are captured as `v210`.** Any
signal the board does not flag as RGB 4:4:4 — the ordinary professional SDI
case — is now taken at 10-bit YCbCr instead of 8-bit. Two bits the cable was
already carrying used to be thrown away by the driver. Expect larger files.
12-bit RGB is available as an opt-in for RGB 4:4:4 sources only; there is no
12-bit YCbCr wire format, so a 4:2:2 signal set to 12 is still captured at 10.
If the board refuses the depth you asked for, the app says so on screen and the
diagnostics report carries the depth actually enabled — it will not silently
give you something else.

**The phone camera grid moved from `/multiview` to `/cameras`.** A phone with
the old address bookmarked gets a 404. Re-scan the QR code in Settings; the
operator remote at `/` and the script page at `/script` are where they were.

**Downloads cannot see a capture board.** The published build is made on a
machine with none of the vendor SDKs on it, because none of them may be
redistributed — so it opens, plays back, exports and runs its built-in demo
camera, and it records nothing from a DeckLink. Every release page states which
bridges that build has; to capture, build from source with Blackmagic's SDK
(`CONTRIBUTING.md`). Nothing about this changes with a future signed build; it
is about the SDK, not the signature.

**First launch needs a right-click → Open.** Builds are ad-hoc signed, not
signed with a Developer ID and not notarized, so a double-click gets you
Gatekeeper's refusal instead of the app.

### New on the shot floor

- **Digital slate** — a fullscreen card with a giant running timecode and the
  rolling take's name, to point a camera at. Click or hit Space for a white
  sync flash.
- **Chroma key** for the monitor: pull the green screen with an eyedropper,
  tolerance, softness and spill control, and put a checkerboard, a colour or a
  still behind the actor. Preview and hardware monitor only — the take, the
  grabs and the exports keep the original picture, deliberately.
- **Difference compare** joins wipe, blend and A/B: the per-pixel difference of
  the two sources with a ×1/×4/×16 gain, for the mismatch that is too small to
  see any other way.
- **Sync-play**: select two to four takes and play them in one transport-locked
  grid, aligned either from each take's first frame or on the timecode they
  share.
- **Menu bar item** (off by default): the recorder's state and the running
  take's timecode stay visible, and stoppable, with the main window closed or
  behind another application.
- The app keeps to **one window per thing**. A second launch hands off to the
  copy already running instead of opening a second recorder against the same
  board.
- **Sound from the cart.** A USB audio interface can be the take's sound
  instead of the board's embedded audio. Off by default; if the interface is
  missing at launch or is unplugged mid-shoot, it falls back to embedded audio
  and tells you.

### New for the phone on set

- **Script supervisor's page** at `/script` — the day's take log, live, with
  good/bad and a comment typed straight into the take.
- **Camera grid** at `/cameras` — every board's live signal as tiles, each
  labelled and with its own REC light. It is the live signal, not the takes,
  and no encoding happens at all unless somebody has the page open.
- Both sit behind the same PIN as the operator remote, and the remote is still
  off until you switch it on.

### New at wrap

- **Dailies**: batch-transcode the day's takes to H.264 with timecode, clip
  name, project and camera burned in. The queue pauses itself while a take is
  recording.
- **Contact sheet**: the day as one PDF of poster frames, one cell per take,
  with the shift report's header on every page.
- **Scene, shot and take** are recorded per take beside the rating and the
  comment, written into the file and into the sidecar CSVs — so the script
  supervisor's numbering reaches post, and a correction typed after the fact
  reaches it too.
- **Camera cards are noticed.** Plug one in and the takes panel says what it
  found and offers to offload it — Offload, Ignore or Never. Nothing is ever
  copied without that answer, and you are never asked during a take: a card
  mounted mid-roll waits until the take closes.

### New when something is wrong

- **Collect diagnostics** (Help menu) writes a folder to the Desktop describing
  what the app can see: the build, the board, the Desktop Video version, the
  signal, the takes, the settings. Nothing is uploaded anywhere, the remote PIN
  is dropped and your home directory is written as `~` — but project, scene,
  roll and take names are kept, and the report says so at the top. Attach it to
  a bug report and the first three questions are already answered.
- The build's own version and commit are stamped into the app, so a report can
  say exactly which build produced it.

### Also new

- **R3D playback**: RED clips, spanned ones included, developed to Rec.709 with
  the camera's metadata and edge timecode. Also needs a build made against
  RED's SDK.

### Known limits

- **`v210` has never run against a board.** The 10-bit YCbCr path — now the
  default for every 4:2:2 signal — was built and measured against synthetic
  frames and through a real ProRes encode, but the rig it was written on feeds
  the board RGB 4:4:4 over HDMI, so no YCbCr signal has ever reached it. It is
  the single largest untested surface in this release. Shoot a test roll and
  check it before a job depends on it.
- **12-bit RGB is opt-in and its range is unconfirmed.** The SDK and CoreVideo
  both describe `R12B` as full-range 0–4095; whether a board actually puts
  studio-swing codes in it has not been measured on hardware.
- **R3D needs RED's SDK at build time.** Without it an `.r3d` is recognised and
  reported as unsupported rather than silently ignored.
- **`.braw` playback needs Blackmagic RAW installed** — the free player
  installs the runtime — and a build made against the Blackmagic RAW SDK.
- **Ad-hoc signing means TCC grants do not stick.** Every build has a different
  signature, so macOS treats each one as a new application and asks for its
  permissions again. Nothing is lost by it; it is a nuisance until the project
  has a Developer ID.
- **The chroma key never reaches a deliverable.** It is a monitoring tool. If
  you need the key in the file, it is not this.
- **A demo camera is always in the device list.** It is how the app is
  exercised without a board, and on a build with no DeckLink SDK it is the only
  device there.
