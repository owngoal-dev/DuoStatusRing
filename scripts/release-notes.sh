#!/usr/bin/env bash
#
# release-notes.sh <tag> — render packaging/release-notes.md on stdout
# (release-notes-contract). Fixed headings; the injection summary and filter
# targets are read from packaging/TWEAK.plist at render time; status defaults to
# untested per flavor.

set -Eeuo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 <tag>" >&2; exit 64; }
tag="$1"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
template="$root/packaging/release-notes.md"
[[ -f "$template" ]] || { echo "error: missing $template" >&2; exit 66; }

# shellcheck source=../configuration/build.env
source "$root/configuration/build.env"
: "${TWEAK_NAME:?}" "${PACKAGE_ID:?}" "${MIN_IOS:?}"
version="$(tr -d '[:space:]' <"$root/configuration/version.txt")"

filter="$root/packaging/TWEAK.plist"
bundles="$(plutil -convert xml1 "$filter" -o - 2>/dev/null | grep -A20 -i 'Bundles' | grep -oE '<string>[^<]+' | sed 's/<string>//' | paste -sd', ' - || true)"
execs="$(plutil -convert xml1 "$filter" -o - 2>/dev/null | grep -A20 -i 'Executables' | grep -oE '<string>[^<]+' | sed 's/<string>//' | paste -sd', ' - || true)"
if [[ -n "$bundles" ]]; then
    injection="Bundles: \`$bundles\`."
elif [[ -n "$execs" ]]; then
    injection="Executables: \`$execs\`."
else
    injection="The filter targets classes only, or is absent."
fi
if grep -qiE 'com\.apple\.springboard|>SpringBoard<' <(plutil -convert xml1 "$filter" -o - 2>/dev/null); then
    injection="$injection Installing does not restart SpringBoard: respring when your preferred package manager offers it, or by hand, and the ring appears."
fi

kill_switch="jbroot(/var/mobile/Library/$PACKAGE_ID/disabled) on roothide, /var/jb/var/mobile/Library/$PACKAGE_ID/disabled on rootless"

# The author tokens (DuoStatusRing, Fold the status bar into a ring when the Dynamic Island splits.) are already filled at repo
# instantiation; this fills the packager and render-time tokens.
rendered="$(sed \
    -e "s|@PACKAGE_ID@|$PACKAGE_ID|g" \
    -e "s|@VERSION@|$version|g" \
    -e "s|@MIN_IOS@|$MIN_IOS|g" \
    -e "s|@INJECTION_SUMMARY@|$injection|g" \
    -e "s|@STATUS_ROOTHIDE@|- roothide (iphoneos-arm64e): works on iOS 26.6.2 (a virtual iPhone; the ring was checked with the payload placed where it installs, and the package installs, reinstalls and removes through a package manager without restarting SpringBoard)|g" \
    -e "s|@STATUS_ROOTLESS@|- rootless (iphoneos-arm64): untested|g" \
    -e "s|@KILL_SWITCH_PATH@|$kill_switch|g" \
    "$template")"

for heading in 'Which one do I download?' 'What gets injected and restarted' 'Status' 'Uninstall and kill switch' 'Verify your download'; do
    grep -qF "## $heading" <<<"$rendered" || { echo "error: release notes missing heading: $heading" >&2; exit 65; }
done
if grep -qE '@[A-Z_]+@' <<<"$rendered"; then
    echo "error: release notes still hold placeholders:" >&2
    grep -nE '@[A-Z_]+@' <<<"$rendered" | sed 's/^/    /' >&2
    exit 65
fi
printf '%s\n' "$rendered"
