# NDI SDK (Vizrt)

Slot for the NDI SDK, which would let TakeShot send the viewer over the set
network — a director's monitor on an iPad, a client feed in the production
office — without another cable or a second board output.

## Status

**Not implemented yet.** Nothing in the app reads this directory; the sender is
planned work, not a stub waiting for headers. The slot exists so the SDK is in
place and its terms are read before that starts.

## Where to get it

Download the **NDI SDK for Apple** from <https://ndi.video/for-developers/ndi-sdk/>
(free, registration required). The macOS installer puts the SDK under
`/Library/NDI SDK for Apple/`; either point the build at that location or copy
the parts below here:

```text
vendor/NDISDK/include/    Processing.NDI.*.h
vendor/NDISDK/lib/        libndi.dylib for arm64/x86_64
```

## Licence note

The NDI runtime may be redistributed inside an NDI-enabled application, but
only under Vizrt's SDK licence, which carries attribution and naming
requirements — the product has to identify NDI correctly and link to their
site. Read the licence in the SDK before shipping a release that includes the
sender, and nothing from the SDK is committed here.
