# libdatachannel (Paul-Louis Ageneau)

Slot for **libdatachannel**, a standalone C/C++ implementation of WebRTC's
transport layer. It is what lets TakeShot put the viewer on a phone or a laptop
browser on the set network as live video, with no plugin, no app to install and
no player to configure — a URL and a four-digit code.

## Why a library at all

macOS has no WebRTC of its own. What a browser needs before a single frame can
be decoded is ICE (candidate gathering, connectivity checks, the STUN binding
exchange between the two ends), DTLS with a self-signed certificate and a
fingerprint carried in the SDP, and then SRTP — every RTP packet encrypted and
authenticated with keys derived from that handshake. `Network.framework` offers
TCP, UDP, QUIC and TLS and nothing above them. Hand-rolling the rest is
guessing at three wire protocols on the far side of a link nobody can inspect
from here, which is the class of mistake that shows up as a black rectangle on
set and nowhere else.

**And deliberately not Google's `libwebrtc`.** That library brings its own
capturers, its own encoders, its own audio stack and its own build system — a
media pipeline this app already has, at a size and a build cost neither of us
wants. libdatachannel does the transport and NOTHING else: it has no encoder in
it at all, which is exactly right here. `SRTVideoEncoder` compresses the frame
once for every live consumer (`LiveVideoEncoder`), `RTPH264Packetizer` puts the
access unit in RTP, and this library carries the packet.

libdatachannel is **MPL-2.0**, which matters twice and both are in the licence
note at the bottom. (It was LGPL-2.1 before version 0.18; anything this project
would use is well past that.)

## Status

**Implemented, and a stub until the headers are here.** `Sources/CDataChannel`
is the bridge (`CDCPeerConnection`), wired the way `CDeckLink`, `CBraw` and
`CSRT` are: it compiles against the header in this directory when it is present
and builds as a stub when it is not. Nothing is committed here and nothing links
at build time.

- **Without the header** — CI, and every build until somebody drops it in: the
  app builds and ships as it always did, `CDCPeerConnection.isSDKAvailable` is
  `NO`, the `/live` page reports the feature as absent with the text of the next
  section as the reason, and every other page — including the camera grid, which
  is the JPEG path this replaces — behaves exactly as before.
- **With the header and the runtime**: the same page plays the viewer.

## Where to get it

There is no Homebrew formula, no MacPorts port and no pkg for it. That is a fact
with a consequence — see **Shipping it** below — and it means the drop is a
build from source:

```sh
git clone --recurse-submodules https://github.com/paullouisageneau/libdatachannel
cd libdatachannel
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DNO_EXAMPLES=ON -DNO_TESTS=ON \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
    -DOPENSSL_USE_STATIC_LIBS=ON
cmake --build build -j
```

Every flag on that list is load bearing:

- `BUILD_SHARED_LIBS=ON` — the bridge `dlopen`s a dylib. A static build produces
  nothing to open.
- `OPENSSL_USE_STATIC_LIBS=ON` — **this is what makes the result shippable.**
  Linked dynamically, `libdatachannel.dylib` carries a reference to
  `/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib`, a path that exists on the
  machine that built it and on nobody else's. Statically linked it has no
  non-system dependency at all: `otool -L` should show `libc++` and `libSystem`
  and nothing else, and `scripts/bundle-app.sh` refuses to bundle it otherwise.
- `CMAKE_OSX_ARCHITECTURES=arm64` — CMake follows the architecture of its OWN
  binary, and a Homebrew CMake installed under `/usr/local` is an x86_64 one.
  Without this the build fails at the link step against an arm64 OpenSSL, which
  reads as a hundred missing X.509 symbols and looks like a bad OpenSSL.
- `CMAKE_OSX_DEPLOYMENT_TARGET=15.0` — the app's floor
  (`Package.swift` says the same number, and so does `Resources/Info.plist`).
- `NO_EXAMPLES`/`NO_TESTS` — the examples pull in nlohmann JSON and a signalling
  server nobody here wants built.

Then copy two files and one library:

```text
vendor/libdatachannel/include/rtc/    rtc.h, version.h
vendor/libdatachannel/lib/            libdatachannel.dylib
```

`rtc.h` includes `"version.h"` relative to itself, so both go in; the C++
headers are deliberately NOT needed, because the bridge uses the C API only (the
reason is at the top of `Sources/CDataChannel/CDataChannel.mm`). The `rtc/`
subdirectory is not optional: the bridge includes `<rtc/rtc.h>`, the spelling
libdatachannel's own installs use, so a drop that flattens the directory fails
to compile rather than half-resolving.

Copy the REAL dylib rather than the `libdatachannel.dylib` symlink CMake leaves
beside it — a symlink into a build tree is a bundle step that silently produces
nothing.

Then `swift build`.

**0.20 or newer**, and 0.24 is what this was written against. The bridge resolves
thirteen entry points and reports which one is missing if the runtime is older.

## The runtime

`libdatachannel.dylib` is opened with `dlopen` the moment a page first offers —
never at launch, never at link time. The paths tried, in order:

1. `<TakeShot.app>/Contents/Frameworks/libdatachannel.dylib` — the copy a
   release ships (see below)
2. `/opt/homebrew/lib/libdatachannel.dylib`
3. `/usr/local/lib/libdatachannel.dylib`

Two and three are where `cmake --install` puts it on a machine that built it
from source, which is what a developer working on this feature has. When none of
them resolves, the page says so and lists every path that was looked at.

Thirteen symbols are resolved — `rtcCreatePeerConnection`,
`rtcClosePeerConnection`, `rtcDeletePeerConnection`, `rtcSetUserPointer`,
`rtcSetStateChangeCallback`, `rtcSetGatheringStateChangeCallback`,
`rtcSetRemoteDescription`, `rtcSetLocalDescription`, `rtcGetLocalDescription`,
`rtcAddTrackEx`, `rtcSendMessage`, `rtcIsOpen` and `rtcChainPliHandler` — and
each takes its type from the SDK header via `decltype`. **No part of the
libdatachannel ABI is hand-declared anywhere in this project.** Guessing the
layout of `rtcConfiguration` or `rtcTrackInit` would be silent memory
corruption, invisible until it mattered on a set, so the bridge is arranged such
that a wrong name or a changed signature is a compile error instead.

`rtcChainPliHandler` is the one symbol allowed to be missing, and its absence is
its own diagnosis: it lives behind `RTC_ENABLE_MEDIA`, so a copy built without
media support is caught here rather than showing up as a peer connection that
negotiates perfectly and carries no picture.

`rtcCleanup` is deliberately never called. It tears down process-wide state and
waits for every connection to close, and viewers come and go all day inside one
launch.

## What the app does with it

- **One peer connection per browser, host candidates only.** No STUN server and
  no TURN server is configured, because outside the set network is out of scope:
  the phone and the Mac are on one network by construction, so the only
  candidates worth gathering are this machine's own interfaces. A STUN lookup on
  a network with no route out is a gathering phase that ends in a timeout
  instead of in a picture.
- **Signalling is one POST**, on the server the phones already talk to, behind
  the PIN they already have (`RemoteWebRTC`). Both ends finish gathering before
  they speak, so one request and one response carry every candidate either end
  has — no trickle channel, no ordering to get wrong, nothing to keep open.
- **H.264 in RTP, and the app packetises it.** `MPEGTSMuxer.accessUnit(from:)`
  turns the encoder's sample into Annex B bytes with a 90 kHz stamp — the same
  seam the SRT output starts from — and `RTPH264Packetizer` puts it in RFC 6184
  packets, single-NAL and FU-A. libdatachannel is handed complete RTP packets
  and never looks inside one. The 90 kHz clock is not a conversion: RFC 6184
  fixes H.264's RTP clock rate at exactly the transport stream's, which is why
  one encoder can feed both.
- **The picture is the DECORATED viewer** — aids and chroma key included, the
  same frame the SRT output carries and the same frame the operator is looking
  at. That is deliberate and it has an open question behind it, written up at the
  top of `Sources/TakeShotKit/CaptureController+WebRTC.swift`.
- **Never on the capture queue, and never able to block it.** The encode is
  shared and runs on `com.takeshot.encode`; the packetising and the send run on
  `com.takeshot.webrtc`; the one call that really blocks — waiting for ICE
  gathering while an answer is built — has a serial queue of its own.
- **Picture only.** Audio is not carried, for the reason written up at the top
  of `Sources/TakeShotKit/CaptureController+SRT.swift`: the only stereo feed the
  pipeline produces belongs to the room speakers and is gated on their switch.

## Shipping it

**This slot is different from every other one in `vendor/`, and the difference
is the whole reason this section exists.** libsrt is one `brew install` away and
the DeckLink and Blackmagic RAW runtimes arrive with the vendor's own software,
so a build that only ever `dlopen`s a system copy finds one on the machines that
matter. libdatachannel is in no macOS package manager at all. A release that
did the same would find it on NOBODY's machine, and the feature would be dark
for every user except whoever built it.

So a release **bundles the dylib**: `scripts/bundle-app.sh` copies
`vendor/libdatachannel/lib/libdatachannel.dylib` into
`TakeShot.app/Contents/Frameworks/`, signs it with the same identity as the app,
and the `dlopen` search order above prefers that copy. Two checks guard it, and
both fail the build rather than shipping something broken:

- `otool -L` must show no non-system dependency. A dylib linked against
  Homebrew's OpenSSL would load on the build machine and fail on every other
  one — the worst kind of release, because it tests green where it was made.
- The architecture must match the app's.

**A build made WITHOUT the drop still builds, runs and ships**, exactly as
`CDeckLink` and `CBraw` do without theirs: `CDataChannel` compiles as a stub,
the `/live` page says the feature is absent and names what is missing, the
camera grid keeps working, and nothing else about the app is different. That is
what CI builds on every push, and it is what a release built on a machine with
no vendor drops is.

## Licence note

libdatachannel is **MPL-2.0** — and so are its bundled dependencies libjuice
(ICE) and plog; usrsctp is BSD-3-Clause and libsrtp is BSD-3-Clause. Built as
instructed above it also contains a static copy of **OpenSSL**, which is
Apache-2.0.

Two consequences, and they point in different directions:

- **Loading a runtime the machine already has distributes nothing.** A build
  made against this header and `dlopen`ing a dylib the user built carries no
  obligation: the MPL is file-level copyleft over the covered source files, and
  none of them are here.
- **Bundling the runtime DOES distribute it**, and this project intends to. The
  MPL then requires that the source of the covered files be available to
  recipients and that the licence text travel with the binary. libdatachannel is
  unmodified in that scenario, so pointing at
  `https://github.com/paullouisageneau/libdatachannel` at the matching tag
  satisfies it — but it has to actually be done, and the notice has to go in
  `NOTICE`, which is where the same obligation for libsrt is already written
  down. Apache-2.0 additionally requires OpenSSL's own notice to travel; that is
  in `NOTICE` too. Read `LICENSE` in the libdatachannel checkout, and the
  submodules', before publishing a release that carries the dylib.

Note the asymmetry with the camera vendors' SDKs: those may not be redistributed
at all, so a published build simply cannot have them. This one may be
redistributed, under terms — which is a decision to make rather than a door that
is closed, and it has been made.
