## What changed and why

<!-- What was wrong before. The history is used as a debugging aid. -->

## Checklist

- [ ] `swift build` is clean with **zero warnings**
- [ ] `scripts/test.sh` is green
- [ ] `scripts/lint.sh` reports nothing new
- [ ] Tests added for changes to take detection, timecode or the writer
- [ ] Any new user-facing string goes through `L()` and exists in **both**
      `.lproj/Localizable.strings`

## Recording integrity

<!-- Delete if untouched. Otherwise say which rule this affects and how you
     verified it: fragmented files, take closed on format change / signal loss,
     audio mask latched per take, take published only after a successful
     finalize. -->
