#!/usr/bin/env bash
# Builds the host-side fold tests (timeline and geometry, the pure parts of the
# tweak) into a temporary directory and runs them on the Mac.
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
out="$(mktemp -d /private/tmp/duostatusring-tests.XXXXXX)"
trap 'rm -rf "$out"' EXIT
xcrun clang -fobjc-arc -Wall -O1 -I"$root/src" -framework Foundation -framework CoreGraphics \
    "$root/tests/host/DLIFoldTests.m" "$root/src/DLIFoldGeometry.m" "$root/src/DLIFoldTimeline.m" -o "$out/DLIFoldTests"
"$out/DLIFoldTests"
