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

# ad-hoc signing is enough for local launch
codesign --force --sign - "$APP"

echo "Done: $APP"
