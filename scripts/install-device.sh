#!/usr/bin/env bash
#
# install-device.sh — install the matching .deb on a jailbroken device over SSH
# and run the smoke test (test-by-installing). Never copies the dylib: that skips
# package relocation and signing.
#
#   DEVICE_HOST  default 127.0.0.1     DEVICE_PORT default 4422
#   DEVICE_USER  default mobile        DEVICE_SUDO_PASSWORD only if sudo needs one

set -Eeuo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 <deb|package-directory>" >&2; exit 64; }
target="$1"; [[ -e "$target" ]] || { echo "error: no such path: $target" >&2; exit 66; }

host="${DEVICE_HOST:-127.0.0.1}"; port="${DEVICE_PORT:-4422}"; user="${DEVICE_USER:-mobile}"
sudo_password="${DEVICE_SUDO_PASSWORD:-}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../configuration/build.env
source "$root/configuration/build.env"
: "${PACKAGE_ID:?}"
version="$(tr -d '[:space:]' <"$root/configuration/version.txt")"

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$port")
remote="$user@$host"
on_device() { ssh "${ssh_opts[@]}" "$remote" "$@"; }

on_device true 2>/dev/null || { echo "error: cannot reach $remote:$port (over USB: iproxy $port:22 &)" >&2; exit 69; }
device_arch="$(on_device 'dpkg --print-architecture')"

if [[ -d "$target" ]]; then
    deb="$target/${PACKAGE_ID}_${version}_${device_arch}.deb"
    [[ -f "$deb" ]] || { echo "error: expected $deb for this device ($device_arch)" >&2; exit 66; }
else
    deb="$target"
fi
pkg_arch="$(dpkg-deb -f "$deb" Architecture)"
[[ "$pkg_arch" == "$device_arch" ]] || {
    echo "error: device installs '$device_arch', deb is '$pkg_arch'" >&2
    case "$device_arch" in
    iphoneos-arm64) echo "hint: install the rootless deb" >&2 ;;
    iphoneos-arm64e) echo "hint: install the roothide deb" >&2 ;;
    esac
    exit 65
}

echo "installing $(dpkg-deb -f "$deb" Package) $(dpkg-deb -f "$deb" Version) ($pkg_arch) on the device"
staged="/tmp/$(basename "$deb")"
scp -q -P "$port" -o BatchMode=yes "$deb" "$remote:$staged"
trap 'on_device "rm -f '"$staged"'" >/dev/null 2>&1 || true' EXIT

if on_device 'sudo -n true' 2>/dev/null; then
    run_priv() { on_device "sudo -n $1"; }
elif [[ -n "$sudo_password" ]]; then
    run_priv() { printf '%s\n' "$sudo_password" | ssh "${ssh_opts[@]}" "$remote" "sudo -S -p '' $1"; }
else
    echo "error: device sudo needs a password; set DEVICE_SUDO_PASSWORD" >&2; exit 77
fi
run_priv "dpkg -i $staged"

"$root/scripts/smoke-installed-tweak.sh"
