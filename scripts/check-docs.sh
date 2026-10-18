#!/usr/bin/env bash
#
# check-docs.sh — non-authoritative backstops for the reading review
# (facts-from-device, no-package-manager-names). A passing lint never counts as
# the review-gate-reading read.

set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
fail=0
err() { echo "error: $*" >&2; fail=1; }

# Prose/value files to scan.
mapfile -t docs < <(find . -type f \( -name '*.md' -o -name '*.json' -o -name '*.plist' -o -name 'control' -o -name 'release-notes.md' \) \
    -not -path './.git/*' -not -path './build/*' -not -path './stubs/roothide/LICENSE')

# 1. Device identifiers must never appear (facts-from-device). Bare 40-hex is a
#    git sha and is NOT flagged.
for f in "${docs[@]}"; do
    grep -nE '\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b' "$f" && err "$f: looks like a device UDID"
    grep -nE '\b[A-Za-z0-9-]+\.(local|lan)\b' "$f" && err "$f: device hostname (.local/.lan)"
    grep -nE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$f" | grep -vE '0\.0\.0|127\.0\.0\.1|>= [0-9]' && err "$f: IPv4 literal"
    grep -niE '(serial|serialnumber|ecid|hostname)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9]' "$f" && err "$f: a serial/ECID/hostname value"
done

# 2. Named package managers in prose/values (no-package-manager-names). Field
#    names (SileoDepiction), Depends ids and the low-level dpkg command are
#    allowed; jailbreak/injector product names are allowed.
managers='\b(Sileo|Zebra|Cydia|Installer|Saily|Aptitude)\b'
for f in "${docs[@]}"; do
    # strip allowed identifiers before scanning
    hits="$(grep -nE "$managers" "$f" | grep -vE 'SileoDepiction' || true)"
    [[ -n "$hits" ]] && { echo "error: $f names a package manager (say 'your preferred package manager'):" >&2; printf '%s\n' "$hits" | sed 's/^/    /' >&2; fail=1; }
done

# 3. control Maintainer/Author must not carry a personal host (control-fields).
if [[ -f packaging/DEBIAN/control ]]; then
    grep -E '^(Maintainer|Author):' packaging/DEBIAN/control | grep -nE '@[A-Za-z0-9.-]+\.(local|lan)\b|([0-9]{1,3}\.){3}[0-9]{1,3}' \
        && err "control Maintainer/Author carries a personal host"
fi

(( fail )) && exit 65
echo "==> docs lint ok (this is not the reading review)" >&2
