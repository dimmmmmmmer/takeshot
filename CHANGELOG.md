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
  share. **The grid goes out with you**: the hardware monitor, the SDI output,
  NDI, SRT and every phone watching all show the comparison, not the single
  take that was open before you started it. Same on the fullscreen player and
  on the director's second display, which used to draw that parked take frozen
  on its last frame — so a client watching a comparison saw a still and had no
  way to tell. Close the comparison and the take you had open comes straight
  back; close one you opened with nothing loaded and the output goes black
  rather than holding the last four-up frame.
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
- **A chromaticity chart** joins the waveform, parade, histogram and
  vectorscope: CIE 1931 xy with the spectral horseshoe, both gamut triangles
  and D65 drawn on it. It reads the signal's OWN primaries, so a Rec.2020
  camera's colours sit in the 2020 triangle and you can see at a glance what
  will move when the day is delivered to a Rec.709 master.
- **The scopes read the signal's own matrix.** Rec.2020 codes luma with
  different weights than Rec.709, so on a 2020 signal the waveform used to read
  saturated greens too dark, and the vectorscope's colour-bar boxes sat about a
  box-width off. Both follow the signal now. Nothing changes for a Rec.709
  camera — that is pinned to four decimal places.
- **The vectorscope is sharper.** Each sample is placed between cells rather
  than rounded into one, so the trace lands where it actually is. The most
  visible consequence: a neutral frame now sits exactly on the centre instead
  of half a cell off it.
- **The scopes window makes a square grid** instead of a row of thin slivers
  when the window is wide.
- **Pre-roll can be typed in seconds** as well as frames, and the reading shows
  both — "12 frames · 0.5 s at 23.976" — so the number you set means the same
  thing whatever the camera is running at.
- **The channels that carry sound are the channels that get recorded.** A
  camera embedding a stereo pair no longer opens a sixteen-channel track with
  fourteen silent ones. It is measured, not guessed, during standby, and the
  panel says whether the choice is the app's or yours — click any channel to
  take it over.

### New for the phone on set

- **Script supervisor's page** at `/script` — the day's take log, live, with
  good/bad and a comment typed straight into the take.
- **Camera grid** at `/cameras` — every board's live signal as tiles, each
  labelled and with its own REC light. It is the live signal, not the takes,
  and no encoding happens at all unless somebody has the page open.
- **Live video at `/live`**, over WebRTC rather than a stream of JPEGs — and
  the phone chooses what it watches: the monitor picture with your aids and
  framelines on it, the clean camera, or the multi-camera grid. Each picture
  somebody is actually watching costs one encode and no more; two people
  watching the same thing cost one between them, and an empty page costs
  nothing at all.
- Both sit behind the same PIN as the operator remote, and the remote is still
  off until you switch it on.

### New at wrap

- **Dailies**: batch-transcode the day's takes to H.264 with timecode, clip
  name, project and camera burned in. The queue pauses itself while a take is
  recording.
- **Dailies of an HDR take are tone mapped**, through the same curve the player
  uses — so a PQ or HLG take comes out of the batch looking like it looked
  while you were watching it, instead of dark. Measured: diffuse white lands
  where the monitor put it rather than at 148 of 255.
- **A note on a take reaches the paper.** The shift report used to lay comments
  out in the width left over after the other columns, which was about sixteen
  characters, cut mid-word. A note is now a line of its own under the take,
  running the full width of the page.
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
- **A take abandoned by a crash or a power cut opens.** The app was already
  writing the file in fragments so that this would be true, and it was not:
  a fragment is only released once every track has data past it, and the
  timecode track was written at the end. It is written as the take runs now,
  and so is silence on an audio track the board declared and never fed —
  measured on a 13-second abandoned take, 10 seconds come back with picture and
  sound where none of it did before.
- **A camera that stops sending without saying so closes the take.** A wedged
  board stays in the device list, raises no error and simply stops calling
  back; one second of silence now ends the take the way a real signal loss
  does, instead of leaving a recording that is not recording.
- **A source that changes its channel count mid-take no longer costs the rest
  of the shot.** The sound is conformed to what the take opened with, the take
  keeps rolling, and the alarm and the log row say it happened.
- **A very long name cannot lose a take.** A project name plus scene, shot and
  take could exceed what the file system accepts, and the take then did not
  open at all — with the camera already rolling. Names are now shortened to fit
  and kept unique.

### Also new

- **SRT output**: the mirrored viewer — aids, framelines and chroma key
  included — encoded as H.264 in an MPEG-TS and sent to an address on the set
  network. VLC on a director's laptop, OBS, a Resolve station, a cloud gateway:
  anything that takes an `srt://` URL. Either end can dial, which is what makes
  it work behind a venue's router in both directions, and there are four things
  to set: where, how much of a bad link to ride out (the latency), how many bits
  the link can carry, and an optional AES passphrase. **If the link dies it comes
  back by itself**, which on a venue network is the normal case rather than the
  exception — the status row says so and keeps trying, and none of it can touch a
  take. Needs a build made against libsrt (see the limits below).
- **NDI output**: the same mirrored viewer announced as a source on the set
  network, for a director's iPad or a client feed, with no second cable and no
  second board output. It sits BESIDE the SRT output rather than replacing it,
  because the two answer different rooms: NDI announces itself and a receiver
  picks it out of a list, so there is a switch and a name and nothing else to be
  on the wrong side of — which is the one to reach for when the receiver is on
  the same LAN. Both can run at once and neither can slow the other down. Needs
  a build made against the NDI SDK (see the limits below).
- **R3D playback**: RED clips, spanned ones included, developed to Rec.709 with
  the camera's metadata and edge timecode. Also needs a build made against
  RED's SDK.
- **In Russian, "unavailable" now explains itself in Russian.** Turn SRT or NDI
  on in a build that was made without that SDK — which every published download
  is — and the Settings row said "Недоступно" and then a paragraph of English
  underneath it. The same was true of the message the live page showed a phone.
  All of them are translated now. What is deliberately NOT translated is what is
  inside them: a shell command, a path, a file name and a library's name are
  things to type and places to look, and they read the same in both languages.

- **Your markers cannot be taken by the wrong menu press.** "Clear all
  markers" acted on whatever clip was last loaded, and the menu let you press
  it *while the camera was rolling* — so a clip left on screen from an earlier
  review could lose every flag on it, sidecar and all, with no grid and no
  warning. The three items that act on a clip's whole list now ask whether you
  are actually reviewing that clip.
- **Binning takes you were comparing ends the comparison.** "Compare four, bin
  the three that failed" used to leave the grid playing files that were already
  in the Trash.
- **Nothing writes to the take parked behind a comparison** — no markers, no
  grabs, and the scopes and the format badge stop describing it instead of
  quietly measuring a paused frame nobody is looking at.

- **Every tile says which take or camera it is.** The name, a red REC dot and
  the tile's own running timecode are drawn into the picture rather than over
  it, so they reach the director's monitor, the SDI output, NDI, SRT and the
  phone — all of which used to show anonymous rectangles. The comparison grid
  now carries a timecode PER TILE, which the camera page never did.

### Known limits

- **A comparison carries no assists and no LUT — on your screen or on anyone
  else's.** Sync-play's tiles have never had a false-colour, a zebra, framelines
  or a viewing LUT, and the picture the hardware output and the streams now
  carry is exactly those tiles. So the director sees precisely what you see,
  which is the point — but neither of you can meter a take inside a comparison.
  The scopes say they are waiting rather than measuring, and the tile labels and
  running timecodes are on your screen and not in the composed picture, so a
  monitor at the far end shows four takes and no names. Use the single player
  for anything you have to judge exposure by.

- **The SRT output has never been watched by a real receiver.** The transport
  stream is checked byte for byte, the encode is measured through a real decode,
  and the handshake and the socket options are exercised against real libsrt over
  the loopback — but nothing has yet put VLC or a gateway at the far end of a real
  network, so the picture coming up correctly on somebody else's machine is the
  one claim still untested. Try it before a job depends on it.
- **SRT needs libsrt at build time**, and installed to send. Unlike the camera
  vendors' SDKs it is MPL-2.0 and needs no registration — `brew install srt`.
  Without it the feature reports itself unavailable in Settings and says how to
  get it.
- **NDI needs the NDI SDK at build time** (version 4 or newer), and an NDI
  runtime installed to send — NDI Tools is enough. Without it the feature
  reports itself unavailable in Settings and says so in a sentence rather than
  asking you to rebuild anything. **Nothing about the NDI output has been
  watched by a real receiver in this build either**, for the same reason as
  SRT and one more: the machine it was written on has the runtime and not the
  headers, so the bridge compiles as a stub there and the half that talks to
  NDI has never executed. Try it before a job depends on it.
- **No browser has ever decoded the live video.** The offer and the answer are
  checked against a real Chrome offer captured off this machine, the RTP
  packetising is checked byte for byte, and the page is checked — but nothing
  has yet put a phone on a set network and seen a picture. If it gathers and
  never connects, the first thing to look at is that Chrome sends `.local`
  candidate names rather than addresses. Try it before a job depends on it.
- **Live video needs libdatachannel at build time.** A published build carries
  it inside the app; a build made from source does not unless you build the
  library too, and the page then says so and stops asking. The camera grid at
  `/cameras` keeps working either way, which is why it is still there.
- **The SRT output carries sound; the NDI one still does not.** The SRT stream
  now has a stereo audio track on it: the same two channels the cart's speakers
  play, which are the first two of whatever is being RECORDED — your channel
  mask, or the channels the app measured as carrying during standby. There is no
  switch for it and it does not depend on the speakers: turn the cart's monitors
  down and the director's laptop keeps its sound. If your mask leaves one channel
  enabled the stream is mono rather than that channel twice.
  **Nobody has watched it on a real receiver.** The two streams are timestamped
  off one clock and the arithmetic is checked, but how far the sound sits from
  the picture on a decoder has not been measured — check it before a job depends
  on lip sync. NDI is still picture only: the shared half is built and the NDI
  half of it cannot even be compiled on a machine without the SDK headers.
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
