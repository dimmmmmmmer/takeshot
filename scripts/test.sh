#!/bin/bash
# Run the tests on a machine with Command Line Tools but no Xcode.
#
# Testing.framework in CLT lives outside the standard search paths, and SwiftPM
# passes its directory only through -I (not enough for a framework). The flags
# below must also reach the SwiftPM-generated test runner, so they're passed
# globally rather than in Package.swift. With Xcode installed a plain
# `swift test` is enough.
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
INTEROP_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

# --no-parallel: the pipeline e2e test encodes ProRes in real time;
# parallel writer tests steal the encoder from it and cause flakes
if [ ! -d "$FRAMEWORKS/Testing.framework" ]; then
    exec swift test --no-parallel "$@"
fi

exec swift test --no-parallel \
    -Xswiftc -F"$FRAMEWORKS" \
    -Xlinker -F"$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$INTEROP_LIB" \
    "$@"
