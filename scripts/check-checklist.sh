#!/bin/sh
# Refuse to build until the repo's one-time checklist is fully ticked.
#
# A new tweak repo starts from template/CHECKLIST.md. Every box is a decision
# that is cheap before the first release and a migration after, so `make check`
# runs this first and every build target depends on it. Adapted from
# the app-packaging skill (not a shared contract).
#
# Usage: check-checklist.sh [<checklist>]      default: CHECKLIST.md
#
# Exit 0 when every item is ticked; 65 when any item is open, there are no items,
# or a malformed box line appears (* [ ], - [] , -[ ]); 66 when the file is
# missing. Items are lines starting (after indentation) with - [ ], - [x] or
# - [X]. Fenced code blocks are ignored.

set -eu

file="${1:-CHECKLIST.md}"

if [ ! -f "$file" ]; then
    echo "error: $file is missing; copy it from the platformize-tweak-ios template and work through it" >&2
    exit 66
fi

awk '
BEGIN { fence=0; total=0; open=0; malformed=0 }
/^[[:space:]]*```/ { fence = !fence; next }
fence { next }
# malformed box lines that look like an item but are not the exact form
/^[[:space:]]*\* \[[ xX]\]/ { malformed++; print "    malformed (use - not *): " $0 > "/dev/stderr"; next }
/^[[:space:]]*-\[[ xX]?\]/  { malformed++; print "    malformed (space after -): " $0 > "/dev/stderr"; next }
/^[[:space:]]*- \[\]/       { malformed++; print "    malformed (empty box): " $0 > "/dev/stderr"; next }
/^[[:space:]]*- \[[ xX]\]/  {
    total++
    if ($0 ~ /^[[:space:]]*- \[ \]/) { open++; print "    open: " $0 > "/dev/stderr" }
    next
}
END {
    if (malformed > 0) { print "error: " FILENAME " has " malformed " malformed box line(s)" > "/dev/stderr"; exit 65 }
    if (total == 0)    { print "error: " FILENAME " has no checklist items" > "/dev/stderr"; exit 65 }
    if (open > 0)      { print "error: " FILENAME " has " open " of " total " items unticked; nothing builds until all are ticked" > "/dev/stderr"; exit 65 }
    print "ok: all " total " items in " FILENAME " are ticked"
}
' "$file"
