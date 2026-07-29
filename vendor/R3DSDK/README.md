# R3D SDK (RED)

Slot for RED's R3D SDK. Nothing here is committed — RED's licence does not
allow redistributing the SDK, its samples or its documentation, so everything
under `vendor/` is ignored except this file.

## Status

**Dropping the SDK here does not enable `.r3d` playback yet.** The app
recognizes `.r3d` files and reports them as unsupported; the decoder bridge
target is not written. This directory exists so the SDK is in place, and its
licence terms are read, before that work starts.

## Where to get it

Register at <https://www.red.com/developers> (free) and download the **R3D
SDK** for macOS. Unpack the archive into this directory as-is — the layout
below is the archive's own, no renaming needed:

```text
vendor/R3DSDK/Include/           R3DSDK*.h
vendor/R3DSDK/Lib/mac64/         the macOS static library
vendor/R3DSDK/Redistributable/   dynamic libraries the decoder loads at runtime
```

## How this one differs from the Blackmagic SDKs

DeckLink and Blackmagic RAW are header-and-dispatch: a `.cpp` shipped with the
headers loads the framework at runtime, so a build made without the SDK still
runs on a machine that has the vendor's software installed. RED's SDK is a
**static library that must be linked**, plus redistributable dynamic libraries
that must travel inside the app bundle. That means, when the bridge is written:

- the build links `libR3DSDK` and only succeeds where the SDK is present;
- a release with R3D support only runs where the redistributables were bundled
  with it, so `scripts/bundle-app.sh` has to copy them in;
- shipping those redistributables is governed by RED's terms — see
  `SDK License Agreement.pdf` in the archive before publishing such a build.
