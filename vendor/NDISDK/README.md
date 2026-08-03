# NDI SDK (Vizrt)

Slot for the NDI SDK, which lets TakeShot send the viewer over the set network —
a director's monitor on an iPad, a client feed in the production office — without
another cable or a second board output.

## Status

**Implemented, and a stub until the headers are here.** `Sources/CNDI` is the
bridge (`CNDSender`), wired the way `CDeckLink` and `CBraw` are: it compiles
against the headers in this directory when they are present and builds as a stub
when they are not. Nothing is committed here and nothing links at build time.

- **Without the headers** — CI, and every build until somebody downloads the SDK:
  the app builds and ships as it always did, `CNDSender.isSDKAvailable` is `NO`,
  and the NDI switch in Settings reports itself unavailable with the text of the
  next section as the reason. Off by default, so nothing changes for anyone who
  does not go looking.
- **With the headers**: the same switch announces an NDI source and sends the
  viewer to it. See "What the app does with it" below.

## Where to get it

Download the **NDI SDK for Apple** from <https://ndi.video/for-developers/ndi-sdk/>
(free, registration required). **SDK 4 or newer** — the FourCC constants were
respelled between 3 and 4, and `Sources/CNDI/CNDI.mm` uses the newer spelling, so
an SDK 3 header fails to compile rather than building something subtly wrong.

The macOS installer puts the SDK under `/Library/NDI SDK for Apple/`. Copy the
headers here:

```text
vendor/NDISDK/include/    Processing.NDI.*.h   (the whole set — they include each other)
```

Then `swift build`. Nothing else: there is no library to copy for the build,
because the runtime is loaded at run time (next section).

## The runtime

`libndi` is opened with `dlopen` the moment the operator first switches the
feature on — never at launch, never at link time. The paths tried, in order:

1. `<TakeShot.app>/Contents/Frameworks/libndi.dylib` — a release that ships the
   runtime itself (read the licence note below first)
2. `/usr/local/lib/libndi.dylib`
3. `/usr/local/lib/libndi.4.dylib`
4. `/opt/homebrew/lib/libndi.dylib`
5. `/Library/NDI SDK for Apple/lib/macOS/libndi.dylib`

Installing **NDI Tools**, or the SDK itself, puts the runtime in one of them. When
none of them resolves, Settings says so and lists every path that was looked at.

Only five symbols are resolved — `NDIlib_initialize`, `NDIlib_version`,
`NDIlib_send_create`, `NDIlib_send_destroy` and `NDIlib_send_send_video_v2` — and
each takes its type from the SDK header via `decltype`. No part of the NDI ABI is
hand-declared anywhere in this project: guessing a struct layout or an argument
list would be silent memory corruption, invisible until it mattered on a set, so
the bridge is arranged such that a wrong name or a changed signature is a compile
error instead.

## What the app does with it

- **One video source per app**, announced as `MACHINE (name)` — NDI supplies the
  machine half; the name is the Settings field, defaulting to the project name
  plus the camera label ("Dune B"), or "TakeShot" when neither is set.
- **The frame is the one the hardware monitor gets**: the decorated viewer
  picture — exposure aids, guides, chroma key and all. NDI rides the same display
  mirror slot as the DeckLink playout output and follows the viewer between live,
  playback and RAW exactly as that output does. It is deliberately NOT the clean
  frame the phone camera grid gets: that grid is a crew monitoring surface where
  the operator's own tools would lie to it, whereas an NDI feed replaces a cable
  to somebody watching over the operator's shoulder.
- **BGRX, full range, Rec.709 primaries and transfer, progressive.** That is what
  the app's display buffer already holds and what an NDI receiver already reads
  uncompressed RGB as, so there is no conversion in the path at all — the sender
  is handed the pixel buffer's own base address at its own row stride. BGRX
  rather than BGRA because the fourth byte is padding, not alpha.
- **Never on the capture queue.** The send runs on `com.takeshot.ndi` with
  latest-wins coalescing, so a slow network drops frames instead of delaying the
  recorder. Measured app-side cost per frame: 0.11 ms at 1080p, 0.22 ms at UHD,
  against a 40 ms frame interval at 25 fps.
- **Picture only.** The reasoning, and where an audio path would attach, is at the
  top of `Sources/TakeShotKit/CaptureController+NDI.swift`.

## Licence note

The NDI runtime may be redistributed inside an NDI-enabled application, but only
under Vizrt's SDK licence, which carries attribution and naming requirements —
the product has to identify NDI correctly and link to their site. Read the licence
in the SDK before shipping a release that bundles the runtime (path 1 above);
nothing about the stub build, or about a build that loads a runtime the machine
already has, distributes any of it.
