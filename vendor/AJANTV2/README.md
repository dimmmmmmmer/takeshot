# AJA NTV2 SDK

Slot for AJA's NTV2 SDK, the counterpart to DeckLink for AJA capture cards
(Io, KONA, T-TAP). `CaptureBackend` in `Sources/CaptureCore` is the protocol an
AJA backend would implement alongside the existing DeckLink one.

## Status

**Not implemented yet.** No target reads this directory. The abstraction it
would plug into exists; the backend does not.

## Where to get it

Unlike the other vendored SDKs, this one is open source (MIT) — clone it rather
than downloading an archive:

```bash
git clone https://github.com/aja-video/libajantv2 vendor/AJANTV2/libajantv2
```

It is deliberately a plain clone and not a submodule: submodules make every
checkout and every CI run pay for a dependency that only matters to someone
building the AJA backend, and the repo already treats vendored SDKs as
something you fetch locally.

Capturing from AJA hardware also needs AJA's **Desktop Software** installed for
the driver, the same way DeckLink support needs Blackmagic Desktop Video.

## Licence note

libajantv2 is MIT, so unlike the RED and Blackmagic SDKs there is no
redistribution obstacle — it is kept out of the repository for size and
checkout speed, not for licensing.
