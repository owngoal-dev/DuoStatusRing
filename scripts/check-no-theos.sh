#!/usr/bin/env bash
#
# check-no-theos.sh — prove Theos is not used as a build system (no-theos).
#
# Theos may only ever be an INPUT: a Theos sdks/iPhoneOS*.sdk used as a custom
# -isysroot (data), never $(THEOS) makefiles, common.mk/tweak.mk, Logos
# (.x/.xm/.xmi, line-leading %hook/%ctor/%orig/%group, logo.pl/logify) or
# roothide-theos.h. Nothing Theos-derived is committed or packaged.
#
# Scans BUILD INPUTS only: makefile*, *.mk, scripts/, source files. Excludes
# *.md, LICENSE, docs/, Licenses/ and this script itself, where "Theos" appears
# as prose about the SDK-as-data.

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
self="scripts/check-no-theos.sh"
fail=0

# Files to scan: build inputs, not prose.
inputs() {
    find . -type f \
        \( -name 'makefile' -o -name 'Makefile' -o -name '*.mk' -o -name '*.sh' \
           -o -name '*.c' -o -name '*.h' -o -name '*.m' -o -name '*.mm' \
           -o -name '*.cpp' -o -name '*.swift' -o -name '*.env' -o -name '*.txt' \
           -o -name '*.yml' -o -name '*.yaml' \) \
        -not -path './.git/*' -not -path './build/*' \
        -not -path './docs/*' -not -path './Licenses/*' -not -path './*.md' \
        -not -path "./$self" \
        -print
}

scan() { # regex label
    local hits
    hits="$(inputs | xargs grep -nE "$1" 2>/dev/null || true)"
    if [[ -n "$hits" ]]; then
        echo "error: Theos-as-build-system reference ($2):" >&2
        printf '%s\n' "$hits" | sed 's/^/    /' >&2
        fail=1
    fi
}

scan '\$\(THEOS'                       'THEOS makefile variable'
scan '\bTHEOS\b'                       'THEOS name'
scan '(^|/)(common|tweak)\.mk'         'Theos makefile include'
scan '^[[:space:]]*%(hook|ctor|orig|group|end|new)\b' 'Logos directive'
scan 'logos\.pl|logify'                'Logos preprocessor'
scan 'roothide-theos\.h'              'Theos roothide header'

# File-type bans.
bad_ext="$(find . -type f \( -name '*.x' -o -name '*.xm' -o -name '*.xmi' \) -not -path './.git/*' -not -path './build/*' || true)"
[[ -n "$bad_ext" ]] && { echo "error: Logos sources present:" >&2; printf '%s\n' "$bad_ext" | sed 's/^/    /' >&2; fail=1; }

sdk_dirs="$(find . -type d -name '*.sdk' -not -path './.git/*' -not -path './build/*' || true)"
[[ -n "$sdk_dirs" ]] && { echo "error: an SDK is committed (external input, never vendor):" >&2; printf '%s\n' "$sdk_dirs" | sed 's/^/    /' >&2; fail=1; }

stray_tbd="$(find . -type f -name '*.tbd' -not -path './stubs/*' -not -path './.git/*' -not -path './build/*' || true)"
[[ -n "$stray_tbd" ]] && { echo "error: a .tbd outside stubs/ (write your own MIT stub in stubs/):" >&2; printf '%s\n' "$stray_tbd" | sed 's/^/    /' >&2; fail=1; }

(( fail )) && exit 65
echo "==> no Theos build dependency; Theos SDKs are inputs only" >&2
