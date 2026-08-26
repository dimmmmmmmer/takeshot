# DeckLink SDK

Place the Blackmagic DeckLink SDK headers here — not committed, Blackmagic's
licence does not allow redistributing them.

1. Download the "Desktop Video SDK" from
   <https://www.blackmagicdesign.com/support> → Capture and Playback → Latest
   Downloads → Developer SDKs.
2. Unpack the archive.
3. Copy the **contents of the SDK's `Mac/include` folder** into
   `vendor/DeckLinkSDK/include/`:

```text
vendor/DeckLinkSDK/include/
├── DeckLinkAPI.h
├── DeckLinkAPIDispatch.cpp
├── DeckLinkAPIVersion.h
└── … the rest of the DeckLinkAPI*.h
```

`swift build` then builds the `CDeckLink` bridge with real device support.
Without the headers it builds as a stub: no devices are found and
`CDLDeviceManager.isSDKAvailable == false`.

The runtime half, `/Library/Frameworks/DeckLinkAPI.framework`, ships with
Blackmagic Desktop Video and is loaded dynamically, so a build made without the
headers still runs on a machine that has Desktop Video installed.

## After you copy them in

SwiftPM does not watch this directory, so a target already built as a stub
stays a stub: `isSDKAvailable` keeps answering NO with the headers sitting
right here. Touch the bridge's `.mm` (or delete `.build`) and rebuild.
Measured once on BRAW, where it cost a confused half hour.
