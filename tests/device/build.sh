#!/usr/bin/env bash
# Builds the development-only DuoStatusRingDebug.dylib (dumps, per-frame recorder,
# in-SpringBoard screen capture, simulated radios) for a vphone guest. Never part
# of a package.
set -euo pipefail
here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
root="$(cd -- "$here/../.." && pwd -P)"
out="${BUILD_DIR:-$root/build}/debug"
mkdir -p "$out"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun clang -isysroot "$sdk" -mios-version-min=16.0 -arch arm64e -fobjc-arc -O1 -g -Wall \
    -dynamiclib -install_name @rpath/DuoStatusRingDebug.dylib \
    -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
    -framework AVFoundation -framework CoreVideo -framework CoreMedia \
    "$here"/debug/*.m -o "$out/DuoStatusRingDebug.dylib"
ldid -S "$out/DuoStatusRingDebug.dylib"
echo "$out/DuoStatusRingDebug.dylib"
