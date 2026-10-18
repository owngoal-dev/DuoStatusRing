#!/usr/bin/env bash
#
# macho-lib.sh — sourced, not run. The one Mach-O test every gate shares.
#
# Decided by the first four bytes, never by `file -b`: `file` prefixes the
# description with "setuid "/"setgid "/"sticky " when a mode bit is set, so a
# `== Mach-O*` match silently skips exactly the binaries the setuid check exists
# for.

# is_macho <path> — 0 for a thin (32/64-bit, either endianness) or fat Mach-O.
is_macho() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in
    cffaedfe | feedfacf | cefaedfe | feedface | cafebabe | cafebabf) return 0 ;;
    *) return 1 ;;
    esac
}
