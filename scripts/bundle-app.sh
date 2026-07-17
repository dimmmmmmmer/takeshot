#!/bin/bash
# Собирает TakeShot.app из release-сборки SwiftPM (Xcode не требуется).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/TakeShot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TakeShot "$APP/Contents/MacOS/TakeShot"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# ad-hoc подпись достаточно для локального запуска
codesign --force --sign - "$APP"

echo "Готово: $APP"
