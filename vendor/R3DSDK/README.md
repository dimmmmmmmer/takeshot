# R3D SDK (RED)

Slot for RED's R3D SDK. Nothing here is committed — RED's licence does not
allow redistributing the SDK, its samples or its documentation, so everything
under `vendor/` is ignored except this file (and `../R3DSDK.xcframework`, which
is ours; see below).

## Status

**`.r3d` clips play.** Drop the SDK here and `swift build` links it — no script
to run, nothing to generate. `Sources/CR3D` opens a clip, reads its metadata and
decodes frames into the same 8-bit BGRA Rec.709 buffers the rest of the app
draws, so an R3D joins `RawPlayerModel` beside BRAW and CinemaDNG: transport,
scopes, markers, in/out points, assists, hardware playout, still grabs and
thumbnails all work on it unchanged.

Without the SDK, `CR3D` compiles as a stub (`CR3DClip.isSDKAvailable == NO`) and
the app builds, tests and ships exactly as before — opening an `.r3d` then says
the SDK is missing instead of decoding. That is what CI builds on every push.

## Where to get it

Register at <https://www.red.com/developers> (free) and download the **R3D
SDK** for macOS. Unpack the archive into this directory as-is — the layout
below is the archive's own, no renaming needed:

```text
vendor/R3DSDK/Include/           R3DSDK*.h
vendor/R3DSDK/Lib/mac64/         libR3DSDK-libcpp.a (universal: arm64 + x86_64)
vendor/R3DSDK/Redistributable/   dynamic libraries the decoder loads at runtime
```

Built and verified against **R3D SDK 9.2.1**.

## How it links, and why that way

DeckLink and Blackmagic RAW are header-and-dispatch: a `.cpp` shipped with the
headers dlopens the vendor's framework at runtime, so nothing links and a build
made without the SDK still runs wherever the vendor's software is installed.
RED ships a **static library that must be linked** — `libR3DSDK-libcpp.a` is
itself only the dispatch layer, and the obfuscated entry points it calls in
`REDR3D.dylib` are not an API anyone may bind to directly.

SwiftPM has three linker settings — `.linkedLibrary`, `.linkedFramework`,
`.unsafeFlags` — and neither of the first two can carry a library search path,
while `unsafeFlags` is off limits for a package we release. So the archive comes
in through a **binary target**: `vendor/R3DSDK.xcframework` is a single
`Info.plist` of ours whose `LibraryPath` and `HeadersPath` are relative paths
reaching back into this directory. That file is committed (it contains no RED
content); the SDK it points at is not.

`Package.swift` adds the binary target only when
`vendor/R3DSDK/Lib/mac64/libR3DSDK-libcpp.a` is actually on disk — a binary
target with a missing library is a hard package-graph error, not a stub. With
the drop absent, no `R3DSDK.h` is on the include path and `CR3D.mm` takes its
`#else` branch, the same switch `CBraw` and `CDeckLink` use.

### After adding or removing the SDK in an existing checkout, clear the caches

```sh
rm -rf .build ~/Library/Caches/org.swift.swiftpm/manifests
```

SwiftPM caches the evaluated manifest keyed on the manifest's **contents**, and
this one asks the filesystem a question. So dropping the SDK into a checkout that
has already been built leaves the cached "no SDK" graph in place — the app keeps
reporting R3D as unavailable with no explanation — and removing it leaves the
cached "SDK" graph, which fails the build outright with *missing inputs:
libR3DSDK-libcpp.a*. Neither `touch Package.swift` nor `rm -rf .build` alone is
enough: the manifest cache is shared and content-keyed, so reverting an edit
restores the stale answer with it. `swift build --manifest-cache none` works for
one build.

A fresh clone is never affected, which is why CI — no SDK, no caches, every push
— builds the stub correctly and always has.

## Runtime libraries

The static library dlopens `REDR3D.dylib`, which therefore has to be findable.
`CR3DClip` looks, in order:

1. `$TAKESHOT_R3D_LIBS` — how a checkout build and `takeshot-r3d` find them;
2. the app bundle's `Contents/Frameworks` — `scripts/bundle-app.sh` copies
   `REDR3D.dylib` there, and that is the only place a shipped app looks;
3. beside the executable, for `swift run` out of `.build`;
4. `vendor/R3DSDK/Redistributable/mac` relative to the working directory, so
   running from the checkout root needs no environment at all.

Only `REDR3D.dylib` is bundled: the bridge initializes with `OPTION_RED_NONE`
(CPU decoding), so `REDMetal`/`REDOpenCL`/`REDDecoder` would be ~28 MB of dead
weight. RED's instructions are explicit that these libraries must sit beside the
application and never in a central location, where they would collide with
another R3D-based app's copy.

**Shipping them is governed by RED's terms — read `SDK License Agreement.pdf`
in the archive before publishing a build that carries them.** A release without
them is a legitimate configuration: R3D playback is simply reported as
unavailable.

## Colour

R3D develops to REDWideGamutRGB / Log3G10 by default. A viewer that shows that
as if it were Rec.709 is showing a flat, milky image nobody can judge exposure or
focus on — and a viewer that quietly bakes the camera's look is lying the other
way. So the bridge runs the **full IPP2 pipeline with its Output Transform
pinned to Rec.709 / BT.1886**, and switches IPP2's **grading stage off**:

- **Stage 1, Primary Raw Development — kept as shot.** Kelvin, tint, ISO and
  exposure adjust come from the clip (and from an RMD sidecar if a DIT left one
  beside it). These are the exposure facts of the take, not a look.
- **Stage 2, Grading — off.** The camera's ASC CDL and its Creative 3D LUT are
  disabled unless the operator switches "Apply the camera 3D LUT" on in
  Settings. When a clip carries a LUT, the player says so either way.
- **Stage 3, Output Transform — RED's reference SDR transform to Rec.709.**
  Tone map and highlight roll-off are the SDK's documented defaults rather than
  the clip's RMD, so two clips off the same camera match each other on the
  viewer. A clip whose metadata asks for log output would otherwise arrive with
  the tone map switched off.

Legacy (ColorVersion2) and Broadcast (ColorVersionBC) clips take the same route
at their own colour version, with Rec.709 forced the same way. The gamma is
BT.1886 for IPP2 and Broadcast — IPP2 has no Rec.709 curve and substitutes
BT.1886 for it — and the Rec.709 transfer for Legacy. `MetalPreviewLayer` tags
every frame it presents with the ICC Rec.709 space, so what the decoder is asked
for and what the compositor is told agree.

The player states all of this on the codec plate in the RAW transport bar:
codec, decode scale, a swatch glyph when the clip carries a camera LUT, and a
tooltip naming the transform, the pipeline, the scale, the LUT and the camera's
own metadata. Nothing in this app named a colour space to the operator before
R3D, because nothing else had a choice to make.

## Performance

Decoding is the SDK's synchronous software decoder (`Clip::DecodeVideoFrame`),
which spreads one frame across its own threads. It is called from
`RawPlayerModel`'s detached decode task, never from the capture queue and never
from the main thread, and the play loop's existing skip-ahead keeps playback on
the clock when decode cannot: a slow clip drops frames instead of drifting.

**Decode scale defaults to a reduction**, because a video-assist viewer is
1080-class and an 8K full-res decode costs sixteen times a quarter-res one for
pixels the window cannot show. `Auto` takes the largest reduction that still
fills 1920 across (8K → 1/4, 6K and 4K → 1/2, 2K → full), stepping down if a
divisor does not divide both dimensions exactly — 5K FF is 5120x2700, and 2700/8
is not an integer, which would shear the picture. Settings offers Full, 1/2,
1/4 and 1/8 explicitly. Thumbnails always decode at 1/8.

Measured rates go here — run `takeshot-r3d` against a real clip:

```sh
TAKESHOT_R3D_LIBS=vendor/R3DSDK/Redistributable/mac \
  swift run -c release takeshot-r3d /path/to/A001_C001_0101XX_001.R3D
```

It prints the clip's metadata, what `Auto` resolved to, and the decode rate at
every scale. **The numbers are not in this file yet: nobody has had an `.r3d` on
this machine.** RED's SDK ships no sample clip and none can be synthesized, so
the decode path is the one part of R3D support that no test covers — see
`Tests/TakeShotKitTests/ModelR3DClipTests.swift` for everything that is tested
without footage. Sample clips: <https://www.red.com/sample-r3d-files>.

## Spanning clips

An R3D past 4 GB is written as `A001_C001_0101XX_001.R3D` … `_999.R3D`, and all
of it is **one clip** — `Clip::LoadFrom` pulls the parts in itself. The folder
scan therefore lists only the first part (`R3DSource.isContinuationPart`); a
part whose `_001` sibling is absent is still listed, because footage that does
not fit the convention is still footage. Nikon's single-file R3D NE clips
(`DSC_0001.R3D`, four digits) are untouched.
