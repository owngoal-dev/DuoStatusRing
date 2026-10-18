#!/bin/bash
# usage: dumpfetch.sh "<command list text>" out.txt
# Writes the command list into the guest, posts the dump notification, fetches the
# result and clears the command list again (a leftover "!" command would replay).
set -euo pipefail
SOCK="$HOME/.vphone/machines/${VPHONE_MACHINE:?set VPHONE_MACHINE to the vphone machine name}/vphone.sock"
rpc() { python3 -c 'import json,sys; print(json.dumps({"t":"rpc","method":sys.argv[1],"params":json.loads(sys.argv[2])}))' "$1" "$2" | nc -U "$SOCK"; }
LIST=/var/mobile/Library/Caches/dli_classes.txt
OUT=${DLI_DUMP_PATH:-/var/mobile/Library/Caches/dli_dump.txt}
rpc files.write "$(python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"content":sys.argv[2]}))' "$LIST" "$1")" >/dev/null
rpc notify.post '{"name":"app.yellowplus.dli.dump"}' >/dev/null
sleep ${DLI_DUMP_WAIT:-1.5}
rpc files.write "{\"path\":\"$LIST\",\"content\":\"\"}" >/dev/null
rpc files.read "{\"path\":\"$OUT\",\"limit\":4000000}" | python3 -c 'import json,sys; d=json.load(sys.stdin); open(sys.argv[1],"w").write(d["result"]["content"]); print(len(d["result"]["content"]), d["result"].get("truncated"))' "$2"
