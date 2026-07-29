# R3D SDK (RED)

Place the RED R3D SDK here (not committed — RED's licence does not allow
redistribution).

1. Register at <https://www.red.com/developers> (free) and download the
   **R3D SDK** for macOS.
2. Unpack it and copy two things out of the archive:

```
vendor/R3DSDK/include/          ← the SDK's Include/ folder (R3DSDK*.h)
vendor/R3DSDK/lib/              ← the macOS static library from Lib/
```

3. The SDK also ships a **Redistributable** folder with the dynamic libraries
   the decoder loads at runtime. Those are copied into the app bundle by
   `scripts/bundle-app.sh` when they are present; leave them where the SDK put
   them and point the script at that path, or copy them to
   `vendor/R3DSDK/redistributable/`.

Without the SDK the `CR3D` bridge builds as a stub and `.r3d` files are
reported as unsupported, exactly like `CBraw` without the RAW SDK.

## How this one differs from the Blackmagic SDKs

DeckLink and Blackmagic RAW are header-and-dispatch: a `.cpp` in the headers
loads the framework at runtime, so a build made without them still runs on a
machine that has them. RED's SDK is a **static library that must be linked**,
plus redistributable dynamic libraries that must travel inside the app bundle.
That means:

- the `CR3D` target links `libR3DSDK` when it is present;
- a release built with R3D support only runs where the redistributables were
  bundled with it;
- the licence terms for shipping those redistributables are RED's — read them
  before publishing a build that includes R3D support.
