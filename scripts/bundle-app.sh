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

# Ad-hoc signing is enough to launch locally, but its cdhash changes on every
# build, so macOS treats each build as a new app and TCC grants do not stick.
# Export CODESIGN_IDENTITY to a Developer ID ("Developer ID Application: Name
# (TEAMID)") once you have one and the grants survive rebuilds.
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
if [ "$IDENTITY" = "-" ]; then
    echo "Signed ad-hoc. Set CODESIGN_IDENTITY for a stable signature."
else
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
