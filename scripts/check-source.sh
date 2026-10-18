#!/usr/bin/env bash
#
# check-source.sh — source-level rules for injected code and packaging templates
# (jbroot-by-scheme, data-locations, hook-logging-privacy, hooks-without-logos,
# hook-type-encoding-check, prefs-read-propagation, constructor-safe-mode).

set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
fail=0; warn=0
err() { echo "error: $*" >&2; fail=1; }
note() { echo "warning: $*" >&2; warn=1; }

jbpath="src/tw_jbpath.h"

# 1. Literal /var/jb may appear only in tw_jbpath.h; not in shared source,
#    DEBIAN scripts or plist templates. (The check-docs/verify-payload gates
#    cover packaging output; here we cover the tracked templates.) The regex
#    excludes /var/jbsomething like /var/jbconfig.plist.
scan_jb() {
    local files hits
    files="$(find src packaging -type f \( -name '*.h' -o -name '*.m' -o -name '*.mm' -o -name '*.c' -o -name '*.cpp' -o -name '*.swift' -o -name '*.plist' \) 2>/dev/null | grep -v "^$jbpath$" || true)"
    hits="$(printf '%s\n' "$files" | xargs grep -nE '/var/jb(/|["'"'"']|$)' 2>/dev/null || true)"
    # DEBIAN maintainer scripts are @PREFIX@ templates; they must not hardcode /var/jb either.
    local deb; deb="$(grep -rnE '/var/jb(/|["'"'"']|$)' packaging/DEBIAN 2>/dev/null | grep -vE '^\s*#|:\s*#' || true)"
    if [[ -n "${hits// }" || -n "${deb// }" ]]; then
        echo "error: literal /var/jb outside $jbpath:" >&2
        printf '%s\n%s\n' "$hits" "$deb" | grep . | sed 's/^/    /' >&2
        fail=1
    fi
}
scan_jb

# 2. No literal rootfs paths in injected source outside the path macro: a
#    literal is allowed only as the argument of TW_JBROOT()/jbroot()/rootfs().
hits="$(grep -rnE '/var/(mobile|containers)/' src --include='*.m' --include='*.mm' --include='*.c' --include='*.cpp' \
    | grep -vE 'TW_JBROOT\(|jbroot\(|rootfs\(' || true)"
if [[ -n "$hits" ]]; then
    echo "error: literal rootfs path not wrapped by the path macro:" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    fail=1
fi

# 3. tw_jbpath.h guards both-defined and neither-defined, in that order.
grep -n '#error' "$jbpath" >/dev/null || err "$jbpath has no #error guard for the scheme macros"

# 4. Raw swizzling only inside tw_hook.h.
raw="$(grep -rnE '\b(method_setImplementation|class_replaceMethod)\b' src --include='*.m' --include='*.mm' --include='*.c' | grep -v 'src/tw_hook.h' || true)"
[[ -n "$raw" ]] && { echo "error: raw method swizzling outside tw_hook.h:" >&2; printf '%s\n' "$raw" | sed 's/^/    /' >&2; fail=1; }

# 5. Every TW_HOOK invocation passes an encoding (TW_ENC(...) or a string arg).
#    A TW_HOOK whose 4th argument is a type name (not TW_ENC/"...") is rejected.
while IFS= read -r line; do
    file="${line%%:*}"; rest="${line#*:}"; num="${rest%%:*}"
    # crude: the 4th macro arg must start with TW_ENC( or a quote
    body="$(sed -n "${num}p" "$file")"
    args="${body#*TW_HOOK(}"
    fourth="$(echo "$args" | awk -F',' '{gsub(/^ +/,"",$4); print $4}')"
    case "$fourth" in
    TW_ENC\(*|\"*|*ENC*) : ;;
    "") : ;;  # continuation line; skip
    *) err "$file:$num TW_HOOK without an encoding argument (use TW_ENC(...))" ;;
    esac
done < <(grep -rn 'TW_HOOK(' src --include='*.m' --include='*.mm' | grep -v 'define TW_HOOK' | grep -v 'tw_hook.h' || true)

# 6. os_log only in injected code; no NSLog/printf/etc. The prefs bundle and
#    helper may use stdout. Files allowed to use other diagnostics are listed
#    after an "allowed diagnostic files" heading in AGENTS.md.
injected="$(find src -maxdepth 1 -type f \( -name '*.m' -o -name '*.mm' -o -name '*.c' \))"
allowed_diag=""
[[ -f AGENTS.md ]] && allowed_diag="$(awk '/allowed diagnostic files/{f=1;next} f&&/^[-*]/{print $2} f&&/^#/{f=0}' AGENTS.md 2>/dev/null || true)"
for f in $injected; do
    grep -qxF "$f" <<<"$allowed_diag" && continue
    bad="$(grep -nE '\b(NSLog|NSLogv|syslog|vprintf|printf|fprintf[[:space:]]*\([[:space:]]*stderr)\b' "$f" || true)"
    [[ -n "$bad" ]] && { echo "error: $f uses non-os_log logging in injected code:" >&2; printf '%s\n' "$bad" | sed 's/^/    /' >&2; fail=1; }
    grep -qE '%\{public\}' "$f" && err "$f uses %{public} in an os_log format (never log values as public)"
    grep -qE 'os_log_(debug|info)|OS_LOG_TYPE_(DEBUG|INFO)' "$f" && note "$f uses info/debug os_log (not persisted; the smoke test reads default level)"
done

# 7. Only the prefs reader calls the preferences/notify APIs.
reader="src/tw_prefs.m"
pref_users="$(grep -rlnE 'NSUserDefaults|CFPreferences|notify_(register|post)' src --include='*.m' --include='*.mm' --include='*.c' 2>/dev/null | grep -v "$reader" | grep -v 'src/prefs/' | grep -v 'src/helper/' || true)"
[[ -n "$pref_users" ]] && { echo "error: preferences/notify API outside the reader:" >&2; printf '%s\n' "$pref_users" | sed 's/^/    /' >&2; fail=1; }

# 8. The injected constructor has an early identity guard; kill-switch via macro.
ctor="src/tweak.m"
if [[ -f "$ctor" ]]; then
    grep -qE 'getprogname|proc_pidpath|CFBundleGetMainBundle|NSBundle mainBundle' "$ctor" || err "$ctor constructor has no early identity guard"
    if ! grep -qE 'TW_JBROOT\(|jbroot\(' "$ctor"; then
        note "$ctor: kill-switch path not resolved through the path macro"
    fi
fi

(( fail )) && exit 65
if (( warn )); then echo "==> source checks ok (with warnings)" >&2; else echo "==> source checks ok" >&2; fi
