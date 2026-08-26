# NDI SDK (Vizrt)

Slot for the NDI SDK, which lets TakeShot announce the viewer as a source on the
set network — a director's monitor on an iPad, a client feed in the production
office — without another cable or a second board output.

## Status

**Implemented, and a stub until the headers are here.** `Sources/CNDI` is the
bridge (`CNDSender`), wired the way `CDeckLink`, `CBraw`, `CSRT` and
`CDataChannel` are: it compiles against the headers in this directory when they
are present and builds as a stub when they are not. Nothing is committed here and
nothing links at build time.

- **Without the headers** — CI, every published release, and every build until
  somebody downloads the SDK: the app builds, launches and does everything else
  it did, `CNDSender.isSDKAvailable` is `NO`, and the NDI switch in Settings
  reports itself unavailable with the text of the next section as the reason. Off
  by default, so nothing changes for anyone who does not go looking.
- **With the headers**: the same switch announces an NDI source and sends the
  viewer to it. See "What the app does with it" below.

**NDI is beside SRT rather than instead of it**, and that is the owner's call
after having asked for the opposite once. The two answer different rooms. NDI
announces itself and a receiver picks it out of a list, so it needs a switch and
a name and there is no handshake to be on the wrong side of — which is what makes
it the right one when the receiver is on the same LAN. SRT is a transport: it has
to be told where to send and in which role, which is what makes it the one that
can cross a network somebody else runs. Neither is a fallback for the other.

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

## After you copy them in

SwiftPM does not watch this directory, so a target already built as a stub
stays a stub: `isSDKAvailable` keeps answering NO with the headers sitting
right here. Touch `Sources/CNDI/CNDI.mm` (or delete `.build`) and rebuild.
Measured once on BRAW, where it cost a confused half hour.

## The runtime

`libndi` is opened with `dlopen` the moment the operator first switches the
feature on — never at launch, never at link time. The paths tried, in order:

1. `<TakeShot.app>/Contents/Frameworks/libndi.dylib` — a release that ships the
   runtime itself (read the licence note below first)
2. `/usr/local/lib/libndi.dylib`
3. `/usr/local/lib/libndi.4.dylib`
4. `/opt/homebrew/lib/libndi.dylib`
5. `/opt/homebrew/lib/libndi.4.dylib`
6. `/Library/NDI SDK for Apple/lib/macOS/libndi.dylib`

Installing **NDI Tools**, or the SDK itself, puts the runtime in one of them. When
none of them resolves, Settings says so and lists every path that was looked at.

`libndi.3.dylib` is deliberately not on that list. An NDI Tools install from the
SDK-3 era leaves one behind, and this bridge is compiled against SDK 4 spellings
— loading a 3 runtime would resolve some names and not others, which is a worse
failure than not finding it at all.

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
  mirror slot as the DeckLink playout output and the SRT stream, and follows the
  viewer between live, playback and RAW exactly as that output does. It is
  deliberately NOT the clean frame the phone camera grid gets: that grid is a
  crew monitoring surface where the operator's own tools would lie to it, whereas
  an NDI feed replaces a cable to somebody watching over the operator's shoulder.
- **It is NOT a consumer of the shared H.264 encoder**, and that is the one
  structural thing to know about this output. The SRT stream and every WebRTC
  viewer take samples off one `LiveVideoEncoder`; NDI's SDK takes FRAMES and
  compresses them with a codec of its own inside the send call, so this bridge
  hangs off the display buffer directly, beside the DeckLink feeder. Two network
  outputs running at once therefore cost the display queue one pixel-format test
  and one `dispatch_async` each, and share no queue at all downstream: a wedged
  NDI receiver cannot delay a browser's picture, and an SRT reconnect cannot
  delay NDI.
- **BGRX, full range, Rec.709 primaries and transfer, progressive.** That is what
  the app's display buffer already holds and what an NDI receiver already reads
  uncompressed RGB as, so there is no conversion in the path at all — the sender
  is handed the pixel buffer's own base address at its own row stride. BGRX
  rather than BGRA because the fourth byte is padding, not alpha.
- **The frame rate is stated as an exact rational** — 24000/1001, never 23.976.
  NDI declares the rate on the wire and a receiver handed a rounded one has to
  guess at the pull-down. This is the one piece of the design SRT did not need:
  MPEG-TS and RTP both timestamp on a 90 kHz clock and have no rate field.
- **Never on the capture queue.** The send runs on `com.takeshot.ndi` with
  latest-wins coalescing, so a slow network drops frames instead of delaying the
  recorder. Measured app-side cost of the whole hop, release, median of 15:
  0.014 ms at 1080p, 0.018 ms at UHD, against a 40 ms frame interval at 25 fps.
  NDI's own compression happens inside the send and is not in that figure — it
  cannot be measured until the headers are here, and the budget above is what is
  left for it.
- **Picture only.** NDI carries audio and this does not send any. The obstacle is
  not the NDI leg — it is that the pipeline's only stereo feed is the room
  monitor's, owned by `AudioMonitor` and gated on its switch, so a feed hung off
  it would tie a director's sound to whether the operator has the cart's speakers
  up. The SRT output is blocked on exactly the same missing piece: one
  independent tap in `CapturePipeline+Audio`. The reasoning and where each leg
  attaches is at the top of `Sources/TakeShotKit/CaptureController+NDI.swift`
  and `CaptureController+SRT.swift`. This gap has not moved since the feature
  was first written; it has only gained a second claimant.

## Not measured on this machine

Everything under "The runtime" and the real half of `CNDI.mm` is **unverified
code**. The development machine has the NDI runtime installed
(`/usr/local/lib/libndi.4.dylib`) and no SDK headers anywhere, so the bridge
compiles as a stub here and every claim about what happens with the headers in
place — that the five symbols resolve, that `NDIlib_send_create` announces a
source a receiver can find, that BGRX at the buffer's own stride reads correctly
on the far end, and that the app-side cost holds up once NDI's own compression is
inside the send — rests on the previous implementation of this file rather than
on a measurement taken since it came back. Drop the headers in and it is one
`swift build` and one receiver away from being checked.

## Licence note

**The SDK is free and carries no royalty.** Checked on Vizrt's licensing page
before this feature was restored: the download costs nothing, and there is no
per-unit fee and no revenue threshold behind it. What the licence asks for is
attribution and correct naming, not money — so "is NDI worth what it costs" is a
question about obligations rather than about a bill. The registration form is a
signature, which is why the download is the owner's to make and not an agent's.

The NDI runtime may be redistributed inside an NDI-enabled application, but only
under Vizrt's SDK licence, which carries attribution and naming requirements —
the product has to identify NDI correctly and link to their site. That is
unlike libsrt and libdatachannel, which are MPL-2.0 and whose obligations are
about source availability rather than naming. Read the licence in the SDK before
shipping a release that bundles the runtime (path 1 above); nothing about the
stub build, or about a build that loads a runtime the machine already has,
distributes any of it. No release bundles it today.
