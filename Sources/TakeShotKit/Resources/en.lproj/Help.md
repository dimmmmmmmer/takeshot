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
- Limited also CLIPS: codes below 16 and above 235 (64 and 940 in 10-bit) —
  the sub-blacks and super-whites a camera legally sends — stop existing, on
  screen and in the recorded file. Choose **Limited, preserving excursions** if
  the grade needs them; it expands the camera's whole legal swing instead, at
  the cost of a very slightly flatter picture. The default does not change.
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
  content** — a video type glyph and its length, a photo glyph and its pixel
  size. They can be played and they carry markers and in/out points like a take;
  what they do not carry is a rating, which belongs to the Resolve metadata
  table and that table is about takes.

## Slate (scene, shot, take)

- The **SLATE** chip in the footer holds the creative metadata of the NEXT
  take: scene, shot and the take number inside that scene. Click it to type.
- The take number follows the clip counter until you type one; from then on it
  is yours, and it restarts at 1 whenever the scene changes. Clearing the field
  hands numbering back to the clip counter.
- Scene, shot and take are written INSIDE the recorded .mov, so a file copied
  without its sidecars still knows which scene it is. They also go into the
  ALE, the shift report, the contact sheet and the `takeshot-slate.csv` sidecar
  beside the footage.
- To fix a take that has already been recorded, open the speech-bubble button
  on its row — scene, shot, take, description and comment are all editable
  there, and so are they on the script supervisor's remote page. **A recorded
  file is never rewritten**: the correction is saved to the sidecar and travels
  through the log and the exports. That is deliberate — the footage is camera
  original, and the offload's checksums are taken over it.
- The digital slate window shows scene/shot/take on its card, so a camera
  pointed at it records the same values the file carries.

## Review

- **Rating**: click the circle on a take to cycle unmarked → good → bad →
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

Wipe, blend, difference or side-by-side. The other side is either the live
signal or another take with a synced transport; a still can be pinned as the
reference instead. Drag the seam to move a wipe. Difference shows per-pixel
|A−B| — identical framing reads as pure black — with a ×1/×4/×16 gain to make
small mismatches visible; it measures the clean signal, so the preview LUT
never bends it.

## Scopes and assists

- Waveform, RGB parade, histogram and vectorscope, as an overlay over the player
  or in a window of their own.
- On a 10-bit RGB source the scopes measure the signal ON THE WIRE, before the
  levels stage touches it — a WIRE badge in the toolbar says so. That is why the
  trace can sit below 0 % and above 100 %: those shaded bands are the camera's
  excursions, and seeing them is the point. Everything else is measured on the
  frame you are looking at, preview LUT included.
- Exposure assists: false color and EL Zone, zebra with a threshold, focus
  peaking.
- Framing: framelines with a chosen aspect, action and title safe areas,
  anamorphic desqueeze.
- **Punch-in** magnifies the center for a focus check; drag the image to pan.
- **Chroma key** shows the actor against the intended background instead of the
  cyc. Take the screen color off the picture with the eyedropper — a lit green
  is nowhere near the digital green a preset can offer — then dial in tolerance,
  softness and spill suppression. Behind the actor goes a checkerboard, a solid
  color, a still plate from disk, or the matte itself in black and white, which
  is how a key is actually judged.
- The key is on the viewer AND on the hardware monitor the director is watching,
  because both mirror the same display frame. It is in no take, no grab and no
  export — those come off the picture before the key is applied.
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
  ticked for a good take, cleared for a bad take, and left EMPTY for a take
  nobody has rated yet. Bad takes also say so in Comments, as `Bad` or
  `Bad: your note`. Logs written by older builds spell that marker `NG`; both
  spellings are read back, so an older day's ratings still come home.
- `takeshot-markers.csv` — one row per marker: file name, timecode, color, note.
  The timecode is the position; there is no separate seconds column. Markers on
  Other content live here too, positioned from the start of the clip.

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

Copies an arbitrary folder — a camera card, a sound roll — to one or several
destinations in a single pass: every file is read once, hashed on the way
(xxHash64, the checksum every DIT tool re-verifies against), and each copy is
verified by re-reading it from the destination disk. The source's own folder
name is preserved inside every destination. A file that does not verify is
reported; a run is never reported as done with an error inside it.

Every copy gets its own **report**, in the root of the copy: a picture to hand
over and the same thing as plain text to search, both stating the files, bytes,
times, speed and the one verdict line. The **checksum list** (`ascmhl/…mhl`, an
ASC MHL manifest) sits in its own folder beside it, which is where Silverstack,
OffShoot and `ascmhl` look for it when they re-verify the disk months later.

The sheet can be closed while a copy runs. The job carries on and reports
itself in the takes-panel strip — percentage, the file in flight and Stop —
and clicking that strip brings the sheet back. The sheet also opens showing the
last twenty offloads made from this Mac, so "have I already copied this card?"
has an answer before anything is picked; clicking a row shows that copy in the
Finder. Under it are the cards the app has stopped asking about — copied, or
answered with Never — and any of them can be cleared to be asked about again.

**Check a disk copy…** (in the offload sheet's own footer and in the File menu)
is the reverse: point it at a copy made earlier and it re-reads every file
against the newest checksum list on that disk, reporting what verified, what
mismatched, what is missing and what is a stray.

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
- `⌘B` — bad take (the last take)
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
