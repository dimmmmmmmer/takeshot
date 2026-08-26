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
| Measured | **90.39 %** lines (4 125 of 42 904 lines uncovered) |

The NDI output's return moved it up by five hundredths of a point while adding
367 lines of measurable code, and for a related reason: the parts of it that do
not cover themselves are behind seams — `NDIVideoSending` for the sender,
`NDIFrameRate` as a value type so the one piece of real arithmetic needs no SDK,
no sender and no network. What stays uncovered is `Sources/CNDI` (Obj-C++, so
not measured at all) and, inside it, the branch of the bridge this build did not
compile: the machine that restored the feature has the NDI runtime and no SDK
headers, so the whole real half of `CNDI.mm` is dark here and on CI alike.

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

## The honest ceiling

Roughly **1 000 lines — about 2.4 points — cannot be covered by a headless
suite at all.** That puts the arithmetic ceiling near 97.6 %, and the gap
between that and the measured 90 % is not unreachable code: it is a long tail of
view bodies, AppKit window paths and error branches that are reachable with more
work. 95 % is a question of how many more waves, not of whether it is possible.

The long-tail wave below is one measurement of what "more work" costs: six
changes, +0.67 points, and five of the six were a rule leaving a place nothing
could ask it rather than a new assertion about code that stayed where it was.

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
| ~39 | `RawPlayback+*`, `RawClipSource` | **This row said ~200 and was wrong — not about the SDK, about what the SDK was being blamed for.** BRAW's headers are absent on CI, so `BRAWSource` and `R3DSource` cannot execute there; but most of the 200 was the DECODE LOOP, which is format-agnostic and was uncovered because every fixture was a folder of files that would not decode, not because of any SDK (see the long-tail wave). What is left is the two SDK-gated sources, and the timecode readouts underneath them — `parseTimecode` and the R3D half-rate `timecodeFrames` need a clip that carries a start timecode, which a folder of CinemaDNG frames does not. `R3DClipSource.swift` (~52) is the same story. The developer machine now HAS the BRAW headers, so `CBRClip.isSDKAvailable` is true here and false on CI — and this changes the coverage number by NOTHING, measured: 90.34 %, 4 108 uncovered, byte for byte the same before and after the headers landed. Availability is not exercise. No suite owns a real `.braw` file, so the decode path stays dark whether the bridge is a stub or not, and the two machines still agree. (An earlier version of this line claimed they would diverge. They do not, and the measurement is why.) |
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
| `CaptureController.askDuplicateLUT` (~13 lines) | An `NSAlert.runModal()`. Everything either side of it is covered; making the choice injectable the way `FilePanel` is would unlock it. |

Two more, worth naming because they look coverable and are not:

- **Menu-content views** (`MediaSourceMenuItems`, `TakeContextMenu`,
  `PanelItemActions`) build their rows inside a `Menu`, which SwiftUI does not
  construct until the menu opens. Their inputs — `mediaSources`,
  `panelActionTargets` — are covered on the controller side instead.
- **Popover bodies** (`TakeLogButton.editor`) are not built until the popover is
  presented. What they read and write (`setComment`, `setSlate`) is covered.

And what the long-tail wave deliberately did NOT touch, so the next one starts
from a list rather than from the report again:

- `AppCommands.swift` (~344, 6 %) is still the largest single file in the table
  and the reasoning above still holds — checked rather than assumed this time.
  The two things that CAN regress silently are already covered from outside:
  `ModelAppCommandsTests` walks every title key in both languages (a typo
  renders as `menu_play_pause`, which no build step notices) and pins the
  shortcut rule, and `ViewDisabledRuleTests` walks the sources so all 22
  `.disabled(` sites there name a controller rule. Hosting the groups as plain
  views would execute 34 `Button` bodies and assert none of it.
- The view files with the most left (`TakeRowControls` 159, `FooterBar` 76,
  `TransportBar` 72, `MediaSourcePicker` 69, `ChromaKeyControls` 65) are mostly
  menu content and popover bodies — the two categories above — plus body arms
  reachable only by rendering a state. Rendering for its own sake is what this
  file exists to say no to; rendering to measure a SIZE budget is what the
  `View*` suites already do, and that is where the honest next wave is.
- `RawPlayback+Transport`'s last six lines: clearing an in or out point by
  clicking it again, a seek that resumes playback, and the scope callback on a
  paused seek. Small, reachable, and left because the wave had run its length.

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
