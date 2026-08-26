# TakeShot help

Records a camera feed through a Blackmagic DeckLink/UltraStudio, splits it into
takes by the camera's REC state, names the files from metadata, and gives you a
review layer on top.

## Device and signal

- The capture device is chosen in **Settings**, not in the main window. Capture
  starts as soon as a device is selected — there is no separate start button.
- Above the player: timecode on the left, resolution and frame rate on the
  right. A missing badge means no signal is arriving.
- **Input levels** state what the SOURCE sends. Limited is expanded once; Full
  passes through untouched. Auto assumes limited for RGB 4:4:4 HDMI, which is
  what cameras send.
- Limited expands the camera's WHOLE legal swing (4–1019 in 10-bit), so the
  sub-blacks and super-whites it rides outside 64–940 are still there for the
  grade. There was a second Limited that clipped them away; it is gone, and a
  saved setting that named it now reads as Limited.
- **Bit depth follows the signal.** The board's format detection reports what
  the source is sending, so there is nothing to set: a 12-bit RGB 4:4:4 camera
  is captured as 12-bit R12B, everything else at 10-bit (r210 for RGB 4:4:4,
  v210 for YCbCr 4:2:2). Ten is a floor, not a ceiling — an 8-bit source is
  still captured at 10 so its sub-blacks and super-whites reach the file.
  You are told when the signal puts you on 12-bit, and told again if the board
  could not open the depth the signal is sending.
- A 12-bit signal recorded with a 4:2:2 codec is subsampled on the way in.
  ProRes 4444 is the only codec that keeps it.
- **Forced input mode** overrides autodetection for a source whose format the
  board reports wrongly.
- **Timecode source**: RP188 from the video stream, or LTC decoded from an
  embedded audio channel. The channel list is the channels the CURRENT signal is
  carrying — up to 16 on SDI. With no signal there are no channels to offer; a
  channel you had chosen that the signal does not carry stays in the menu,
  marked, rather than being silently swapped for another one.
- The demo source is always in the device list. It generates a 1080p25 signal
  with running timecode, so the whole take path can be exercised without a
  board — and in a build made without the DeckLink SDK it is the only source
  there is.
- If a board is connected and never appears, Settings says why under the device
  picker: this build has no DeckLink SDK in it, Desktop Video is not installed,
  or the framework was refused at load. Nothing is said when the build can see
  boards — an empty list then means what it says.

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
begins before the camera did. Pre-roll can be typed in frames or in seconds,
whichever you think in; what is stored is always the frame count, converted at
the rate the signal is running, and both readings are shown under the field. A
value entered on one signal does not change when the next one runs at another
rate — a frame count is an answer that stays true.

**REC indicator on the picture** is a third trigger, and it is a switch beside
the mode rather than another entry in it: it composes with all four, and it is
the one that works on a camera which sends no VANC at all. Cameras put their own
UI on the monitoring output, so the record indicator on screen can drive the
take. Nothing recognises anything — you teach it, in four steps:

- **Mark on picture** draws the box on the live image; a click moves it onto the
  indicator. The box is stored in the signal's own coordinates, so punching in
  or desqueezing cannot move it off the thing it is watching.
- **Box size** sets how much around the indicator is watched. Keep it tight: the
  smaller the box, the less of the frame can walk into it.
- **Learn rolling** while the camera is rolling, **Learn idle** while it is not.
  The panel then shows how far apart the two came out and what the box is reading
  right now — check it says *rolling* while the camera rolls before you trust it.
- **On.** It refuses to switch on until the two references are far enough apart
  to be told apart, and it is never on by default.

A blinking indicator needs no special setting: the stop confirm frames above are
counted in the readings the watcher takes, a few per second, so the confirm the
detector already uses rides out the dark half of a flash. Nothing about the box
reaches a file, a grab or an export — it is measured and nothing else. While a
take rolls, the REC mark over the player says which trigger started it, and the
diagnostics bundle reports the same.

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

- **SCENE / SHOT / TAKE** sit in the footer under the file-name fields and hold
  the creative metadata of the NEXT take. Type into them, or page them with the
  ‹ › arrows beside each: the arrows step the number at the end of the value, or
  the shot letter — 12 → 13, 12A → 12B — and stepping back off the first value
  empties the field again. A scene you have typed a note into is left alone and
  the arrows go grey; type that one.
- The take number follows the clip counter until you set one; from then on it
  is yours, and it restarts at 1 whenever the scene changes. Emptying the field
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
  pointed at it records the same values the file carries. The web remote serves
  the same slate to a phone (Settings → Remote → Page → Slate), which is the one
  that can actually be held in front of the lens. Tap it for the sync flash. Its
  timecode counts between the app's updates and freezes VISIBLY — amber and
  tagged — the moment it stops being confirmed, so a stopped clock can never be
  mistaken for a running one. Set the phone's Auto-Lock to Never.

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
- **"Bake into recording"** is the exception, and it changes what a take IS. The
  next take is written as a composite: the screen is replaced in the file, so the
  footage cannot be re-keyed and is not camera original. The scopes go on
  measuring the camera rather than the file — which is still the right thing to
  expose against, because the plate was never on the wire. A take opened with the
  bake on finishes that way whatever you touch mid-take, and one opened without it
  stays clean; the file itself says which it is.
- Assists and LUTs are a display layer. Nothing they show reaches the recorded
  file unless "bake into recording" is on — for the LUT, or for the chroma key.

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

**If a disk is lost mid-copy**, the ones still connected finish and that disk's
own report says what happened to it. Plug it back in, pick the same card and the
same destinations, and press Start: TakeShot reads the checksum list already on
that disk, tells you how much of this card it holds — "400 of 900 files are
already there" — and waits for you to agree before it skips anything. Agreeing
does not take the list on trust: each of those files is read back off the disk
and its checksum compared before it counts as done, and anything short, wrong or
missing is copied from the card again. A disk that already finished is not
written to at all, and the checksum list every disk ends up with describes
everything on it, not only what moved that time. The other answer — copy the
whole card — is always on the same panel. Resuming reads the disk instead of
reading the card and writing the disk, so it is roughly three times less work;
on a card that has been shot on since, or a disk whose copy came from a
different card, it is refused and says which.

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
original media.

## Windows and output

- The scopes, the VANC monitor and Settings each open in their own window.
- `F` puts the player fullscreen (`Esc` leaves); the takes panel can sit on
  either side.
- A DeckLink output can mirror the viewer to a hardware monitor, and a second
  screen can show the player alone.
- With two boards, a second camera records in sync with the first.

## SRT output

Sends the same picture the hardware monitor gets — aids, framelines and chroma
key included — over the network instead of down a cable, to VLC or OBS or a
Resolve station or a cloud gateway. Off by default.

- **Connection** is the only part of this that is not obvious, and it is a fact
  about the venue rather than a preference. *Dial the receiver* when this Mac is
  behind a router and the receiver is reachable, which is the usual way round.
  *Wait for the receiver* when it is the other way round: TakeShot holds the port
  open and whoever wants the picture connects to it. The status row shows the
  `srt://` address to hand over either way.
- **Latency** is SRT's whole point. It is the buffer the far end holds, and it is
  the time SRT has to notice a lost packet and ask for it again — so it is how
  much of a bad network the picture rides out, paid for in delay. 120 ms is the
  standard starting figure and is right for a wired venue LAN; raise it on
  congested Wi-Fi or over the internet, where 4× the round-trip time is the rule
  of thumb. Below about 20 ms it can recover nothing and you have bought the
  delay for nothing.
- **Bitrate** is what the link can carry, which the app cannot know. 8 Mbit/s
  holds up on a face at 1080p. The stream costs about 5 % more than the number
  you set, which is the transport itself.
- **Passphrase** turns on AES. Ten characters or more, or leave it empty and the
  stream is unencrypted — worth thinking about on a venue's own network. The
  same passphrase goes into the receiver.
- Picture only: no audio, deliberately.
- **When the link dies it comes back by itself.** The status row says
  "Reconnecting" and why, and TakeShot keeps trying every one to five seconds.
  Nothing about it can touch a take — a receiver that has been closed all day
  costs nothing but the status row. What does NOT retry is a setting that cannot
  work at all (a port already in use, an address that resolves to nothing): that
  says "Could not start" and waits for you, because retrying would hide it.
- A receiver joining mid-shoot gets a picture within a second.

## Keyboard

Every binding below can be changed in Settings → Hotkeys → Edit. The editor
refuses a chord another action already holds, and names the one that has it.

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
