#!/bin/bash
# SwiftLint runner.
#
# SwiftLint needs sourcekitd, and SourceKitten looks for it inside a toolchain
# directory. With Xcode installed that resolves itself; with only the Command
# Line Tools there is no Toolchains directory, but sourcekitdInProc.framework
# is right there under usr/lib — pointing TOOLCHAIN_DIR at the CLT root is all
# it takes. Without this the linter dies with "Loading sourcekitdInProc failed".
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "swiftlint not found — install it with: brew install swiftlint" >&2
    exit 127
fi

if [ -z "${TOOLCHAIN_DIR:-}" ] && [ ! -d "$(xcode-select -p)/Toolchains" ]; then
    export TOOLCHAIN_DIR="$(xcode-select -p)"
fi

exec swiftlint "$@"
