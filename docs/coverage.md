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
| Floor | **86.0 %** lines |
| Measured | **87.52 %** lines, 78.9 % regions (4 400 of 35 258 lines uncovered) |

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

## The honest ceiling

Roughly **1 000 lines — about 2.9 points — cannot be covered by a headless
suite at all.** That puts the arithmetic ceiling near 97 %, and the gap between
that and the measured 87.5 % is not unreachable code: it is a long tail of view
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
