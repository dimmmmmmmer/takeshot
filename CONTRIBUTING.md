# Contributing to TakeShot

Thanks for looking. This is a tool people record irreplaceable footage with, so
the bar for anything touching the capture path is high — the rules below exist
because each of them was learned the expensive way.

## Getting set up

```bash
swift build                    # build
scripts/test.sh                # both test suites
scripts/bundle-app.sh          # build/TakeShot.app
swift run takeshot-devices     # list capture devices
swiftlint                      # lint (brew install swiftlint)
```

Xcode is not required; the Command Line Tools are enough. The SDK setup is in
[README.md](README.md) — without the SDKs the bridges build as stubs and the
app runs against its demo source, which is enough for most UI and logic work.

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
