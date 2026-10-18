#!/usr/bin/env bash
# Puts the roothide package's payload on a vphone guest, with the development
# dylib next to it, and resprings. vphoned has no dpkg entry point, so this stands
# in for installing the deb: the files written are extracted from the deb that
# `make deb-roothide` built, byte for byte, at the path dpkg would install them
# (on roothide /Library/MobileSubstrate/DynamicLibraries is a link to
# usr/lib/TweakInject). DEBUG=0 leaves the development dylib out.
#   VPHONE_MACHINE: the vphone machine name (required)
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
machine="${VPHONE_MACHINE:?set VPHONE_MACHINE to the vphone machine name}"
sock="$HOME/.vphone/machines/$machine/vphone.sock"
deb="$(ls -t "$root"/build/pkg/*_iphoneos-arm64e.deb 2>/dev/null | head -1)"
[[ -n "$deb" ]] || { echo "build the package first: make deb-roothide" >&2; exit 66; }
stage="$(mktemp -d /private/tmp/duostatusring-deploy.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
dpkg-deb -x "$deb" "$stage"
lib="$stage/Library/MobileSubstrate/DynamicLibraries"

rpc() { printf '%s\n' "$1" | nc -U "$sock"; }
jbroot="$(rpc '{"t":"rpc","method":"device.info"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["jailbreak"]["jbroot"])')"
dest="$jbroot/usr/lib/TweakInject"
put() { # put <local> <remote>
    python3 - "$1" "$2" <<'PY' | nc -U "$sock" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r.get("ok"), r; print("wrote", r["result"]["path"])'
import base64, json, sys
data = base64.b64encode(open(sys.argv[1], "rb").read()).decode()
print(json.dumps({"t": "rpc", "method": "files.write", "params": {"path": sys.argv[2], "content": data, "encoding": "base64"}}))
PY
}
put "$lib/DuoStatusRing.dylib" "$dest/DuoStatusRing.dylib"
put "$lib/DuoStatusRing.plist" "$dest/DuoStatusRing.plist"
rpc "{\"t\":\"rpc\",\"method\":\"files.chmod\",\"params\":{\"path\":\"$dest/DuoStatusRing.dylib\",\"mode\":\"755\"}}" >/dev/null
if [[ "${DEBUG:-1}" == 1 ]]; then
    debug="$("$root/tests/device/build.sh" | tail -1)"
    put "$debug" "$dest/DuoStatusRingDebug.dylib"
    put "$lib/DuoStatusRing.plist" "$dest/DuoStatusRingDebug.plist"
    rpc "{\"t\":\"rpc\",\"method\":\"files.chmod\",\"params\":{\"path\":\"$dest/DuoStatusRingDebug.dylib\",\"mode\":\"755\"}}" >/dev/null
else
    for f in DuoStatusRingDebug.dylib DuoStatusRingDebug.plist; do
        rpc "{\"t\":\"rpc\",\"method\":\"files.remove\",\"params\":{\"path\":\"$dest/$f\"}}" >/dev/null || true
    done
fi
rpc '{"t":"rpc","method":"system.respring","params":{"force":true}}' >/dev/null
echo "respring requested"
