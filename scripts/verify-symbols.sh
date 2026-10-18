#!/usr/bin/env bash
#
# verify-symbols.sh <role> <mach-o> — the import denylist (import-denylist).
#
#   role dylib  | bundle : full gate (injected code / prefs bundle)
#   role helper          : same, minus symbols recorded as exceptions in AGENTS.md
#
# Runs `nm -m` on every arm64/arm64e slice of the final linked Mach-O and fails
# on an undefined external import of a process-spawning, credential-changing or
# networking symbol. Injected code must start children with posix_spawn only;
# lowering priority, setpgid and setsid stay allowed. This is a best-effort
# check: dlsym and raw syscalls are caught in review.

set -Eeuo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <dylib|bundle|helper> <mach-o>" >&2; exit 64; }
role="$1"; file="$2"
case "$role" in dylib | bundle | helper) ;; *) echo "error: role must be dylib, bundle or helper" >&2; exit 64 ;; esac
[[ -f "$file" ]] || { echo "error: no such file: $file" >&2; exit 66; }

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

denied=(
    _fork _vfork
    _execl _execle _execlp _execv _execve _execvp _execvP _execvpe _fexecve
    _system _popen _daemon
    _setuid _seteuid _setreuid _setgid _setegid _setregid _setgroups _initgroups
    _socket _getaddrinfo
)

# Helper exceptions: a line in AGENTS.md of the form `import-exception: _name`.
allowed_exceptions=""
if [[ "$role" == helper && -f "$root/AGENTS.md" ]]; then
    allowed_exceptions="$(grep -oE 'import-exception:[[:space:]]*_[A-Za-z0-9_]+' "$root/AGENTS.md" \
        | sed -E 's/.*(_[A-Za-z0-9_]+)$/\1/' || true)"
fi

is_excepted() {
    local sym="$1"
    [[ -n "$allowed_exceptions" ]] && grep -qxF "$sym" <<<"$allowed_exceptions"
}

mapfile -t slices < <(lipo -archs "$file" 2>/dev/null | tr ' ' '\n' | grep -v '^$' || echo "")
[[ ${#slices[@]} -gt 0 ]] || slices=("")

fail=0
for arch in "${slices[@]}"; do
    if [[ -n "$arch" ]]; then
        symbols="$(nm -m -arch "$arch" "$file" 2>/dev/null || true)"
    else
        symbols="$(nm -m "$file" 2>/dev/null || true)"
    fi
    # Line shape: "(undefined) external _sym (from libX)" — the name is field 3,
    # never $NF (which is the library).
    undefined="$(awk '$1=="(undefined)" && $2=="external"{print $3}' <<<"$symbols" | sort -u)"
    for sym in "${denied[@]}"; do
        if grep -qxF "$sym" <<<"$undefined"; then
            if [[ "$role" == helper ]] && is_excepted "$sym"; then
                echo "note: $file ($arch) imports $sym (recorded exception in AGENTS.md)" >&2
                continue
            fi
            echo "error: $file ($arch) imports $sym (import-denylist)" >&2
            fail=1
        fi
    done
done

if (( fail )); then
    echo "posix_spawn is the one way to start a child; record a helper exception in AGENTS.md as 'import-exception: _name'." >&2
    exit 65
fi
echo "==> import denylist clean: $file ($role)" >&2
