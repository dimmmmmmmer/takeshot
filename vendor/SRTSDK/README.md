# libsrt (Haivision)

Slot for **libsrt**, the reference implementation of SRT (Secure Reliable
Transport). It is what lets TakeShot send the viewer to an address on the set
network — a director's monitor running VLC, a Resolve station, an OBS machine, a
cloud gateway — over a link that drops packets.

## Why a library at all

macOS has no SRT of its own. AVFoundation writes files and VideoToolbox encodes
frames; neither speaks a transport, and `Network.framework` offers TCP, UDP,
QUIC and TLS and nothing above them. SRT is not a socket flavour — it is
automatic repeat request over UDP with a timestamp-based delivery buffer, a
handshake, congestion control and AES key exchange. Hand-rolling that would be
guessing at a wire protocol on the far side of a link nobody can inspect from
here, which is the class of mistake that shows up as a stutter on set and
nowhere else. So: the reference implementation, loaded at run time.

libsrt is **MPL-2.0**, which matters twice and both are in the licence note at
the bottom.

## Status

**Implemented, and a stub until the headers are here.** `Sources/CSRT` is the
bridge (`CSRTSender`), wired the way `CDeckLink`, `CBraw` and the retired NDI
bridge were: it compiles against the headers in this directory when they are
present and builds as a stub when they are not. Nothing is committed here and
nothing links at build time.

- **Without the headers** — CI, and every build until somebody drops them in:
  the app builds and ships as it always did, `CSRTSender.isSDKAvailable` is
  `NO`, and the SRT switch in Settings reports itself unavailable with the text
  of the next section as the reason. Off by default, so nothing changes for
  anyone who does not go looking.
- **With the headers**: the same switch encodes the viewer and sends it.

## Where to get it

```sh
brew install srt
```

That is the whole of it — unlike the camera vendors' SDKs there is no
registration and no licence click-through. Copy the headers here:

```text
vendor/SRTSDK/include/srt/    srt.h, logging_api.h, platform_sys.h, udt.h,
                              version.h, access_control.h  (the whole set —
                              they include each other)
```

The `srt/` subdirectory is not optional: `Sources/CSRT/CSRT.mm` includes
`<srt/srt.h>`, the spelling libsrt's own installs use, so a drop that flattens
the directory fails to compile rather than half-resolving.

Then `swift build`. Nothing else: there is no library to copy for the build,
because the runtime is loaded at run time (next section).

**1.5 or newer.** `SRTO_PEERLATENCY` and the `SRTT_LIVE` transmission type both
predate 1.4, but `srt_getversion` does not exist before 1.3.2 and the bridge
reports the runtime's version in Settings, so an older header fails to compile
here rather than building something that cannot say what it loaded.

## The runtime

`libsrt` is opened with `dlopen` the moment the operator first switches the
feature on — never at launch, never at link time. The paths tried, in order:

1. `<TakeShot.app>/Contents/Frameworks/libsrt.dylib` — a release that ships the
   runtime itself (read the licence note below first)
2. `/opt/homebrew/lib/libsrt.dylib` — Homebrew on Apple silicon
3. `/opt/homebrew/lib/libsrt.1.5.dylib`
4. `/usr/local/lib/libsrt.dylib` — Homebrew on Intel, and MacPorts
5. `/usr/local/lib/libsrt.1.5.dylib`

When none of them resolves, Settings says so and lists every path that was
looked at.

Twelve symbols are resolved — `srt_startup`, `srt_getversion`,
`srt_create_socket`, `srt_setsockflag`, `srt_bind`, `srt_listen`, `srt_accept`,
`srt_connect`, `srt_send`, `srt_close`, `srt_getlasterror` and
`srt_getlasterror_str` — and each takes its type from the SDK header via
`decltype`. **No part of the SRT ABI is hand-declared anywhere in this
project.** Guessing a struct layout or an argument list would be silent memory
corruption, invisible until it mattered on a set, so the bridge is arranged such
that a wrong name or a changed signature is a compile error instead. That is
also why `srt_send` is used rather than `srt_sendmsg2`: the two do the same
thing for a live stream and only the second one needs `SRT_MSGCTRL`'s layout to
be right.

`srt_cleanup` is deliberately never called. It tears down libsrt's process-wide
state, and the app can switch the feature off and on again inside one launch.

## What the app does with it

- **One stream out, no discovery.** SRT is a transport, not an announcement:
  where NDI put a name in every receiver's list, SRT needs an address, a port
  and a role. Both roles are offered — **caller** dials the receiver
  (`srt://host:port`, the one that works when this Mac is behind NAT) and
  **listener** waits for the receiver to dial in (the one that works when the
  receiver is). Nothing is ever received: this is an output.
- **MPEG-TS over the link, H.264 inside it.** SRT carries a transport stream, so
  the display frames are encoded (VideoToolbox, hardware, `SRTVideoEncoder`) and
  packetised (`MPEGTSMuxer`, 188-byte packets, seven to a 1316-byte datagram —
  `SRT_LIVE_DEF_PLSIZE`, which is 188 × 7 for exactly this reason). H.264 High
  and not HEVC because every SRT receiver decodes it; frame reordering is off,
  so a picture is one frame behind the monitor rather than a GOP behind it.
- **Never on the capture queue, and never able to block it.** The encode, the
  mux and the send all run on `com.takeshot.srt` with latest-wins coalescing,
  and the socket is opened non-blocking for sending — a link that cannot take
  the bytes returns "again" and the frame is dropped rather than waited on. The
  measured app-side cost is in `SRTPerformanceTests`.
- **A dead link is a notice and a reconnect**, which on a venue network is the
  normal case rather than the exception. See `SRTVideoMirror` for the backoff
  and `CaptureController+SRT` for what the operator is shown.
- **Picture only.** SRT and MPEG-TS both carry audio perfectly well; the reason
  this does not is about where the app's stereo feed comes from, and it is
  written up at the top of `Sources/TakeShotKit/CaptureController+SRT.swift`.

## Licence note

libsrt is **MPL-2.0**. Two consequences, and they point in different
directions:

- **Loading a runtime the machine already has distributes nothing.** A build
  made against these headers and `dlopen`ing Homebrew's dylib is the ordinary
  case and carries no obligation: the MPL is file-level copyleft over the
  covered source files, and none of them are here.
- **Bundling the runtime (path 1 above) does distribute it.** The MPL then
  requires that the source of the covered files be made available to the
  recipients, and that the licence text travel with the binary. libsrt is
  unmodified in that scenario, so pointing at `https://github.com/Haivision/srt`
  at the matching tag satisfies it — but it has to actually be done, and the
  notice has to go in `NOTICE`. Read `LICENSE` in the libsrt checkout before
  shipping a release that carries the dylib.

Note the asymmetry with the camera vendors' SDKs: those may not be
redistributed at all, so a published build simply cannot have them. This one
may be redistributed, under terms — which is a decision to make rather than a
door that is closed.

## After you copy them in

SwiftPM does not watch this directory, so a target already built as a stub
stays a stub: `isSDKAvailable` keeps answering NO with the headers sitting
right here. Touch the bridge's `.mm` (or delete `.build`) and rebuild.
Measured once on BRAW, where it cost a confused half hour.
