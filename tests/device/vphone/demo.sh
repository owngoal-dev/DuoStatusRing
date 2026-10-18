#!/bin/bash
# Records the demo: home screen fold/unfold, interruptions, data changes while folded,
# and an app with a dark status bar. usage: demo.sh out.mp4
set -uo pipefail
here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
SOCK="$HOME/.vphone/machines/${VPHONE_MACHINE:?set VPHONE_MACHINE to the vphone machine name}/vphone.sock"
d() { "$here/dumpfetch.sh" "$1" /dev/null >/dev/null; }
rpc() { printf '%s\n' "{\"t\":\"rpc\",\"method\":\"$1\",\"params\":$2}" | nc -U "$SOCK" >/dev/null; }
RADIO=4,3,5,10,5,,9:41
d "^radios:$RADIO,82,0,0"; sleep 1
d '^capture:start:110:60'; sleep 1.2
d '^seq:inc@0'; sleep 2.2                              # one activity
d '^seq:inc@0'; sleep 2.6                              # split: fold
d '^seq:dec@0'; sleep 2.4                              # merge: unfold
d '^seq:inc@0'; sleep 2.4                              # fold again
d '^seq:dec@0,inc@0.35,dec@0.7,inc@1.0'; sleep 3       # interrupted back and forth
for r in "4,1,5,10,5,,9:41,82,0,0" "1,1,5,10,5,,9:41,82,0,0" "0,-2,1,0,0,,9:41,82,0,0" "$RADIO,82,0,0" \
         "$RADIO,15,0,0" "$RADIO,40,1,0" "$RADIO,60,0,1" "$RADIO,82,0,0"; do
    d "^radios:$r"; sleep 1.6                           # data changes while folded
done
d '^seq:dec@0'; sleep 2.2                              # unfold
rpc apps.launch '{"bundle_id":"com.apple.Preferences"}'; sleep 2
d '^seq:inc@0'; sleep 2.6                              # fold over a dark status bar
d '^seq:dec@0'; sleep 2.2
rpc input.button '{"name":"home"}'; sleep 1.2
d '^capture:stop'
printf '%s\n' '{"t":"rpc","method":"files.read","params":{"path":"/var/mobile/Library/Caches/dli_capture.mp4","binary":true,"limit":60000000}}' \
    | nc -U "$SOCK" | python3 -c 'import json,sys,base64; d=json.load(sys.stdin); open(sys.argv[1],"wb").write(base64.b64decode(d["result"]["content"]))' "$1"
