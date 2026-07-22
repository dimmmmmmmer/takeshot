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
# SwiftPM target resources (localizations): Bundle.module looks for them in Contents/Resources
cp -R .build/release/TakeShot_TakeShot.bundle "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# ad-hoc signing is enough for local launch
codesign --force --sign - "$APP"

echo "Done: $APP"
