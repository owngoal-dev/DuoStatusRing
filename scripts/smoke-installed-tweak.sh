#!/usr/bin/env bash
#
# smoke-installed-tweak.sh — after install-device.sh has installed the deb, check
# on-device that the tweak is in place and injects (test-by-installing). Derives
# paths from the installed flavor. Reports works/nosupport/untested per flavor.
#
# This runs against a device; with none attached it prints untested and exits 0.
# It never claims injection without a positive signal (dylib mapped or the marker
# log line), and cannot see per-app injection exclusion (roothide-injection-blacklist).

set -Eeuo pipefail
host="${DEVICE_HOST:-127.0.0.1}"; port="${DEVICE_PORT:-4422}"; user="${DEVICE_USER:-mobile}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../configuration/build.env
source "$root/configuration/build.env"
: "${TWEAK_NAME:?}" "${PACKAGE_ID:?}"

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$port")
remote="$user@$host"
on_device() { ssh "${ssh_opts[@]}" "$remote" "$@"; }

if ! on_device true 2>/dev/null; then
    echo "untested: no device attached"
    echo "untested: per-app injection exclusion state unknown"
    exit 0
fi

arch="$(on_device 'dpkg --print-architecture')"
case "$arch" in iphoneos-arm64) prefix="/var/jb"; flavor=rootless ;; iphoneos-arm64e) prefix=""; flavor=roothide ;; *) echo "untested: unknown device architecture $arch"; exit 0 ;; esac

dylib="$prefix/Library/MobileSubstrate/DynamicLibraries/$TWEAK_NAME.dylib"
filter="$prefix/Library/MobileSubstrate/DynamicLibraries/$TWEAK_NAME.plist"
status=works
for path in "$dylib" "$filter"; do
    on_device "test -e '$path'" || { echo "nosupport ($flavor): $path missing after install"; status=nosupport; }
done

# A positive injection signal: the marker log line at default level, if the log
# is readable. Absent that, this stays untested for injection.
echo "untested ($flavor): live injection into a target is a device observation"
echo "untested ($flavor): per-app injection exclusion state unknown (check the jailbreak manager)"
echo "$status ($flavor): package files are in place where the loader reads"
