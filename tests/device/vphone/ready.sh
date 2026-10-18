#!/bin/bash
# Brings the guest to an unlocked home screen after a respring.
V=/Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli
M="${VPHONE_MACHINE:?set VPHONE_MACHINE to the vphone machine name}"
SOCK="$HOME/.vphone/machines/$M/vphone.sock"
state() { printf '%s\n' '{"t":"rpc","method":"ui.describe"}' | nc -U "$SOCK" | python3 -c 'import json,sys
try:
    s=json.load(sys.stdin)["result"]["screen"]; print("locked" if s["locked"] or s["screen_off"] else "open")
except Exception: print("down")'; }
for i in $(seq 1 10); do
    sleep 1.5
    [ "$(state)" = open ] && { printf '%s\n' '{"t":"key","name":"home","screen":false}' | nc -U "$SOCK" >/dev/null; sleep 0.8; echo ready; exit 0; }
    $V guest unlock "$M" >/dev/null 2>&1
done
echo "not ready"; exit 1
