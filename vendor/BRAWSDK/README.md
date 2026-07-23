# Blackmagic RAW SDK

Place the Blackmagic RAW SDK headers here (not committed — BMD license).

1. Install the "Blackmagic RAW SDK" (ships with the Blackmagic RAW installer,
   https://www.blackmagicdesign.com/support → Camera → Blackmagic RAW).
2. Copy from `/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/`:

```
vendor/BRAWSDK/include/
├── BlackmagicRawAPI.h
└── BlackmagicRawAPIDispatch.cpp
```

Without the headers `CBraw` builds as a stub (`CBRClip.isSDKAvailable == NO`)
and .braw files are shown as unsupported. The runtime framework is loaded from
`/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries/`.
