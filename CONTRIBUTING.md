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

No vendored SDK is committed — most are not redistributable — so everything
under `vendor/` is ignored except each directory's `README.md`. Both Blackmagic
bridges build as stubs without their SDK and the app still runs against its
demo source, which is enough for most UI and logic work.

The first two are wired up. The rest are slots: the SDK has somewhere to go and
its terms are written down, but no code reads them yet.

| SDK | Goes in | State |
| --- | --- | --- |
| [DeckLink](https://www.blackmagicdesign.com/developer/) | `vendor/DeckLinkSDK/` | in use; without it there are no capture devices (`CDLDeviceManager.isSDKAvailable == false`) |
| [Blackmagic RAW](https://www.blackmagicdesign.com/developer/) | `vendor/BRAWSDK/` | in use; without it `.braw` files do not open (`CBRClip.isSDKAvailable == NO`) |
| [R3D](https://www.red.com/developers) | `vendor/R3DSDK/` | slot only — `.r3d` is recognized and reported as unsupported |
| [NDI](https://ndi.video/for-developers/ndi-sdk/) | `vendor/NDISDK/` | slot only — network output is planned, not built |
| [AJA NTV2](https://github.com/aja-video/libajantv2) | `vendor/AJANTV2/` | slot only — an AJA `CaptureBackend` is planned, not built |

Each `vendor/*/README.md` says exactly which files to copy where, and what the
licence lets you ship.

Neither runtime is linked at build time — `DeckLinkAPIDispatch.cpp` is included
directly in the bridge and the RAW framework is loaded dynamically — so a build
made without the SDKs still runs on a machine that has them.

For how the pieces fit together, and the hardware behaviour the capture path
depends on, read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

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
