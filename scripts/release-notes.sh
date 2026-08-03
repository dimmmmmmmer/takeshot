#!/bin/bash
# The body of a GitHub Release, printed to stdout.
#
# Two halves, and they are separate on purpose:
#
#   1. The version's section of CHANGELOG.md — what changed, written for an
#      operator who last used the previous build. It is in the repository
#      because the notes have to be reviewable in the pull request that makes
#      the change, not typed into a web form on tag day.
#   2. What THIS download actually is. That is a property of the machine the
#      artifact was built on, not of the version, so it cannot live in the
#      changelog: a GitHub runner has none of the vendor SDKs, and the bridges
#      that need them ship as stubs. Rather than assert that in prose that goes
#      stale the moment a build is made somewhere else, the block below is
#      MEASURED off the checkout the build used — the same four paths the
#      package and the bridges test with __has_include.
#
# Usage: scripts/release-notes.sh [version] [path/to/TakeShot.app]
#   version   defaults to the VERSION file
#   app       when given, its architectures are read off the binary and stated.
#             Optional so that the workflow can run this BEFORE the build, as a
#             cheap check that the notes exist at all, and again afterwards for
#             the real body.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' VERSION \
    | head -1 | tr -d '[:space:]')}"
APP="${2:-}"

# The section from its heading to the next one, heading itself dropped: the
# release page shows the version in its own title already.
notes="$(awk -v want="$VERSION" '
    /^## / {
        if (inside) exit
        # "## 0.2.0 — 2026-08-03" — compare the version token alone.
        if ($2 == want) { inside = 1; next }
    }
    inside { print }
' CHANGELOG.md)"

if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
    echo "CHANGELOG.md has no '## $VERSION' section — write the notes before" \
         "tagging." >&2
    exit 1
fi

# The blank line that follows every heading would otherwise open the release
# body with an empty paragraph. Trailing blanks are already gone: command
# substitution eats them.
printf '%s\n' "$notes" | sed '/./,$!d'

# Which bridges are real in this build. Each path is the exact file the
# corresponding target tests for — keep these in step with Package.swift
# (the R3D archive) and the four __has_include guards in Sources/C*/.
sdk_state() {
    if [ -f "$2" ]; then echo "- $1: **built in**"
    else echo "- $1: **stub** — $3"
    fi
}

cat <<'HEADER'

---

## What this download is

HEADER

sdk_state "Blackmagic DeckLink" "vendor/DeckLinkSDK/include/DeckLinkAPI.h" \
    "no capture device is visible to this build at all; it opens, plays back
  existing footage and runs its demo source, but it cannot record from a
  board. Build from source with the DeckLink SDK to capture."
sdk_state "Blackmagic RAW" "vendor/BRAWSDK/include/BlackmagicRawAPI.h" \
    "\`.braw\` clips do not open."
sdk_state "RED R3D" "vendor/R3DSDK/Lib/mac64/libR3DSDK-libcpp.a" \
    "\`.r3d\` clips are recognised and reported as unsupported."
sdk_state "NDI" "vendor/NDISDK/include/Processing.NDI.Lib.h" \
    "network output reports itself unavailable."

cat <<'FOOTER'

None of these SDKs may be redistributed, so a build published from CI has none
of them. `CONTRIBUTING.md` says where each one goes; the app's **Collect
diagnostics** report states which are live in the copy you are running.

Signed ad hoc, not with a Developer ID — the first launch needs a right-click →
**Open** rather than a double-click. macOS 14 (Sonoma) or newer.
FOOTER

# Which Macs this particular download runs on — MEASURED, not assumed. A plain
# `swift build` produces a binary for the machine that ran it, and the runner
# this is published from is Apple silicon, so the download is arm64 unless
# somebody deliberately makes it universal. Claiming "Apple Silicon or Intel"
# in prose was wrong for every build that has ever come out of this workflow.
if [ -n "$APP" ] && [ -x "$APP/Contents/MacOS/TakeShot" ]; then
    archs="$(lipo -archs "$APP/Contents/MacOS/TakeShot" 2>/dev/null || true)"
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*)
            echo "Universal: runs on Apple Silicon and Intel." ;;
        *arm64*)
            echo "Apple Silicon only (\`arm64\`). An Intel Mac needs a build" \
                 "from source." ;;
        *x86_64*)
            echo "Intel only (\`x86_64\`). An Apple Silicon Mac runs it under" \
                 "Rosetta." ;;
        *) ;;  # unreadable: say nothing rather than guess
    esac
fi
