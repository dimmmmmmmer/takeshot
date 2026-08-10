# Contributing to TakeShot

Thanks for looking. This is a tool people record irreplaceable footage with, so
the bar for anything touching the capture path is high — the rules below exist
because each of them was learned the expensive way.

## Building from source

Xcode is not required — the Command Line Tools are enough. Everything runs
through SwiftPM:

```bash
swift build                    # build
scripts/test.sh                # both test suites
scripts/test.sh --sanitize=thread   # the same suites under ThreadSanitizer
scripts/coverage.sh            # the suites with coverage, against the floor
scripts/lint.sh                # SwiftLint (brew install swiftlint first)
scripts/bundle-app.sh          # build/TakeShot.app
swift run takeshot-devices     # CLI smoke test: list capture devices
```

Two test targets: `CaptureCoreTests` covers the core logic against synthetic
signals, `TakeShotKitTests` drives a session end to end through the mock
backend with no hardware and no window.

`scripts/lint.sh` exists because SourceKitten looks for sourcekitd inside a
toolchain directory and the Command Line Tools have no `Toolchains` folder; the
script points `TOOLCHAIN_DIR` at the CLT root. Without it SwiftLint dies on
startup.

### Vendored SDKs

No vendored SDK is committed — none of them may be redistributed — so
everything under `vendor/` is ignored except each directory's `README.md`.
Every bridge builds as a stub without its SDK and the app still runs against
its demo source, which is enough for most UI and logic work. **This is also
what every published release is**: the workflow builds on a GitHub runner,
which has none of them, so the DMG on the releases page can play back and
export but cannot see a capture board. If you want to change that, that is the
thing to change.

Four of these are wired up; the last is a slot — the SDK has somewhere to go
and its terms are written down, but no code reads it yet.

| SDK | Goes in | State |
| --- | --- | --- |
| [DeckLink](https://www.blackmagicdesign.com/developer/) | `vendor/DeckLinkSDK/` | in use; without it there are no capture devices (`CDLDeviceManager.isSDKAvailable == false`) |
| [Blackmagic RAW](https://www.blackmagicdesign.com/developer/) | `vendor/BRAWSDK/` | in use; without it `.braw` files do not open (`CBRClip.isSDKAvailable == NO`) |
| [R3D](https://www.red.com/developers) | `vendor/R3DSDK/` | in use; without it `.r3d` is recognized and reported as unsupported (`CR3DClip.isSDKAvailable == NO`) |
| [AJA NTV2](https://github.com/aja-video/libajantv2) | `vendor/AJANTV2/` | slot only — an AJA `CaptureBackend` is planned, not built |

Each `vendor/*/README.md` says exactly which files to copy where, and what the
licence lets you ship.

Only R3D is linked at build time, and only when its archive is really on disk
(see the comment in `Package.swift`). The rest are opened at runtime —
`DeckLinkAPIDispatch.cpp` is compiled into the bridge, and the RAW runtime is
`dlopen`ed — so a build made without those SDKs still runs on a machine that
has them.

For how the pieces fit together, and the hardware behaviour the capture path
depends on, read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Cutting a release

The version is stated in exactly one place, the root `VERSION` file, and
everything else reads it from there: `scripts/bundle-app.sh` stamps it into the
bundle's `Info.plist` (so the About panel, the diagnostics report and the ASC
MHL manifests all agree), `scripts/release-notes.sh` looks up the matching
`CHANGELOG.md` section, and `.github/workflows/release.yml` refuses to publish
unless the tag is exactly `v` + that number. Nothing about a release is typed
into a web form.

1. Bump `VERSION`.
2. Add the matching `## <version>` section to `CHANGELOG.md`. Write it for the
   operator: what they will see, what changed under a workflow they already
   have, what is known not to work. `scripts/release-notes.sh` prints exactly
   what the release page will say — read it before you tag.
3. Commit, then `git tag v<version>` and push the tag.

The workflow builds the app, checks that the bundle really reports that
version, wraps it in a `.dmg` and publishes it with those notes plus a
description of the artifact measured off the artifact — which SDKs it was built
against and which architectures it carries.

Signing is ad hoc: no Developer ID, no notarization, so a downloaded build
needs a right-click → **Open** on first launch, and its cdhash changes with
every build, so TCC grants do not survive a rebuild. That is a known state, and
it is stated on the release page and in the README rather than left for
somebody to discover.

## Before you open a pull request

- `swift build` is clean **with zero warnings**. Warnings are how the
  concurrency bugs in this codebase announced themselves; a warning-free build
  is the tripwire, not a nicety.
- `scripts/test.sh` is green.
- `swiftlint` reports nothing new.
- If you changed take detection, timecode, or the writer, add a test. Those
  areas are covered against synthetic signals precisely because the failures
  are silent and only show up on set.
- If you touched anything that crosses threads, run `scripts/test.sh
  --sanitize=thread`. CI runs it too, but finding a race locally costs
  minutes and finding it in CI costs a day — the last one hid behind a green
  local suite for a week.
- Line coverage stays above the floor in `.coverage-floor`. CI fails the build
  below it and names the files holding the most uncovered lines;
  `scripts/coverage.sh` gives you the same answer locally. If the code you added
  can only be reached with hardware, a device or a UI session, put a seam in
  front of it the way the rest of the codebase does — `docs/coverage.md` lists
  the existing ones — or add it to the ceiling list in that file with the reason.
  Do not raise the number with assertions that restate the implementation: a line
  exercised without a behaviour pinned to it defends nothing and makes the next
  refactor more expensive.

**Tests keep to themselves.** A test must not reach anything outside its own
scratch directory: no writing the operator's real `UserDefaults` keys, no
opening an audio output device, no touching a configured destination folder.
Types that talk to those take an injected seam (`HotkeyManager(defaults:)` is
the pattern) and the fixtures pass a throwaway one. This is not fastidiousness
— the demo source generates sine tones, and a controller built with monitoring
at its default plays them out of the speakers of whoever runs the suite, while
also making the run depend on a device the CI runner may not have.

## House rules

**Language.** Code, comments, commit messages and documentation are in English.
UI strings go through `L("key")` and are added to *both*
`Sources/TakeShotKit/Resources/{en,ru}.lproj/Localizable.strings`. No
hard-coded user-facing text in views.

**Comments explain *why*.** The codebase deliberately records the reasoning
behind non-obvious choices — why the preview avoids `AVSampleBufferDisplayLayer`,
why levels are expanded on gamma-encoded values, why the 10-bit record buffer is
precompensated. Do not delete that reasoning, and add your own when you make a
choice the next reader would otherwise undo.

**Do not block the capture queue.** Per-frame work lives on
`CapturePipeline.queue`. GPU work, file I/O and anything that can park (notably
`nextDrawable()` on an occluded window) belongs on its own queue with
latest-wins coalescing. A stall there is dropped frames in someone's take.

**Recording integrity is not negotiable.** The rules in CLAUDE.md — fragmented
files, closing the take on format change or signal loss, latching the audio
mask per take, publishing a take only after a successful finalize — are load
bearing. If a change touches them, say so explicitly in the PR.

**Failures must be visible.** A failure that threatens a recording is a sticky
alarm, not a five-second toast. Silent `try?` on a path the operator depends on
is a bug.

**Keep types from growing back into god objects.** `CaptureController` and
`CapturePipeline` are split into domain extensions; new behaviour goes into the
matching one.

## Commit messages

Explain what changed and why it was wrong before. The history is used as a
debugging aid — "fix bug" costs the next person an hour of `git log -S`.

## Reporting bugs

Include the macOS version, the capture device and its Desktop Video version,
the signal (resolution, frame rate, RGB or YUV, timecode source), and what the
app said. Console logs are under the `com.takeshot.app` subsystem:

```bash
log show --last 10m --predicate 'subsystem == "com.takeshot.app"'
```

If it happened during a take, say whether the file survived — that separates a
UI bug from a recording bug, and the second kind gets fixed first.
