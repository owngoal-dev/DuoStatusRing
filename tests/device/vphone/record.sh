#!/bin/bash
# usage: record.sh "<dump command list>" out.txt [seconds]
# Starts the in-SpringBoard recorder, runs the dump commands (for example a test
# recipe), waits, stops and fetches the per-frame log.
set -euo pipefail
here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
SOCK="$HOME/.vphone/machines/${VPHONE_MACHINE:?set VPHONE_MACHINE to the vphone machine name}/vphone.sock"
rpc() { printf '%s\n' "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":$2}" | nc -U "$SOCK"; }
rpc notify.post '{"name":"app.yellowplus.dli.record.start"}' >/dev/null
DLI_DUMP_WAIT=0.3 "$here/dumpfetch.sh" "$1" /dev/null >/dev/null
sleep "${3:-1.6}"
rpc notify.post '{"name":"app.yellowplus.dli.record.stop"}' >/dev/null
sleep 0.5
rpc files.read '{"path":"/var/mobile/Library/Caches/dli_animations.txt","limit":8000000}' | python3 -c 'import json,sys; d=json.load(sys.stdin); open(sys.argv[1],"w").write(d["result"]["content"])' "$2"
