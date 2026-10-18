#!/bin/bash
# Prints SpringBoard crash reports newer than the given epoch (default: last 10 minutes).
SOCK="$HOME/.vphone/machines/${VPHONE_MACHINE:?set VPHONE_MACHINE to the vphone machine name}/vphone.sock"
since="${1:-$(( $(date +%s) - 600 ))}"
printf '%s\n' '{"t":"rpc","method":"logs.crashes"}' | nc -U "$SOCK" | python3 -c 'import json,sys
d=json.load(sys.stdin)["result"]; items=d if isinstance(d,list) else (d.get("reports") or d.get("crashes") or [])
new=[c for c in items if c["process"]=="SpringBoard" and c["mtime"]>float(sys.argv[1])]
print("SpringBoard crashes since %s: %d" % (sys.argv[1], len(new))); [print(" ", c["name"]) for c in new]' "$since"
