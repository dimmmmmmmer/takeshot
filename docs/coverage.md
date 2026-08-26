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
| Floor | **87.5 %** lines |
| Measured | **89.32 %** lines (4 258 of 39 856 lines uncovered) |

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

## The honest ceiling

Roughly **1 000 lines — about 2.7 points — cannot be covered by a headless
suite at all.** That puts the arithmetic ceiling near 97 %, and the gap between
that and the measured 89 % is not unreachable code: it is a long tail of view
bodies, AppKit window paths and error branches that are reachable with more work.
95 % is a question of how many more waves, not of whether it is possible.

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
| ~200 | `RawPlayback+*`, `RawClipSource` | The BRAW decode paths. `vendor/BRAWSDK/include` is not committed and is absent on CI, so `CBRClip.isSDKAvailable` is false and those branches cannot execute. The CinemaDNG half is reachable and partly covered. |

And the ones the interruption wave went looking for and could not reach. Each
was tried, so these are measurements rather than guesses:

| Where | Why |
| --- | --- |
| `CapturePipeline+Frame.appendToTake`, the `writer.hasFailed` arm (~8 lines), and `TakeWriter.failureReason` | **There is no deterministic way to fail an `AVAssetWriter` from a test.** Measured on macOS 26: a grayscale or 16-bit-grey buffer into a ProRes writer is accepted, an off-size buffer is accepted, unlinking the whole output directory and then writing 400 more frames is accepted, `cancelWriting` leaves `.cancelled` and not `.failed`, and `AVAssetWriter(outputURL:)` no longer throws on an existing file. The *decision* the branch guards is covered from the other side (`routineDropsAreNotReportedAsWriterFailure`) and the failure itself is covered on device. Reaching it headlessly needs a protocol in front of `TakeWriter`, which is a bigger change than the branch is worth. |
| `CaptureController.availableScreens` | Reads `NSApp.mainWindow`. `NSApp` is an implicitly unwrapped global that is nil until an `NSApplication` exists, and a test binary has none — touching it traps. Harmless in the app (the property is only ever read from a view inside a running application) and not worth instantiating `NSApplication` in the suite to reach. |
| `makeBorderlessWindow` and the three fullscreen surfaces in `CaptureController+Windows` (~40 lines) | They put a black `.statusBar`-level window over the whole screen of whoever runs the suite and take the keyboard focus with it. The half that decides — a stored display that is no longer attached builds nothing — is covered. |
| `HotkeyManager.install` (~45 lines) | An `NSEvent` local monitor. Driving it means posting real events into an application event queue there is none of; the two decidable parts (`typingKeepsTheKey`, and `perform` behind it) are covered. |
| `PunchEventView.handle`, what is left of it | Same shape: a local monitor over synthesized `.magnify` and `.scrollWheel` events, which cannot be built with a window number that matches. The DECISION has since been pulled out into `PunchEventView.decide`, a function over (type, magnification, modifiers, deltas, precise, pointer, bounds, punched-in) with its own suite — so what remains unreachable is the reading of those facts off an `NSEvent` and the two calls that apply the outcome. That is the shape to copy for the rest of this table's monitor rows. |
| `CaptureController.setMulticam`, the hardware arm (~22 lines) | Constructing the `DeckLinkBackendAdapter` it needs is the thing `ControllerHarness` exists to avoid: on a machine with the SDK dropped in it adopts whatever board is attached. Safe on a runner with no SDK and unsafe on the developer's, which is not a difference a suite may depend on. |
| `CapturePipeline.uniqueURL`'s 1000-attempt fallback (4 lines) | Needs a thousand colliding files in the record folder. |
| `CaptureController.askDuplicateLUT` (~13 lines) | An `NSAlert.runModal()`. Everything either side of it is covered; making the choice injectable the way `FilePanel` is would unlock it. |

Two more, worth naming because they look coverable and are not:

- **Menu-content views** (`MediaSourceMenuItems`, `TakeContextMenu`,
  `PanelItemActions`) build their rows inside a `Menu`, which SwiftUI does not
  construct until the menu opens. Their inputs — `mediaSources`,
  `panelActionTargets` — are covered on the controller side instead.
- **Popover bodies** (`TakeLogButton.editor`) are not built until the popover is
  presented. What they read and write (`setComment`, `setSlate`) is covered.

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
