# DeckLink SDK

Place the Blackmagic DeckLink SDK headers here (not committed to git — BMD license).

1. Download the "Desktop Video SDK": https://www.blackmagicdesign.com/support → Capture and Playback → Latest Downloads → Developer SDKs.
2. Unpack the archive.
3. Copy the **contents of the SDK's `Mac/include` folder** here, into `vendor/DeckLinkSDK/include/`:

```
vendor/DeckLinkSDK/include/
├── DeckLinkAPI.h
├── DeckLinkAPIDispatch.cpp
├── DeckLinkAPIVersion.h
└── … (the rest of the DeckLinkAPI*.h)
```

After that, `swift build` automatically builds the `CDeckLink` bridge with real device support (without the headers it builds as a stub: no devices are found, `isSDKAvailable == false`).

The runtime part (`/Library/Frameworks/DeckLinkAPI.framework`) ships with Blackmagic Desktop Video — already installed on this machine.
