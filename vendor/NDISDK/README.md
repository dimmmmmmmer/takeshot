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

Only six symbols are resolved — `NDIlib_initialize`, `NDIlib_version`,
`NDIlib_send_create`, `NDIlib_send_destroy`, `NDIlib_send_send_video_v2` and
`NDIlib_send_send_audio_v3` — and each takes its type from the SDK header via
`decltype`. No part of the NDI ABI is hand-declared anywhere in this project:
guessing a struct layout or an argument list would be silent memory corruption,
invisible until it mattered on a set, so the bridge is arranged such that a wrong
name or a changed signature is a compile error instead.

**Five of the six are REQUIRED and the audio one is not**, which is a promise
rather than a leniency: adding sound must not be able to take the picture away.
The header this build compiles against declares `NDIlib_send_send_audio_v3` (it
is SDK 4 and newer, the same floor the FourCC spellings already set), but the
dylib loaded at runtime is whatever the machine has — two different facts. A
runtime that resolves the picture send and not the sound one therefore stays
fully available and carries picture; `CNDSender.isAudioAvailable` answers NO and
the leg above it stops. Folding it into the required set would turn a mismatched
runtime into "NDI unavailable", i.e. a director's monitor going dark over their
sound. Measured here: both `/usr/local/lib/libndi.4.dylib` and
`/Library/NDI SDK for Apple/lib/macOS/libndi.dylib` export it.

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
- **Sound goes too, off the tap the SRT output already uses.**
  `CapturePipeline.feedStereo` builds ONE stereo mix per packet — after
  `recordAudio`, so nothing it does can reach the file — and hands the same
  buffer to the cart's speakers and to every registered consumer, independent of
  the monitor switch. `NDIAudioMirror` is the NDI consumer, and the only thing
  that differs from SRT's leg is what happens after: interleaved 16-bit becomes
  the de-interleaved 32-bit float `NDIlib_FourCC_audio_type_FLTP` names, scaled
  by 1/32768 (so −32768 lands on exactly −1.0). The channels are the first two
  ENABLED by the mask in force — the same expression the record path reads — so
  what goes out is always a prefix of what is being written, and a rig whose
  only live channel is 6 sends MONO rather than a doubled fake pair.
- **The sound is on its OWN queue** (`com.takeshot.ndi-audio`), not the
  picture's. Both sends are synchronous and either can park for as long as its
  receiver makes it, so one queue would mean a stalled picture holding up its own
  sound. `CNDSender` serializes the sender's LIFETIME and nothing else: `stop`
  marks it closed without waiting, and whichever send is last out destroys the
  instance. A rwlock would have been the obvious primitive and is the wrong one —
  a `stop` waiting for the write lock behind a wedged picture send blocks the
  next sound send behind it.
- **No timecode is stated on either leg.** Both ask the runtime to synthesize
  (`NDIlib_send_timecode_synthesize`), which is the SDK's own documented
  configuration for two streams staying in sync: one sender takes the system time
  as its origin once and generates both series from it. The packet's own
  presentation time is the pipeline's stream clock and has no defined
  relationship to NDI's 100 ns timecode domain, so converting it would be
  inventing an origin.
- **Unlike the picture, the sound is not coalesced.** The frame leg keeps only
  the newest frame; sound cannot, because NDI synthesizes the audio timecode from
  the samples it is handed, so a dropped packet is both a hole and a permanent
  shift against the picture. The sound queue is a FIFO with a one-second backlog
  ceiling (48 000 sample frames, ~384 KB of stereo); past it a packet is refused
  and counted, which only happens once the receiver has stopped taking sound at
  all.
- **Measured cost on the capture queue** — release, minimum of nine passes over
  400 packets, 8-channel source, against a 40 ms packet interval:
  12.9 µs/packet with NDI off, 12.9 with NDI's PICTURE up (the sound leg is the
  only part of this feature that touches this queue at all), 18.4 with any one
  consumer on the tap (the stereo mix, which the first consumer pays for
  whichever transport it is) and 22.9 with NDI's sound. The conversion itself is
  1.17 µs mono and 2.29 µs stereo for a 1920-frame packet, and it is NOT on that
  queue — it runs behind the hop, on the sound's own. The frame path is unmoved
  by the sound being up: 0.008 ms at 1080p either way.

## What has now been executed, and what still has not

The headers are in on the development machine, so the real half of `CNDI.mm`
compiles and RUNS here for the first time. What that has established, by running
it rather than by reading it:

- `CNDSender.isSDKAvailable()` and `isAudioAvailable()` are both true here: the
  runtime loaded, `NDIlib_initialize` returned true, and all six symbols resolved
  out of the installed dylib. `NDIRealBridgeTests` asserts it and runs in the
  normal battery wherever the headers are.
- `NDIlib_send_send_audio_v3` is CALLABLE with the frame this bridge builds — the
  FLTP FourCC, the plane stride, the synthesized timecode — against a real sender
  on a real runtime, without the runtime rejecting it or walking off the end of
  the planes. That is `NDILiveSenderTests`, and it is OPT-IN
  (`TAKESHOT_NDI_LIVE=1`) because creating a sender ANNOUNCES a source on
  whatever LAN the machine is on, which on a shoot is the set network. It has
  been run deliberately and it passes.
- The shape guard on the audio send is not defensive politeness. With it removed,
  the real runtime handed `no_samples = 0` kills the process with SIGFPE —
  measured, as a planted regression.

**Still unverified, and only a receiver can answer it.** Nothing here proves that
a receiver DECODES any of it: that VLC, OBS, Resolve or an NDI monitor shows the
picture, that the sound plays, that the two land in lip sync, or that the
synthesized timecode behaves as the SDK's note describes when the picture leg is
dropping frames and the sound leg is not. Those need a receiver, a network and a
person. The app-side costs above are measured; NDI's own compression, which
happens inside the send, is still not separable from here.

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
