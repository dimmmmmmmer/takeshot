# Coverage

What the suite covers, how the number is measured, what holds it up, and what
cannot be covered at all from a headless run.

The reason any of this matters is on-set reliability: a bug found in the trailer
costs a session, and a bug found while the camera is rolling costs the take. The
number is a proxy for that, not the goal — a test that raises it without pinning
a behaviour defends nothing and makes the next refactor more expensive.

## Measuring it

```bash
scripts/coverage.sh                 # run the suite, export lcov, check the floor
scripts/coverage.sh --report-only   # reuse the profdata already in .build
scripts/coverage.sh --floor 90      # try a different floor for one run
```

The script writes `coverage.lcov` (what Codacy consumes) and
`coverage-report.txt` (the per-file table), then compares the measured line
coverage against the floor. Below the floor it exits non-zero and prints the
measured number, the floor, the gap, and the files holding the most uncovered
lines — which is where new uncovered code lands.

CI runs the same script (`.github/workflows/codacy-coverage.yml`), so the job and
a developer's machine cannot disagree about the number. The Codacy upload stays
`continue-on-error` because it depends on the repo being connected on
codacy.com; the FLOOR is the gate.

The run must be serial. `scripts/coverage.sh` goes through `scripts/test.sh`,
which passes `--no-parallel`, because the view tests share
`UserDefaults.standard` through `@AppStorage` and a parallel run has one test's
cleanup erase another's keys. Every red the coverage job ever showed traced back
to a parallel run.

## The floor

**`.coverage-floor`, and nowhere else.** One number in one file; raising it is a
one-line diff. It sits about a point and a half under the measured number on
purpose — a floor set at the exact measurement goes red on the first honest
refactor that adds an error branch nobody has a test for, and a gate that is red
the week it lands teaches everyone to ignore it.

| | |
| --- | --- |
| Floor | **88.0 %** lines |
| Measured | **90.70 %** lines (4 192 of 45 054 lines uncovered) |

Measured in the ORDINARY configuration, which is what `scripts/coverage.sh`
runs and what CI runs. `-DTAKESHOT_FORCE_STUBS=1` is a different build with
different reachable branches and is not what any number in this file refers to.

The NDI output's return moved it up by five hundredths of a point while adding
367 lines of measurable code, and for a related reason: the parts of it that do
not cover themselves are behind seams — `NDISending` for the sender,
`NDIFrameRate` as a value type so the one piece of real arithmetic needs no SDK,
no sender and no network. Its SOUND leg followed the same shape and moved the
figure up again, to 90.53 %: `NDIAudioMirror.planarFloat` is a static function
of a `CMSampleBuffer`, so the conversion — the only per-sample work in the
feature — is covered with no sender, no SDK and no network, and covered in BOTH
configurations.

What stays uncovered is `Sources/CNDI` (Obj-C++, so not measured at all). Note
that the reason has changed even though the number has not: the development
machine now has the SDK headers, so the real half of `CNDI.mm` is compiled and
executed here — `NDIRealBridgeTests` runs against the loaded runtime and
`NDILiveSenderTests` calls into it — but none of that appears in this figure,
because llvm-cov is not measuring that target at all. On CI the same lines are
dark for the older reason: no headers, so the stub is what is compiled.

Two runs of that same tree measured 4 125 and 4 126 uncovered lines — one line
of jitter, re-derived with `--report-only` off the second run's own profdata
before it was written down. The figure above is the second run's. A tenth of a
point of run-to-run noise is worth knowing about before somebody chases a
hundredth. It has not gone away and it is the same size: after the NDI sound
leg, two runs measured 4 201 and 4 197 uncovered — four lines, still under a
hundredth of a point, and the figure in the table is again the second run's.

The SRT output moved it up by six hundredths of a point while adding 1 263 lines
of measurable code, which is a fact about what SHAPE of code it is rather than
about how hard anybody tried: an MPEG-TS muxer is pure byte arithmetic with no
device behind it, so it covers itself. The parts of that feature which do not
cover themselves are the parts with a socket or a codec behind them, and they are
behind seams for exactly that reason — `SRTStreamSending` for the link,
`SRTVideoEncoder.isSupported` for the encoder. What stays uncovered is the same
residue as everywhere else: the Obj-C++ bridge (not Swift, so not measured at all)
and the branch of the bridge this build did not compile.

## What holds the number up: seams, not more tests

The residue is not "code nobody got round to". It is code that talks to a device,
a board, a modal dialog, or the menu bar — and the way to cover it is to put a
protocol or a replaceable handler in front of it, not to write a test that opens
the real thing. The codebase does this in several places and they all look the
same:

| Seam | Real | Fake | What it unlocks |
| --- | --- | --- | --- |
| `DuplicateLookPrompt.handler` | `NSAlert.runModal()` | a closure answering one of the three | re-importing a look that is already in the library |
| `CaptureBackend` | `DeckLinkBackendAdapter` | `MockCaptureBackend`, `SyntheticSignalBackend`, `StubCaptureBackend` | the whole capture session |
| `AudioInputDeviceProviding` | `SystemAudioInputProvider` | `FakeAudioInputProvider` | the USB input path |
| `VolumeWatching` | `WorkspaceVolumeWatch` | `FakeVolumeWatch` | the card watch |
| `FinderOpen.handler` | `NSWorkspace` | a recorder | which folder each button reaches for |
| `AudioRenderRoute` | `SystemAudioRoute` | `FakeAudioRoute` | the live monitor's timing and backlog |
| `PlayoutOutput` | `CDLPlayout` | `FakePlayoutOutput` | the hardware mirror's frame path |
| `PlayoutFeeder.factory` | the real feeder | one on a fake board | the output mode and its fallback |
| `FilePanel.saveHandler` / `.openHandler` | `NSSavePanel` / `NSOpenPanel` | `FakeFilePanel` | the four export documents and the four browse dialogs |

A seam concentrates the untestable part into a handful of named lines instead of
leaving it spread through the code that uses it. `FilePanel.swift` is 35 %
covered and that is the point: what is left uncovered there is `runModal()` and
the two lines that read its result, while the four exporters behind it went from
16 % to 94 %.

## The interruption wave

The wave that took the number from 87.95 % to 89.01 % went after the branches that
only run when a shooting day goes wrong, on the grounds that a bug in one costs
a take rather than a click. What it added, and what each one pins:

| Suite | The failure it exercises |
| --- | --- |
| `TakeInterruptionTests` | The cable out mid-take, the camera changing format mid-take, an input that wedges without raising any event at all, and a finalize that fails: the take is closed rather than left starving, the alarm is sticky, the file survives, the next take is a file of its own, and a take that could not be finalized never joins the list. The frame-arrival watchdog gets its negative half here too — it must say nothing while the app stands by between setups. |
| `PipelineTimecodeSourceTests` | A timecode arriving with no frame rate, and a camera that starts Rec Run after the take does — read back as the tc32 samples in the finished .mov, not off the writer. |
| `PipelineVancStatsTests` | The VANC monitor's tallies, the once-a-second publish rate, and the reset on capture stop. |
| `ControllerDestinationFailureTests` | The record folder moved out from under the app, a destination whose volume cannot be interrogated, a fresh folder that is created rather than alarmed about, quitting mid-take, and a board appearing on the backend callback. |
| `ControllerHardwareSurfaceTests` | The scopes window's placement, `WorkspaceVolumeWatch` driven by a hand-posted notification, and a decode of a file that only looks like BRAW/R3D. |
| `ModelHotkeyActionTests` | Every arm of the hotkey fan-out, asserted through the state the on-screen button changes. |
| `ControllerLookLibraryFailureTests` | A look that cannot be imported, clearing the library without taking bystanders, and a director's monitor that is no longer attached. |

Two production changes came with it, both stated in the code:
`CaptureController.diskVerdict` splits the two free-space thresholds out of the
watchdog tick that nothing can drive (the same split `bitDepthNotice` already
had from its reporter), and `TestWait.becomesTrue` gives the CaptureCore suites
the answering poll `ControllerWait.until` already had.

## The long-tail wave

The wave that took the number from 89.68 % to 90.35 % went after what the next
section calls "a long tail of view bodies, AppKit window paths and error
branches that are reachable with more work". Almost none of it was writing more
tests against the code as it stood.

**One part was a fixture that had never been right.** Every CinemaDNG folder the
suites built held files no decoder opens — enough for `RawPlayerModel.init` to
accept the folder and for the transport arithmetic to be measured, which is why
the RAW transport looked half covered while the decode loop sat at 43 % and its
scope path at 10 %. The only arm of that loop which had ever executed was the
failure one, reached by accident. `DNGSequenceSource` develops each frame
through `CIRAWFilter` with a plain ImageIO decode behind it, and CIRAWFilter
opens whatever ImageIO opens — so a PNG under a `.dng` name is a frame the
player really decodes. That is measured, and `RawClipFixtures` is it. Frames
carry a PATTERN rather than a level (index + 1 white columns), because a test
that can say WHICH picture is on screen is the only kind that catches the
playhead and the picture disagreeing; a level would not survive the develop,
which converts sRGB to Rec.709 and moves a flat grey by up to eleven codes.

What that unlocked is the half of review a DIT spends the day in: the picture
following the playhead, a decode failure REPORTED rather than pausing in silence
(which is exactly what reaching the end looks like — the operator reads "short
clip" where the truth is "bad card"), the last frame refusing to decode being
the end rather than a failure, the loop resuming at the in point, and the scope
cadence both while playing and on a paused clip.

**The rest was five decisions that lived where nothing could ask them.** Same
shape as `ScopeGridLayout.columns` and `PunchEventView.decide`: the rule comes
out as a function over its inputs, what stays unreachable shrinks to the reading
and the applying, and the coverage is a side effect. Three of the five found a
disagreement that was already there:

| Extraction | What it decides, and what it found |
| --- | --- |
| `HotkeyManager.outcome` | Whether the key under the operator's finger reaches the app or the scene name they are halfway through typing. The ORDER is now written down with the arms, including its consequence: Esc leaves a fullscreen surface before it cancels a combo recording, so a row armed while a fullscreen window is up stays armed until Esc is pressed a second time. |
| `CompareWipeGeometry` | Where the wipe seam is, and where a drag of its handle puts it. The handle and the seam are drawn by two different things in two different coordinate systems — SwiftUI top-left, Core Image bottom-left — and nothing held them against each other. The suite composes through the real `CompareCompositor` and checks the front image is on one side of the handle and the back on the other. |
| `CaptureController.transportBarKind` and `PlayerToastPlan` | Which bar is under the picture, and what the player says over it. **Already drifted.** `PlayerToast` carried a note saying a drifted copy of its inset is "the take-failed message hidden behind the play button"; the bar asked a careful question and the toast asked "is a clip loaded in playback", so over a still and over a sync-play grid the toast floated 42 points above a bar that was not there. |
| `ChromeReveal` | When a fullscreen window shows its chrome. Three strips spelled the rule out separately and in two different SHAPES — one against a bare number, two against a band measured off the view's own height — so nothing showed they were the same rule. The three bands are now three named constants twenty points apart, and that spread is itself a test. |
| `CaptureController.multicamPlan` and `deckLinkDevices` | Which board becomes which camera. The label goes through `NamingEngine` into the FILE NAMES, so a board that answered to a different letter between two sessions of the same shoot is a day of footage that will not sort. Three places spelled out "which of these is a board", and two of them have to agree or the badge is a lit button that adds no camera. |

Every suite here was checked by breaking the rule and watching the test name the
break: twenty-two mutations, of which twenty-one turned a test red — each by the
test that describes it, and, where the claim is narrow enough for that to mean
anything, by no others. The twenty-second is worth writing down for what it
showed rather than for what it caught:
`restartLoop(fromInPoint:)` going to frame 0 changes NOTHING on its own, because
`startOfPlayback` re-imposes the in point underneath it. That rule is defended
twice and either line alone is redundant; breaking both is what turns
`aLoopWithAnInPointResumesAtTheInPoint` red.

## The shared-rule wave

The wave that took the number from 90.55 % to 90.62 % started from the list the
long-tail wave left rather than from the report. Three of its four changes were
one shape — a rule that several surfaces each spelled out for themselves,
pulled into one place, where the copies could be compared for the first time —
and two of those three had already drifted.

Two runs of the finished tree measured 4 147 and 4 145 uncovered lines — two
lines of jitter, the same order the long-tail wave saw. The figure above is the
second run's, and both were re-derived from that run's own `coverage-report.txt`
rather than from a log. The starting figure was measured the same way on the
same machine, and it is NOT the 90.38 % this file carried before: the tree has
grown 1 279 measurable lines since that number was written down, so the honest
comparison is 90.55 → 90.62 and not 90.38 → 90.62.

**Read the point move before copying the method.** Seven hundredths of a point
for four changes is the smallest of the four waves in this file, and it is a
fact about the SHAPE of the work rather than about how much of it there was:
deduplicating a decision deletes lines from several places and adds one covered
function, so it lowers the denominator about as fast as it raises the numerator.
`RawPlayback+Transport` went 95 % → 100 % (6 lines), `TakeRowControls` moved 16
and `TransportBar` 6, `CaptureController+LUT` was at 100 % lines before and
after, and the three new files are 47 lines at 100 %. A wave that wants POINTS
should go after the view bodies and the AppKit paths; a wave that wants the
number to mean something should expect to find what this one found. Both are
worth doing and they are not the same afternoon.

| Extraction | What it decides, and what it found |
| --- | --- |
| `SlateTakeField` | What a TAKE field means, in both directions: typed text becomes a take number, a take number becomes the text the field shows. **Already drifted, three ways.** The same field is reachable from the footer, from the takes panel's popover and from the phone, and all three write the same `SlateMetadata.take` — into the .mov at `TakeWriter` time, and into `takeshot-slate.csv` and the ALE afterwards. `12345` was 9999 in the footer, 1234 in the popover (it kept the first four DIGITS) and 12345 on the phone; `12A` was 12, 12 and **0 — nothing logged**; `0` was **1**, 0 and 0. Two of the three are drawn by the SAME view (`SlateFieldsEditor`), which is why the control looked shared. The ceiling was three `9999` literals, one of them in `SlateStep`, whose comment already claimed the controller clamped "to the same ceiling". |
| `PlaybackLook` | Whether a look is reaching the clip under review, and therefore what the filter control beside the transport may say about it. **Already drifted.** `applyPlaybackLUT` — what actually reaches the picture — asks four questions: preview on, look baked into the file, suppressed for this clip, and is there a cube. The bar asked two. It never asked whether there was a LOOK, so with the library cleared and preview still on (`selectLUT(fileName: nil)` deliberately leaves `previewEnabled` alone) it lit in the accent colour over an ungraded picture and offered to switch off something that was not on. Every case is now checked against the FRAME the tap delivers rather than against the flags. |
| `TakeLogDraft` | What the take log popover holds while it is open, and the fact that its load and its save are inverses. It is the only way to correct what a take was slated as, and the correction lands on the sidecar that `+LibraryRestore` reads back as the newer of the two — so a slate changed by a save nobody meant travels into the next session as the truth. Both halves were private methods over five `@State` strings inside a body SwiftUI does not build until the popover is presented, and the take-number half was not an inverse. |

The fourth is the six lines the previous section named and left, so
`RawPlayback+Transport` is 100 % now: clearing an in or out point by clicking it
again, a scrub that RESUMES playback instead of stopping it, and the scopes
following a paused seek — which is the thing a DIT does all day.

**One existing test had to change, and the reason is the finding.**
`RemoteAbuseBoundsTests.theSlateFieldsAreBoundedToo` expected a take of five
thousand digits off the wire to read as 0, on the argument that "an ellipsis is
not a number". That 0 was an accident of where `Int(_:)` gives up. The old parse
was `Int(bounded(text))`, so the answer turned over at the width of `Int` and
nowhere else — measured across lengths: 5 digits gave 99999, **18 digits gave
999999999999999999**, 19 gave 0. The test sat on the safe side of that cliff
with the unsafe side one digit away and nothing looking at it, and `slate.take`
goes into the .mov's metadata and the Take column of the sidecar and the ALE. It
now pins the bound at every length, which is a stronger claim than the one it
replaced.

Every claim was checked by breaking it and watching a test name the break:
twelve mutations, all twelve caught, each by the test that describes it. Three
are worth writing down for what they showed rather than for what they caught:

- Removing the take-number ceiling turned five assertions red across two suites
  and left the round trip GREEN, correctly — a number under the ceiling still
  comes back. The round trip and the ceiling are two claims and need two tests.
- Putting the footer's own parse back — the exact state described above — is
  caught by `theCartAndThePhoneLogTheSameTakeNumber` and by nothing else:
  `(controller.slateTakeOverride → 1) == (expected → nil)`, which is typing `0`
  into a field and being handed take 1.
- Demoting `PlaybackLook.baked` below the preview guard changes NOTHING about
  the picture: `appliesCube` is false either way, so only the READING moves, and
  only the assertion about the reading catches it. That is the argument for
  asserting a control separately from the frame it claims to describe, and it is
  why every case in that suite is checked against both.

## The forgotten-engine wave

The wave that took the number from 90.61 % to 90.66 % started from the list the
shared-rule wave left, and its first item was the one that wave had measured as
paying **zero** coverage. That turned out to be the right place to start for a
reason that is not about the number: pulling on it led to four more instances of
the same shape, and two of those are the worst defects in this file's history —
a marker written into the wrong file, and one silently deleted out of it.

Five hundredths of a point for five changes, which is the shared-rule wave's
shape again and for the shared-rule wave's reason: deduplicating a decision
deletes lines from several places and adds one covered function. Read that
paragraph before copying the method. The two defects are the return here; the
number is not.

**A note on the starting figure.** This wave measured 90.61 % (4 169 of 44 380
uncovered) on the very commit the table above recorded as 90.57 % (4 185). That
is sixteen lines, where the jitter this file documents is one to four, so it is
NOT the same phenomenon and no explanation was established. Both numbers came
from `coverage.sh` on this Mac. Treat a starting figure as something to
re-measure rather than to read out of this file — which is the rule the file
already states for the ending one. The 90.66 % above is ONE run of the finished
tree, so it carries the usual few lines of jitter and no second run to average
against.

**And a note on how not to measure it.** Editing a source file while a battery
is in flight fails the build outright — `input file '…' was modified during the
build` — which cost this wave a run of both phases. SwiftPM catching it is the
good case: the bad one is an edit that lands between the build and the report,
where the number comes out looking like a number. The existing rule is "never
run two SwiftPM invocations against one tree"; the same tree also has to hold
STILL for the one that is running.

### The dial that was right by coincidence

`ChromaKeyControls` asked one question — what fraction of this slider's travel
is the dial at — in three spellings: tolerance divided by
`ChromaKey.maxTolerance`, softness divided by nothing at all, spill divided by
nothing because its range is a literal 1. All three were right and two only by
coincidence. The range and the readout were separate arguments to
`ChromaSliderRow`, so nothing held them together; `ChromaSliderReadout` derives
the text from the range the slider is already laid out on, and the three
readouts, the plate's signed offsets and the plate's scale multiplier are now
three named cases instead of three ad-hoc expressions.

The mutation is the clearest statement of it: made to divide by nothing — which
is what SOFTNESS did — the tolerance dial reads **60 at the end of its travel**.

Two things came out of the mutations rather than out of the design:

- The zero-width-range guard is not protecting what its comment claimed.
  `Int(Double.nan)` does trap, but the clamp absorbs the NaN first
  (`max(0, .nan)` is 0, because `nan >= 0` is false), so `0` on `0...0` answers
  "0" with or without the guard. What the guard actually stops is a value OFF a
  degenerate range: `5` on `3...3` divides to +∞, clamps to 1 and reads **100**
  — "all the way along" a travel of zero. The comment and the test both say the
  measured thing now, and a test that had only asked the first case would have
  been green against the bug.
- **Which KIND of readout a dial is given is still a per-call-site choice and
  nothing can catch a wrong one.** Given `.signedPercentOfFrame`, the tolerance
  dial reads "+30" where it should read "50" and the whole suite stays green:
  the readout sits in a fixed-width 30pt column so it moves no measurable size,
  and ink is not portable between the runner and this Mac. The three percent
  dials share one private helper now, so there is one site that can be wrong
  instead of three. That is what was available, not a fix.

### The modal the previous table predicted

`askDuplicateLUT` was an `NSAlert.runModal()` with all three arms of
`adoptLooks` behind it — file operations on the operator's look library, one of
which DELETES — and none of them had ever executed. `DuplicateLookPrompt` is the
`FilePanel` shape applied to it.

The part worth copying is not the seam, it is what the seam made visible.
`NSAlert` answers with a POSITION, so the buttons and the response mapping are
two halves of one list; written apart (three `addButton` calls, then a `switch`
over three response constants) inserting or reordering a button leaves both
halves compiling and swaps what two of the three buttons DO. They come from one
ordered list now. The mutation that reverses the mapping prints the hazard
exactly: `(choice → .replace) != .replace` for `.alertThirdButtonReturn` — the
operator presses **Skip** and the look is overwritten.

### The grid every surface forgets

Playback is three engines — the sync-play GRID, the RAW engine, the single
`AVPlayer` — and `startSyncPlay` pauses the single player without clearing
`playbackURL`, so every question asked of the parked engines still has a
plausible-looking answer while the grid is up. That is why `transportBarKind`
guards `syncPlay == nil` before reading `playbackURL`, and why
`isReviewingClip` and `isReviewingSingleClip` both exist. The transport verbs
(`togglePlayPause`, `skipPlayback`, `stepPlayback`) all route grid → raw →
single. Five other places did not, and four of them were found by pulling on
the first:

| Surface | What it did over a grid |
| --- | --- |
| the TC badge's text | Read `player.currentTime()` of the PARKED player and showed the previous take's timecode — `10:00:00:00`, verbatim from the mutation — on the readout the brief puts top left. |
| the TC badge's 10 Hz tick | Asked `player.rate != 0 \|\| rawPlayer?.isPlaying`, so it declined to re-read anything: the badge went still while the grid rolled. Fixing the text alone would have changed nothing visible. |
| **`addMarker()`** | Wrote a marker into the parked take, at the paused player's position. |
| **`removeNearestMarker()`** | DELETED one from the parked take, within ±2 frames of the paused position. |
| `playbackPositionSeconds` | Answered the parked player's position. Every caller is gated, so this one cost nothing yet. |

The two marker rows are the real defects, and they are ones the codebase had
already diagnosed and half-fixed. `canDropMarker` has said since the long-tail
wave that "the sync-play grid is not [a timeline a flag belongs on]" — and that
fix reached the MENU ITEM and never the methods. Of the four surfaces that drop
a marker, two were safe by accident (the menu greys; the transport button is not
mounted over a grid) and two were not: the hotkey and the phone both call
`addMarker()` directly. `playbackAcceptsMarkers` cannot catch it, because
`playbackURL` is exactly where it was. A marker in a file the operator cannot
see, at a position that is not the one on screen, in the sidecar editorial
reads.

**The delete is the one that costs something, and its reach is what makes it
reachable.** `removeNearestMarker` takes the marker within ±2 frames of the
playhead — so the case is not a coincidence but the ordinary one: an operator
marks a moment in a take, then selects that take and three others to compare,
and the parked playhead is sitting exactly on the marker they just placed. The
remove hotkey over the grid took it, out of a file not on screen, with a toast
naming a timecode from somewhere else.

`playbackPositionSeconds` was fixed too, though nothing steps on it: every
caller is gated to the single clip. It is in the table because "wrong but
currently unreachable" is precisely what the marker rule was before the hotkey
found it, and leaving one more of them lying about is how the first one survived
a wave that had already named it.

`PlaybackEngine` names the three and their precedence once; the badge, the
clock and the position read it, both marker methods ask `isReviewingSingleClip`,
and the menu bar — which was `canDropMarker` spelled out a second time, which is
how the methods came to be missing it — asks the rule itself.

`seekPlayback` is left asking raw → single on purpose, and that is worth stating
so the next reader does not "finish the job": its only caller is `jumpToMarker`,
which is menu-only and gated to the single clip, and seeking a GRID is
`SyncPlayModel.seek`, which re-issues a synchronized start across every tile
rather than moving one player. It would need routing to a different verb, not an
extra arm.

What a grid's timecode IS turned out to be the interesting half: nothing. Two to
four takes with two to four start timecodes against one master timeline have no
single timecode, which is why the grid's own transport shows elapsed time and
each TILE carries its own. So the badge shows `timecodeFallbackText` — the same
"no timecode here" string the live badge, the multicam tiles and the slate use.
A readout that says it has no number is worth more than one that states another
clip's.

### Mutations

Eighteen, of which seventeen turned a test red — each by the test that
describes it. Three are worth writing down for what they showed rather than for
what they caught:

- **Reordering `DuplicateLookPrompt.order` leaves the CONSISTENCY loop green**,
  correctly: the buttons and the mapping still agree, because they now come
  from the one list. Only the two explicit position assertions catch it. That
  is the design working rather than a gap, and it is the answer to "what would
  still pass if this regressed in a different direction" — a divergence is
  impossible, so the test that mattered before is now the one about which
  answer is FIRST.
- **The zero-width-range guard is not protecting what its comment claimed**, and
  the mutation is how that was found: removing it leaves `0` on `0...0`
  answering "0" anyway. The comment and the test both say the measured thing
  now. This is the one place in the wave where a mutation failing "correctly"
  would have let a wrong sentence stand in the source.
- **The eighteenth does not fail and is not a bug in the test to be fixed.**
  Given `.signedPercentOfFrame`, the tolerance dial reads "+30" instead of "50"
  and all 2 543 tests stay green. It is the test and not the configuration —
  the suite tests the function, and the wiring is a per-call-site choice with
  no portable observable. Stated as a limit above.

## The honest ceiling

Roughly **1 000 lines — about 2.4 points — cannot be covered by a headless
suite at all.** That puts the arithmetic ceiling near 97.6 %, and the gap
between that and the measured 90 % is not unreachable code: it is a long tail of
view bodies, AppKit window paths and error branches that are reachable with more
work. 95 % is a question of how many more waves, not of whether it is possible.

There are now three measurements of what "more work" costs, and the spread — an
order of magnitude between the first and the other two — is the useful part:

| Wave | Changes | Points | What the changes were |
| --- | --- | --- | --- |
| long-tail | 6 | +0.67 | a fixture that had never decoded, plus five rules leaving places nothing could ask them |
| shared-rule | 4 | +0.07 | four rules leaving places nothing could ask them, three of which were spelled out in several places at once |
| forgotten-engine | 5 | +0.05 | one seam in front of the app's only modal, plus four rules leaving places nothing could ask them |

The difference is not effort. A rule that was in ONE unreachable place moves the
number when it comes out; a rule that was in FOUR unreachable places deletes
three copies on the way, and deleting covered-by-nobody lines lowers the
denominator as fast as the new function raises the numerator. Both leave the
suite defending more than it did. Only one of them shows up in the report, and a
wave planned against the report alone will keep picking the first kind and never
find a disagreement — because a rule stated once cannot disagree with itself.

Two waves in a row have now landed on the low number, and both found real
defects doing it — which is the correlation worth reading. The measure of the
second kind is not points; it is that the forgotten-engine wave started from one
readout stated twice and ended with five surfaces asking about a grid, two of
them writing to a file that was not on screen. **95 % will not be reached by
this kind of wave**, and that is not an argument against it. It is an argument
for planning both: a points wave has to go at the view bodies and the AppKit
paths the table below describes, and a wave that wants the number to MEAN
something goes where two things claim to answer the same question. The honest
version of the owner's target is that those are different afternoons and only
one of them shows up in the report.

What is genuinely out of reach, and why:

| Lines | Where | Why |
| --- | --- | --- |
| ~342 | `AppCommands.swift` | The menu bar. `Commands` bodies cannot be hosted in an `NSHostingView`, and hosting the individual groups as plain views would run their `body` without asserting anything — the item titles, the `.disabled` predicates and the shortcut lookups are all invisible from outside. Rendering it would move the number and defend nothing. |
| ~234 | `TakeShotApp.swift` | The `App` scene and `AppDelegate`. Constructing it builds a `CaptureController()` on the operator's real `UserDefaults` and needs an `NSApplication` lifecycle. |
| ~135 | `AudioInputDevices.swift` | `SystemAudioInputProvider` enumerates the machine's CoreAudio devices and `SystemAudioCaptureDevice` opens one. The conversion arithmetic underneath was pulled out and is covered (`ModelAudioPCMConversionTests`); the device walk is not. |
| ~82 | `MenuBarPresence.swift` | Constructing it installs a real `NSStatusItem` in the menu bar of whoever runs the suite. Everything decidable already lives in `MenuBarModel`, which is covered. |
| ~47 | `VolumeWatch.swift` | The real watch installs process-wide `NSWorkspace` observers and would react to a disk somebody plugged into the machine running the suite. |
| ~43 | `AssistZoomCursor.swift` | `NSCursor` and tracking areas need a window and a pointer, and asserting on them means mutating process-global cursor state. |
| ~37 | `DeckLinkBackendAdapter.swift` | Constructing it installs a process-wide hot-plug callback and adopts whatever board is attached. |
| ~29 | `SingleInstanceGuard.swift` | Hands off to another running copy of the app via `NSRunningApplication`. |
| ~41 | `FilePanel`, `AudioRenderRoute`, `PlayoutOutput` | The far side of the three new seams: `runModal()`, `audioOutputDeviceUniqueID` on a live renderer, and the `CDLPlayout` conformance. |
| ~33 | `RawClipSource` (and no longer `RawPlayback+*`) | **This row said ~200 and was wrong — not about the SDK, about what the SDK was being blamed for.** BRAW's headers are absent on CI, so `BRAWSource` and `R3DSource` cannot execute there; but most of the 200 was the DECODE LOOP, which is format-agnostic and was uncovered because every fixture was a folder of files that would not decode, not because of any SDK (see the long-tail wave). What is left is the two SDK-gated sources, and the timecode readouts underneath them — `parseTimecode` and the R3D half-rate `timecodeFrames` need a clip that carries a start timecode, which a folder of CinemaDNG frames does not. `R3DClipSource.swift` (~52) is the same story. The developer machine now HAS the BRAW headers, so `CBRClip.isSDKAvailable` is true here and false on CI — and this changes the coverage number by NOTHING, measured: 90.34 %, 4 108 uncovered, byte for byte the same before and after the headers landed. Availability is not exercise. No suite owns a real `.braw` file, so the decode path stays dark whether the bridge is a stub or not, and the two machines still agree. (An earlier version of this line claimed they would diverge. They do not, and the measurement is why.) The `RawPlayback+*` half of this row is now spent: `+Scopes` and `+Transport` are at 100 % and `+PlayLoop` at 98 %, so nothing in the RAW ENGINE is left here — only the two SDK-gated sources under it. |
| ~39 | `WebRTCPeer.swift` | The real peer connection, behind the `WebRTCPeering` seam. Reaching it means generating a DTLS certificate and gathering ICE candidates off every interface the machine has, once per test. `WebRTCBridgeTests` DOES exercise it — the offer, the answer, the candidate list — but only on a machine that has libdatachannel, which is not CI. The mappings that decide behaviour (`state`, `classify`) were pulled out as pure functions and are covered everywhere (`WebRTCMappingTests`). |

And the ones the interruption wave went looking for and could not reach. Each
was tried, so these are measurements rather than guesses:

| Where | Why |
| --- | --- |
| `CapturePipeline+Frame.appendToTake`, the `writer.hasFailed` arm (~8 lines), and `TakeWriter.failureReason` | **There is no deterministic way to fail an `AVAssetWriter` from a test.** Measured on macOS 26: a grayscale or 16-bit-grey buffer into a ProRes writer is accepted, an off-size buffer is accepted, unlinking the whole output directory and then writing 400 more frames is accepted, `cancelWriting` leaves `.cancelled` and not `.failed`, and `AVAssetWriter(outputURL:)` no longer throws on an existing file. The *decision* the branch guards is covered from the other side (`routineDropsAreNotReportedAsWriterFailure`) and the failure itself is covered on device. Reaching it headlessly needs a protocol in front of `TakeWriter`, which is a bigger change than the branch is worth. |
| `CaptureController.availableScreens` | Reads `NSApp.mainWindow`. `NSApp` is an implicitly unwrapped global that is nil until an `NSApplication` exists, and a test binary has none — touching it traps. Harmless in the app (the property is only ever read from a view inside a running application) and not worth instantiating `NSApplication` in the suite to reach. |
| `makeBorderlessWindow` and the three fullscreen surfaces in `CaptureController+Windows` (~40 lines) | They put a black `.statusBar`-level window over the whole screen of whoever runs the suite and take the keyboard focus with it. The half that decides — a stored display that is no longer attached builds nothing — is covered. |
| `HotkeyManager.install`, what is left of it | An `NSEvent` local monitor: driving it means posting real events into an application event queue there is none of. This row used to say only that "the two decidable parts are covered", which understated how much of it WAS decidable. The rule has since been pulled out into `HotkeyManager.outcome`, a function over the facts a press carries (`HotkeyPress`) and the two fullscreen flags, with its own suite — so what stays unreachable is the reading of those facts off an `NSEvent`, the one fact no event carries (`firstResponder is NSTextView`), and the calls that apply the answer. |
| `PunchEventView.handle`, what is left of it | Same shape: a local monitor over synthesized `.magnify` and `.scrollWheel` events, which cannot be built with a window number that matches. The DECISION has since been pulled out into `PunchEventView.decide`, a function over (type, magnification, modifiers, deltas, precise, pointer, bounds, punched-in) with its own suite — so what remains unreachable is the reading of those facts off an `NSEvent` and the two calls that apply the outcome. That is the shape to copy for the rest of this table's monitor rows. |
| `CaptureController.setMulticam`, the hardware arm (~22 lines) | Constructing the `DeckLinkBackendAdapter` it needs is the thing `ControllerHarness` exists to avoid: on a machine with the SDK dropped in it adopts whatever board is attached. Safe on a runner with no SDK and unsafe on the developer's, which is not a difference a suite may depend on. The PLAN in front of it is not that and is covered now — `multicamPlan` says which board becomes which camera, which is the half that reaches the file names. |
| `CapturePipeline.uniqueURL`'s 1000-attempt fallback (4 lines) | Needs a thousand colliding files in the record folder. |
| `DuplicateLookPrompt.handler`'s default body (2 lines) | **This row said `askDuplicateLUT` (~13 lines) and predicted its own fix**, which the forgotten-engine wave carried out: "making the choice injectable the way `FilePanel` is would unlock it." What is left is `configured(name:).runModal()` and nothing else — the alert's construction and the response mapping are `configured(name:)` and `choice(for:)`, both pure and both covered, and the three arms of `adoptLooks` behind it are covered now too. Same residue as `FilePanel`: the modal itself. |

Two more, worth naming because they look coverable and are not:

- **Menu-content views** (`MediaSourceMenuItems`, `TakeContextMenu`,
  `PanelItemActions`) build their rows inside a `Menu`, which SwiftUI does not
  construct until the menu opens. Their inputs — `mediaSources`,
  `panelActionTargets` — are covered on the controller side instead.
- **Popover bodies** (`TakeLogButton.editor`) are not built until the popover is
  presented. What they read and write is covered, and that got narrower: it used
  to mean "`setComment` and `setSlate` are tested", which said nothing about the
  five `@State` strings between the take and those two calls. The draft is a
  value now (`TakeLogDraft`), so the load, the save and the fact that they are
  inverses are all covered, and what is left unreachable is the LAYOUT.
  `ChromaColorField.commit()` was the same shape one popover along — reached
  from `onSubmit` and from focus LEAVING the field, neither of which a headless
  render performs — and went the same way (`committed(text:current:)`).

And what the forgotten-engine wave deliberately did NOT touch, so the next one
starts from a list rather than from the report again:

- `AppCommands.swift` (~344, 6 %) is still the largest single file in the table
  and the reasoning above still holds — checked rather than assumed by the
  long-tail wave, and not re-argued since. The two things that CAN regress
  silently are already covered from outside: `ModelAppCommandsTests` walks every
  title key in both languages (a typo renders as `menu_play_pause`, which no
  build step notices) and pins the shortcut rule, and `ViewDisabledRuleTests`
  walks the sources so all 22 `.disabled(` sites there name a controller rule.
  Hosting the groups as plain views would execute 34 `Button` bodies and assert
  none of it.
- **`AssistZoomEvents.swift` (56) is not a gap, and the report cannot say so.**
  It is the file `PunchEventView.handle` lives in, which the table above already
  accounts for; what is left in it is the reading of facts off an `NSEvent` and
  the two calls that apply the outcome. Anyone working down the report's top-N
  list will meet this file with no idea it is settled — which is the general
  hazard of reading the report instead of this document, and the reason the
  table names SYMBOLS and the report names files.
- **`ChromaKeyControls`, now that both of its decisions are out.** The readouts
  are `ChromaSliderReadout` and the hex field's commit is
  `ChromaColorField.committed(text:current:)`. What is left in that file is
  button action closures, the eyedropper's `NSCursor` push/pop (a pointer and a
  window, same category as `AssistZoomCursor`), and the layout — and the
  shared-rule wave's measurement still holds for all of it: **it pays close to
  no coverage**, because a body that renders already executes.
- **Which readout KIND each dial is given** is the limit the section above
  states, and it is deliberately not repaired: nothing portable can see it. If
  somebody finds a way to assert a rendered STRING that survives macOS 15 and
  macOS 26, this is the first thing to point it at — and `ViewRenderSupport`'s
  note is the reason it has not been tried.
- **`MediaSourcePicker`'s three `Identifiable` `id` accessors** are still open,
  and the claim is unchanged: a picker row is identified by its URL and not its
  name, so two files of the same name in two folders stay two rows. One
  assertion, three lines. Left because it is the small end of the list, not
  because it is settled.
- `AppCommands.swift` is settled twice over, and this wave did not re-argue it
  a third time.
- **`TakeRowControls` (143), `FooterBar` (76), `TransportBar` (66)** are still
  mostly menu content and popover bodies (the two categories above) plus body
  arms reachable only by rendering a state. `PlayerBadges` has left this list:
  the decidable part of it WAS the badge clock, and that rule is
  `CaptureController.playbackIsRunning` now.
- **The engine question is now asked in one place; whether every OTHER surface
  reads it has not been audited.** `PlaybackEngine` was reached by pulling on
  one readout and finding three. `playbackPositionSeconds`,
  `playbackAcceptsMarkers` and `RemoteState.markerCount` were each read in
  passing and none looked wrong, but none was mutated either. A sweep for
  "what else asks about `player` or `rawPlayer` without asking about
  `syncPlay`" is the obvious next thread and this wave did not pull it.
- Rendering for its own sake is still what this file exists to say no to.

## Rules that outrank the number

- A test must not reach outside its own scratch directory: no real
  `UserDefaults`, no audio device, no configured destination folder, never the
  Desktop. `ControllerHarness` wires the throwaway versions up.
- Do not write an assertion that only restates the implementation. If a line's
  only honest test is "it compiles", leave it uncovered and say so — this file is
  where to say it.
- Waits poll for outcomes with I/O-sized budgets, never wall-clock windows.
- Rendering assertions: sizes are portable, ink is not. See the note at the top
  of `Tests/TakeShotKitTests/ViewRenderSupport.swift` before writing a view test
  — CI runs macOS 15 and the development Mac is on 26.
