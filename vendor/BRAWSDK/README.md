# Blackmagic RAW SDK

Place the Blackmagic RAW SDK headers here — not committed, Blackmagic's licence
does not allow redistributing them.

1. Install the Blackmagic RAW SDK; it ships with the Blackmagic RAW installer
   from <https://www.blackmagicdesign.com/support> → Camera → Blackmagic RAW.
2. Copy these two files out of
   `/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/`:

```text
vendor/BRAWSDK/include/
├── BlackmagicRawAPI.h
└── BlackmagicRawAPIDispatch.cpp
```

Without the headers `CBraw` builds as a stub (`CBRClip.isSDKAvailable == NO`)
and `.braw` files are shown as unsupported. The runtime framework is loaded
dynamically — the app bundle's `Frameworks/` first, then
`/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries/`.
