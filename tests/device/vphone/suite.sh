#!/bin/bash
# Interruption suite on the guest. Expects the island to show one test element.
# usage: suite.sh outdir
set -uo pipefail
here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
out="$1"; mkdir -p "$out"
run() { # name sequence seconds
    "$here/record.sh" "^seq:$2" "$out/$1.txt" "$3" >/dev/null
    printf '%-14s ' "$1"; "$here/foldcheck.py" "$out/$1.txt" | tail -2 | tr '\n' ' ' | cut -c1-260; echo
}
for d in 0.05 0.1 0.2 0.3 0.4 0.6; do run "fold-x-$d" "inc@0,dec@$d" 1.9; done
"$here/dumpfetch.sh" '^seq:inc@0' /dev/null >/dev/null; sleep 1.2
for d in 0.05 0.1 0.2 0.3 0.5 0.7; do run "unfold-x-$d" "dec@0,inc@$d" 1.9; done
seq=$(python3 -c 'import random; random.seed(11); t=0; s=[]
for i in range(20):
    s.append(("dec" if i%2==0 else "inc")+"@%.3f"%t); t+=random.uniform(0.05,0.16)
print(",".join(s))')
run rapid "$seq" 3.8
