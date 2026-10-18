#!/usr/bin/env bash
# audit-ios-floor.sh — prove every built Mach-O can load on the floor it claims
# (deployment-floor). package-deb.sh runs it on the staged payload before
# signing; it also takes any file or directory by hand.
#
#   audit-ios-floor.sh <floor> <path> [<path> …]
#
# Exit 0 when everything fits the floor, 65 otherwise. `error:` = cannot load;
# `note:` = must be guarded in source (this script cannot see whether it is).
# Every check prints why it failed: nothing here may exit non-zero silently.

set -Eeuo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 <floor> <path> [<path> …]" >&2; exit 64; }
floor="$1"; shift
[[ "$floor" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "error: bad floor '$floor'" >&2; exit 64; }
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=macho-lib.sh
source "$root/scripts/macho-lib.sh"
fail=0

version_key() { local IFS=.; local p=($1 0 0); printf '%d' $(( ${p[0]} * 10000 + ${p[1]} * 100 + ${p[2]} )); }
floor_key="$(version_key "$floor")"
above_floor() { (( $(version_key "$1") > floor_key )); }

# Libraries and runtime symbols that first shipped after a given iOS.
late_libraries=(
    "libswiftXPC.dylib:16.0"
    "libswiftObservation.dylib:17.0"
    "libswiftSpatial.dylib:17.0"
    "libswiftSynchronization.dylib:18.0"
    "libswiftRealityKit.dylib:18.0"
)
late_runtime_symbols=(
    "_swift_initBorrow:27.0"
)

check_one() {
    local binary="$1" arch line entry lib minv minos imports weak
    for arch in $(lipo -archs "$binary"); do
        # minos per slice (vtool prints one LC_BUILD_VERSION per slice)
        minos="$(vtool -arch "$arch" -show-build "$binary" 2>/dev/null | awk '$1 == "minos" {print $2; exit}')"
        if [[ -z "$minos" ]]; then
            echo "error: $binary ($arch) has no LC_BUILD_VERSION minos" >&2; fail=1
        elif above_floor "$minos"; then
            echo "error: $binary ($arch) is built for iOS $minos, above the floor $floor" >&2; fail=1
        fi

        # strong links to a library newer than the floor
        while IFS= read -r line; do
            [[ "$line" == *", weak)"* ]] && continue
            for entry in "${late_libraries[@]}"; do
                lib="${entry%%:*}"; minv="${entry##*:}"
                if [[ "$line" == *"/$lib "* ]] && above_floor "$minv"; then
                    echo "error: $binary ($arch) links $lib (iOS $minv) but claims $floor" >&2; fail=1
                fi
            done
        done < <(otool -arch "$arch" -L "$binary" | tail -n +2)

        # strong imports of a runtime symbol newer than the floor
        imports="$(nm -m -arch "$arch" "$binary" 2>/dev/null | awk '$1 == "(undefined)" && $2 == "external" {print $3}' | sort -u)"
        for entry in "${late_runtime_symbols[@]}"; do
            lib="${entry%%:*}"; minv="${entry##*:}"
            if grep -qxF "$lib" <<<"$imports" && above_floor "$minv"; then
                echo "error: $binary ($arch) imports $lib (iOS $minv) non-weakly but claims $floor" >&2; fail=1
            fi
        done

        weak="$(nm -m -arch "$arch" "$binary" 2>/dev/null | grep 'weak external' | grep -v FORCE_LOAD || true)"
        if [[ -n "$weak" ]]; then
            echo "note: $binary ($arch) weak-imports (guard each in source):" >&2
            sed 's/^/    /' <<<"$weak" >&2
        fi
    done
}

for path in "$@"; do
    [[ -e "$path" ]] || { echo "error: no such path: $path" >&2; exit 66; }
    n=0
    while IFS= read -r -d '' candidate; do
        is_macho "$candidate" || continue
        n=$((n + 1))
        check_one "$candidate"
    done < <(find "$path" -type f -print0)
    if (( n == 0 )); then echo "error: no Mach-O in $path" >&2; fail=1; fi
done

# Availability must never be silenced (deployment-floor): no pragma in the
# sources, no -Wno flag in the build script or makefile. The flag is spelled in
# two pieces so a scan of scripts/ can never match this file itself.
silencer='-Wno-unguarded-''availability'
if grep -rnF '#pragma clang diagnostic ignored "-Wunguarded-availability' "$root/src" >&2; then
    echo "error: an availability pragma silences the floor check" >&2; fail=1
fi
if grep -nF -- "$silencer" "$root/scripts/build-ios.sh" "$root/makefile" >&2; then
    echo "error: a $silencer flag silences the floor check" >&2; fail=1
fi

if (( fail )); then echo "error: this product cannot load on iOS $floor" >&2; exit 65; fi
echo "==> every Mach-O fits iOS $floor" >&2
