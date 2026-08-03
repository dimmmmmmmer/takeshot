#!/bin/bash
# Builds TakeShot.app from a SwiftPM release build (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/TakeShot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TakeShot "$APP/Contents/MacOS/TakeShot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM target resources (localizations): Bundle.module looks for them in
# Contents/Resources. The bundle is named after the target that owns the
# resources — TakeShotKit since the app layer became a library.
RESOURCE_BUNDLE=".build/release/TakeShot_TakeShotKit.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "missing $RESOURCE_BUNDLE — localizations would be absent" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# RED's R3D runtime, when this build was made against the SDK. Unlike DeckLink
# and Blackmagic RAW — installed system-wide by the vendor's own software and
# loaded from there — RED's libraries are redistributables that have to travel
# INSIDE the app: "do not install them in a central location", per the SDK's own
# instructions, because they would collide with another R3D application's copy.
# Contents/Frameworks is the only place a shipped app looks (see CR3D.mm).
#
# Only REDR3D.dylib: the bridge initializes with OPTION_RED_NONE (CPU decode),
# so REDMetal/REDOpenCL/REDDecoder would be ~28 MB of dead weight.
#
# NOT re-signed: RED signs it themselves (team 4ER5V66EKT) and `codesign` on the
# bundle without --deep leaves nested code alone, which is what we want. It is
# another team's library, so the same library-validation rule as the Blackmagic
# frameworks applies — see the signing comment below.
#
# Redistributing it is governed by RED's licence (SDK License Agreement.pdf in
# the vendor drop). A build made without the SDK simply has no R3D playback and
# says so in the player.
R3D_RUNTIME="vendor/R3DSDK/Redistributable/mac/REDR3D.dylib"
if [ -f "$R3D_RUNTIME" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp "$R3D_RUNTIME" "$APP/Contents/Frameworks/"
    echo "Bundled R3D runtime: $(basename "$R3D_RUNTIME")"
else
    echo "No R3D runtime bundled — .r3d clips will report the SDK as missing"
fi

# Which commit this build IS. The running app has no git around it, so the
# answer has to be baked in here — "Collect diagnostics" reads it back out of
# Info.plist (CaptureController.gitSHAInfoKey) and a bundle that cannot say
# which build produced it is most of the way to useless. Left absent rather
# than faked outside a checkout; "unavailable" is a truthful report.
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$GIT_SHA" ]; then
    if ! git diff --quiet HEAD 2>/dev/null; then
        GIT_SHA="$GIT_SHA-dirty"
    fi
    /usr/libexec/PlistBuddy -c "Add :TakeShotGitSHA string $GIT_SHA" \
        "$APP/Contents/Info.plist" >/dev/null
fi

# Ad-hoc signing is enough to launch locally, but its cdhash changes on every
# build, so macOS treats each build as a new app and TCC grants do not stick.
# Export CODESIGN_IDENTITY to a Developer ID ("Developer ID Application: Name
# (TEAMID)") once you have one and the grants survive rebuilds.
IDENTITY="${CODESIGN_IDENTITY:--}"
# Library validation (part of the hardened runtime) refuses frameworks signed
# by another team unless the app carries disable-library-validation — and
# DeckLinkAPI/BlackmagicRAW ARE another team's frameworks. An ad-hoc identity
# has no team at all, so a hardened ad-hoc build can never load them: the
# bundled app was device-blind while every unbundled build saw the board
# (reproduced by re-signing the CLI probe both ways). Ad-hoc builds therefore
# sign WITHOUT the hardened runtime; a real Developer ID keeps it, with the
# entitlement notarization allows.
if [ "$IDENTITY" = "-" ]; then
    codesign --force --timestamp=none --sign - "$APP"
    echo "Signed ad-hoc (no hardened runtime: library validation would block"
    echo "the Blackmagic frameworks). Set CODESIGN_IDENTITY for a stable signature."
else
    codesign --force --options runtime --timestamp=none \
        --entitlements scripts/takeshot.entitlements --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
fi

echo "Done: $APP"

# An app INSIDE ~/Documents (or Desktop/Downloads) needs the Documents TCC
# permission just to read its own resource bundle, and an ad-hoc signature
# changes with every build — so macOS treats each build as a new app and asks
# again, every single launch, blocking startup until it is answered.
# Installing outside the protected folders makes the question go away entirely:
# the app itself never touches Documents (takes go to the chosen record folder).
# Set TAKESHOT_NO_INSTALL=1 to skip (CI only wants build/TakeShot.app).
case "$PWD/" in
    "$HOME/Documents/"*|"$HOME/Desktop/"*|"$HOME/Downloads/"*)
        if [ -z "${TAKESHOT_NO_INSTALL:-}" ]; then
            INSTALLED="$HOME/Applications/TakeShot.app"
            mkdir -p "$HOME/Applications"
            rm -rf "$INSTALLED"
            cp -R "$APP" "$INSTALLED"
            echo "Installed: $INSTALLED"
            echo "  (launch this copy — the one under $PWD is inside a" \
                 "protected folder and macOS asks for Documents access on" \
                 "every ad-hoc build)"
        fi
        ;;
esac
