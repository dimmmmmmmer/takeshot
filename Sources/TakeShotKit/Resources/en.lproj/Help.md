# TakeShot help

Records a camera feed through a Blackmagic DeckLink/UltraStudio, splits it into
takes by the camera's REC state, names the files from metadata, and gives you a
review layer on top.

## Device and signal

- The capture device is chosen in **Settings**, not in the main window. Capture
  starts as soon as a device is selected — there is no separate start button.
- Above the player: timecode on the left, resolution and frame rate on the
  right. A missing badge means no signal is arriving.
- **Input levels** state what the SOURCE sends. Limited (16–235) is expanded
  once; Full passes through untouched. Auto assumes limited for RGB 4:4:4 HDMI,
  which is what cameras send.
- RGB 4:4:4 sources are captured as 10-bit by default. Turn that off in Settings
  if the board or the disk cannot keep up.
- **Forced input mode** overrides autodetection for a source whose format the
  board reports wrongly.
- **Timecode source**: RP188 from the video stream, or LTC decoded from an
  embedded audio channel.
- The demo source is hidden unless the app is launched with `--demo` (or
  `TAKESHOT_DEMO=1`). It generates a 1080p25 signal with running timecode so the
  whole take path can be exercised without a board.

## Take detection

Set the mode in Settings → Take detection. Clicking the timecode badge above the
player switches it too.

- **VANC trigger only** (default) — a take starts on the camera's record
  trigger in the VANC data. Running timecode alone never starts a take: a
  Resolve playout feeding the board runs timecode all day.
- **Auto (VANC + timecode)** — the trigger, plus timecode that starts moving.
- **Running timecode only** — for cameras in Rec Run with no usable trigger.
- **Manual only** — the REC button in the app and nothing else.

Two settings temper the detector: the **debounce** frames confirm a start or
stop before it is acted on, and **pre-roll** keeps frames in memory so the take
begins before the camera did.

While recording, the footage is protected: the file is written in fragments so a
crash or a power loss cannot cost the whole take, a mid-take format change or a
signal loss closes the take with an alarm that stays on screen until you clear
it, free space is watched (a warning under 5 GB, the take is closed under
0.5 GB), and a take that fails to finalize is left as `*_FAILED.mov` rather than
adopted into the list.

## Naming and the record folder

- Prefix (the project name), camera, roll and clip are edited in the footer.
  Changing the roll resets the clip number.
- The naming template is built from those fields plus a postfix and date/time
  placeholders. Presets live in Settings and in the footer's `Aa` menu.
- A warning appears before recording if the next filename is already taken.
- The record folder is picked in Settings or from the folder button. Video and
  photos in it that TakeShot did not record are listed separately as **Other
  content** — they can be played, but they cannot carry ratings or markers.

## Review

- **Rating**: click the circle on a take to cycle unmarked → good → NG →
  unmarked. Good takes are what the selects EDL exports.
- **Comment**: free text per take, kept in the metadata CSV.
- **Markers** flag a moment. In playback the marker lands under the playhead; while
  a take is rolling it is anchored on the running timecode and attached when the
  take finalizes. One marker per frame, so a held-down key cannot fill the
  sidecar. Markers carry a color and a note and become locators in the EDL.
- **Instant replay** plays the freshest take from the top, looping.
- **In/out points** on the transport set a loop range — the same beat, ten times
  in a row.
- **Grabbing a still** writes a PNG next to the takes. Stills are deliverables:
  the preview LUT is never baked into them.

## Compare

Wipe, blend or side-by-side. The other side is either the live signal or another
take with a synced transport; a still can be pinned as the reference instead.
Drag the seam to move a wipe.

## Scopes and assists

- Waveform, RGB parade, histogram and vectorscope, as an overlay over the player
  or in a window of their own.
- Exposure assists: false color and EL Zone, zebra with a threshold, focus
  peaking.
- Framing: framelines with a chosen aspect, action and title safe areas,
  anamorphic desqueeze.
- **Punch-in** magnifies the center for a focus check; drag the image to pan.
- Assists and LUTs are a display layer. Nothing they show reaches the recorded
  file unless "bake into recording" is on for the LUT.

## LUT and looks

Import a `.cube` lattice or an ASC CDL (`.cdl`, `.ccc`, `.cc`) and choose whether
it applies to the preview, to the recorded file, or both, with an intensity mix.
A CDL is converted to a lattice on import, so it travels through exactly the same
preview, bake and compare path a `.cube` does — and it keeps its slope, offset,
power and saturation, which the selects EDL writes out for the colourist. A file
recorded with the look baked in is tagged, and the player recognizes the tag so
the look is not applied twice.

## Exports

Two sidecars are kept up to date in the record folder as you work:

- `takeshot-log.csv` — the Resolve metadata table (File Name, Reel Name, Take,
  Good Take, Comments). Import it in Resolve with Media Pool → Import Metadata;
  it matches on the file name. The Good Take column is a checkbox, so it is
  ticked for a good take, cleared for an NG take, and left EMPTY for a take
  nobody has rated yet. NG takes also say so in Comments.
- `takeshot-markers.csv` — one row per marker: file name, timecode, color, note.
  The timecode is the position; there is no separate seconds column.

On demand, from the export menu in the takes panel or the File menu:

- **Selects EDL** — the good takes, cut back to back, with the markers as
  Resolve locators. When the active look is an ASC CDL, every event also carries
  `*ASC_SOP` and `*ASC_SAT`, which is how the grade reaches the colourist.
- **Avid log (ALE)** — every take, for a Media Composer bin: reel, start, end,
  duration, rate, take, scene, the Good Take flag and the comments. The reel is
  the same one the EDL writes, so the two join up.
- **Shift report** — the full table for production paperwork, as a PDF with
  thumbnails or as a CSV.

Takes moved out of the folder leave the panel but stay in the log: the normal end
of a day is the DIT moving footage into the archive, and that must not erase the
day's ratings.

## Verified copy (offload)

Copies an arbitrary folder — a camera card, a sound roll — recursively, hashing
every file with SHA-256 on both sides and writing `offload-manifest.csv` next to
the copy. The source's own folder name is preserved inside the destination. A
file that does not verify is reported; it is never reported as done.

This is for originals. TakeShot's own takes do not need it — they are not the
original media. A separate **verified backup** folder can be set in Settings to
mirror every finished take and still as it is written.

## Windows and output

- The scopes, the VANC monitor and Settings each open in their own window.
- `F` puts the player fullscreen (`Esc` leaves); the takes panel can sit on
  either side.
- A DeckLink output can mirror the viewer to a hardware monitor, and a second
  screen can show the player alone.
- With two boards, a second camera records in sync with the first.

## Keyboard

Every binding below can be changed in Settings → Hotkeys.

- `⌘R` — start/stop recording
- `⌘G` — good take (the last take)
- `⌘B` — NG take (the last take)
- `⌘S` — grab a still
- `⌘E` — instant replay
- `M` — add a marker
- `⇧M` — remove the marker under the playhead
- `F` — fullscreen player
- `Z` — punch-in
- `⌃S` — scopes overlay
- `⌃L` — preview LUT on/off (with a LUT selected)
- `⌃A` — mute/unmute monitoring
- `⌃D` — DIM: monitoring at half level
- `⌃V` — switch record/playback
- `⌃I` — record the mix on 1-2 only, or every selected channel (not while a
  take is recording)

Menu items carry the shortcut only when the binding uses a modifier: a bare
letter in a menu would fire while you are typing in the naming fields.
