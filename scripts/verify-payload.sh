#!/usr/bin/env bash
#
# verify-payload.sh <flavor> <staging-root> — the one mechanical payload gate
# (verify-payload-gate). package-deb.sh runs it on the stage before packing;
# audit-tweak-debs.py runs it on each extracted final deb. Fails on any mismatch.
#
#   flavor        roothide | rootless
#   staging-root  a directory holding DEBIAN/ and the payload under the layout
#                 prefix (empty for roothide, var/jb for rootless)

set -Eeuo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <roothide|rootless> <staging-root>" >&2; exit 64; }
flavor="$1"; stage="$2"
case "$flavor" in roothide) prefix=""; arch="iphoneos-arm64e" ;; rootless) prefix="var/jb"; arch="iphoneos-arm64" ;; *) echo "error: flavor must be roothide or rootless" >&2; exit 64 ;; esac
[[ -d "$stage" ]] || { echo "error: no staging root: $stage" >&2; exit 66; }

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../configuration/build.env
source "$root/configuration/build.env"
# shellcheck source=../configuration/depends.env
source "$root/configuration/depends.env"
# shellcheck source=macho-lib.sh
source "$root/scripts/macho-lib.sh"
: "${TWEAK_NAME:?}" "${PACKAGE_ID:?}" "${MIN_IOS:?}"

P="$stage${prefix:+/$prefix}"
fail=0
err() { echo "error: $*" >&2; fail=1; }
# A command that dies under set -e must still read as a failed gate, not a
# silent non-zero exit.
finished=0
trap 'rc=$?; (( finished || rc == 0 )) || echo "verify-payload: FAILED for $flavor (aborted, exit $rc)" >&2' EXIT

floor_key() { local IFS=.; local p=($1 0 0); printf '%d' $(( ${p[0]} * 10000 + ${p[1]} * 100 + ${p[2]} )); }
(( $(floor_key "$MIN_IOS") >= $(floor_key 15.0) )) || err "MIN_IOS $MIN_IOS is below 15.0"

dylib_rel="/Library/MobileSubstrate/DynamicLibraries/$TWEAK_NAME.dylib"
filter_rel="/Library/MobileSubstrate/DynamicLibraries/$TWEAK_NAME.plist"
notice_rel="/usr/share/doc/$PACKAGE_ID/NOTICE"

for req in "$dylib_rel" "$filter_rel" "$notice_rel"; do
    [[ -e "$P$req" ]] || err "missing required payload path: $prefix$req"
done

# --- payload allowlist (layout-tweak-payload) ---
# Walk the WHOLE stage, not just P: on rootless anything outside var/jb (a
# top-level .jbroot, a stray Library/) would install onto the real rootfs.
allow_re='^(Library/MobileSubstrate/DynamicLibraries/|Library/PreferenceBundles/|Library/PreferenceLoader/Preferences/|Library/LaunchDaemons/|usr/libexec/|usr/share/doc/|Applications/)'
while IFS= read -r -d '' item; do
    rel="${item#"$stage"/}"
    [[ "$rel" == DEBIAN || "$rel" == DEBIAN/* ]] && continue   # metadata, not payload
    if [[ -n "$prefix" ]]; then
        if [[ "$rel" != "$prefix"/* ]]; then
            # only the directories leading down to the prefix may sit above it
            [[ -d "$item" && ! -L "$item" && "$prefix/" == "$rel"/* ]] || err "payload path outside /$prefix: /$rel"
            continue
        fi
        rel="${rel#"$prefix"/}"
    fi
    case "$(basename "$rel")" in .DS_Store | ._*) err "macOS metadata in payload: /$rel" ;; esac
    [[ -d "$item" && ! -L "$item" ]] && continue
    [[ "$rel" =~ $allow_re ]] || err "payload path not on allowlist: ${prefix:+/$prefix}/$rel"
done < <(find "$stage" -mindepth 1 -print0)
# roothide must have no var/jb entry
if [[ "$flavor" == roothide && -e "$stage/var/jb" ]]; then err "roothide payload contains a var/jb tree"; fi

# --- filter plist (filter-plist) ---
filter="$P$filter_rel"
if [[ -f "$filter" ]]; then
    plutil -lint "$filter" >/dev/null || err "filter plist fails plutil -lint"
    magic="$(head -c 8 "$filter")"
    if [[ "$magic" != bplist00* ]] && [[ "$(plutil -convert xml1 "$filter" -o - 2>/dev/null | head -c 5 || true)" != '<?xml' ]]; then
        err "filter plist is neither binary nor XML"
    fi
    mode="$(stat -f '%Lp' "$filter")"
    [[ "$mode" == 644 ]] || err "filter plist mode is $mode, want 644"
    keys="$(plutil -extract Filter raw -o - "$filter" 2>/dev/null || true)"
    [[ -n "$keys" ]] || err "filter plist has no non-empty Filter dict"
fi

# --- per Mach-O checks ---
# Every Mach-O in the stage, including any the allowlist already rejected, so a
# stray binary outside P still gets its signature and setuid checks.
mach_files() {
    while IFS= read -r -d '' f; do
        is_macho "$f" && printf '%s\0' "$f"
    done < <(find "$stage" -path "$stage/DEBIAN" -prune -o -type f -print0 2>/dev/null)
}

while IFS= read -r -d '' mach; do
    rel="${mach#"$P"/}"
    [[ "$rel" == "$mach" ]] && rel="${mach#"$stage"/}"
    is_dylib=0; is_bundle=0; is_exec=0
    ft="$(otool -arch arm64e -hv "$mach" 2>/dev/null | awk 'NR==4{print $5}' || true)"
    [[ -z "$ft" ]] && ft="$(otool -hv "$mach" 2>/dev/null | awk 'NR==4{print $5}' || true)"
    case "$ft" in DYLIB) is_dylib=1 ;; BUNDLE) is_bundle=1 ;; EXECUTE) is_exec=1 ;; esac

    # slices per flavor (arch-and-slices)
    slices="$(lipo -archs "$mach" 2>/dev/null || true)"
    if [[ "$flavor" == roothide ]]; then
        grep -qw arm64e <<<"$slices" || err "$rel: roothide slice must contain arm64e (has: $slices)"
    else
        { grep -qw arm64 <<<"$slices" && grep -qw arm64e <<<"$slices"; } || err "$rel: rootless slice must be fat arm64 arm64e (has: $slices)"
    fi
    # arm64e must be the userspace ABI
    if grep -qw arm64e <<<"$slices"; then
        otool -arch arm64e -hv "$mach" | grep -E 'ARM64 *E *USR00' >/dev/null || err "$rel: arm64e slice is not USR00"
    fi
    # platform IOS and minos == MIN_IOS on every slice
    for a in $slices; do
        build="$(vtool -arch "$a" -show-build "$mach" 2>/dev/null || true)"
        grep -qE '^ *platform (IOS|2)$' <<<"$build" || err "$rel ($a): not an iOS build"
        minos="$(awk '/minos/{print $2; exit}' <<<"$build")"
        [[ "$minos" == "$MIN_IOS" ]] || err "$rel ($a): minos $minos != MIN_IOS $MIN_IOS"
    done

    # filetype expectations
    if [[ "$rel" == "${dylib_rel#/}" ]]; then
        (( is_dylib )) || err "$rel: tweak payload must be MH_DYLIB (got $ft)"
    fi
    [[ "$rel" == Library/PreferenceBundles/* ]] && { (( is_bundle )) || err "$rel: prefs binary must be MH_BUNDLE (got $ft)"; }
    [[ "$rel" == usr/libexec/* ]] && { (( is_exec )) || err "$rel: helper must be MH_EXECUTE (got $ft)"; }

    # install name (roothide-install-names) for MH_DYLIB
    if (( is_dylib )); then
        idname="$(otool -D "$mach" 2>/dev/null | tail -n1 || true)"
        if [[ "$flavor" == roothide ]]; then
            [[ "$idname" == "@loader_path/.jbroot/$rel" ]] || err "$rel: roothide install name is '$idname', want @loader_path/.jbroot/$rel"
        else
            [[ "$idname" == @rpath/* ]] || err "$rel: rootless install name is '$idname', want @rpath/*"
        fi
    fi

    # otool -L allowlist
    while IFS= read -r dep; do
        case "$dep" in
        /usr/lib/*|/System/Library/Frameworks/*|/System/Library/PrivateFrameworks/*) : ;;
        @loader_path/.jbroot/*)
            [[ "$flavor" == roothide ]] || err "$rel: rootless links a .jbroot path: $dep" ;;
        @rpath/*)
            [[ "$flavor" == rootless ]] || err "$rel: roothide links an @rpath path: $dep" ;;
        *) err "$rel: disallowed dependency: $dep" ;;
        esac
        case "$dep" in
        *libvroot*) err "$rel: links libvroot ($dep)" ;;
        *libsubstrate*|*CydiaSubstrate*|*libhooker*|*libellekit*|*ellekit*) err "$rel: links a substrate provider ($dep)" ;;
        esac
        [[ "$flavor" == roothide && "$dep" == /var/jb/* ]] && err "$rel: roothide links a /var/jb path ($dep)"
        [[ "$flavor" == roothide && "$dep" == /Library/Frameworks/* ]] && err "$rel: roothide links /Library/Frameworks ($dep)"
        if [[ "$flavor" == rootless ]]; then
            case "$dep" in */libroothide.dylib) err "$rel: rootless links libroothide ($dep)" ;; esac
        fi
    done < <(otool -L "$mach" | tail -n +2 | awk '{print $1}' | { read -r first; [[ "$(otool -D "$mach" | tail -n1)" == "$first" ]] && cat || { printf '%s\n' "$first"; cat; }; })

    # import denylist on the shipped bytes (import-denylist), same roles as the build
    case "$rel" in usr/libexec/*) sym_role=helper ;; Library/PreferenceBundles/*) sym_role=bundle ;; *) sym_role=dylib ;; esac
    "$root/scripts/verify-symbols.sh" "$sym_role" "$mach" >/dev/null || err "$rel: imports a denied symbol (see above)"

    # no undefined MS* symbol and no weak-external substrate symbol (substrate-runtime-resolution)
    syms="$(nm -m "$mach" 2>/dev/null || true)"
    grep -qE '\(undefined\)[[:space:]]+external[[:space:]]+_MS[A-Za-z]' <<<"$syms" && err "$rel: undefined MS* import (resolve via dlsym instead)"
    grep -qE 'weak external _MS[A-Za-z]' <<<"$syms" && err "$rel: weak-external substrate symbol"

    # no /var/jb string in a roothide Mach-O (jbroot-by-scheme), allowlist none
    if [[ "$flavor" == roothide ]]; then
        strings -a "$mach" | grep -E '/var/jb(/|$)' >/dev/null && err "$rel: roothide Mach-O embeds a /var/jb string"
    fi

    # setuid/setgid bits (helper-entitlements)
    { [[ -u "$mach" ]] || [[ -g "$mach" ]]; } && err "$rel: has setuid/setgid bit"

    # signature present per slice (sign-dylib-adhoc): flags adhoc + CDHash. Then
    # re-sign a same-basename scratch copy and require an equal CDHash per slice:
    # a byte flipped in a signed slice after signing leaves a stale embedded
    # CDHash that ldid -h reports but does not verify, so only a fresh re-sign
    # over the current bytes exposes it (gates-fail-closed: flipped code byte).
    role_ent=""
    [[ "$rel" == usr/libexec/* && -f "$root/packaging/HELPER.entitlements" ]] && role_ent="$root/packaging/HELPER.entitlements"
    scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/vp-resign.XXXXXX")"
    scratch="$scratch_dir/$(basename "$mach")"
    cp "$mach" "$scratch"
    if [[ -n "$role_ent" ]]; then ldid -S"$role_ent" -Cadhoc "$scratch" 2>/dev/null || true; else ldid -S -Cadhoc "$scratch" 2>/dev/null || true; fi
    for a in $slices; do
        head="$(ldid -arch "$a" -h "$mach" 2>/dev/null || true)"
        grep -q 'flags=0x2(adhoc)' <<<"$head" || err "$rel ($a): not ad-hoc signed"
        grep -qi 'CDHash' <<<"$head" || err "$rel ($a): no CDHash"
        got="$(ldid -arch "$a" -h "$mach" 2>/dev/null | awk -F= '/^CDHash=/{print $2; exit}' || true)"
        want="$(ldid -arch "$a" -h "$scratch" 2>/dev/null | awk -F= '/^CDHash=/{print $2; exit}' || true)"
        [[ -n "$got" && "$got" == "$want" ]] || err "$rel ($a): signature does not match the code (tampered or stale)"
    done
    rm -rf "$scratch_dir"
    # ad-hoc only: a certificate (Apple or developer) means a copied or
    # re-signed foreign binary, not one this repo built
    authority="$(codesign -dvvv "$mach" 2>&1 | awk -F= '/^Authority=/{print $2; exit}' || true)"
    [[ -z "$authority" ]] || err "$rel: carries a certificate signature ($authority), want ad-hoc only"

    # no dSYM shipped inside the tree
    [[ "$rel" == *.dSYM/* ]] && err "$rel: dSYM must not ship in the payload"
done < <(mach_files)

# --- Mach-O placement (data-locations): none under var/ or tmp/ of the tree ---
while IFS= read -r -d '' f; do
    rel="${f#"$P"/}"
    case "$rel" in var/*|tmp/*)
        is_macho "$f" && err "$rel: Mach-O placed under var/ or tmp/ (will not load)" ;;
    esac
done < <(find "$P" -type f -print0 2>/dev/null)

# --- version marker matches control Version (version-single-source) ---
if [[ -f "$stage/DEBIAN/control" ]]; then
    control_version="$(awk -F': ' '/^Version:/{print $2; exit}' "$stage/DEBIAN/control")"
    marker="$(strings -a "$P$dylib_rel" 2>/dev/null | sed -n 's/^TWEAKVER=//p' | head -n1 || true)"
    [[ -n "$marker" ]] || err "dylib has no TWEAKVER marker"
    [[ "$marker" == "$control_version" ]] || err "TWEAKVER=$marker != control Version $control_version"
    [[ "$(awk -F': ' '/^Architecture:/{print $2; exit}' "$stage/DEBIAN/control")" == "$arch" ]] || err "control Architecture is not $arch"
fi

# --- NOTICE present, no GPL-family text in payload (license-provenance) ---
[[ -f "$P$notice_rel" ]] || err "missing $prefix$notice_rel"
if grep -rIlE --exclude-dir=DEBIAN 'GNU (GENERAL|LESSER GENERAL) PUBLIC LICENSE' "$stage" >/dev/null 2>&1; then
    err "payload contains GPL/LGPL license text"
fi

# --- helper LaunchDaemons plist (helper-daemon-hardening) ---
for plist in "$P"/Library/LaunchDaemons/*.plist; do
    [[ -e "$plist" ]] || continue
    plutil -lint "$plist" >/dev/null || err "$(basename "$plist"): fails plutil -lint"
    plutil -extract MachServices xml1 -o - "$plist" >/dev/null 2>&1 || plutil -extract Sockets xml1 -o - "$plist" >/dev/null 2>&1 || err "$(basename "$plist"): no MachServices or Sockets"
    for banned in KeepAlive RunAtLoad; do
        plutil -extract "$banned" raw -o - "$plist" >/dev/null 2>&1 && err "$(basename "$plist"): has $banned (session-host exception must be documented)"
    done
    first_arg="$(plutil -extract ProgramArguments.0 raw -o - "$plist" 2>/dev/null || true)"
    if [[ "$flavor" == roothide ]]; then
        [[ "$first_arg" == /var/jb/* ]] && err "$(basename "$plist"): roothide plist has a literal /var/jb ProgramArguments[0]"
        case "$first_arg" in */.jbroot/*) err "$(basename "$plist"): resolved jbroot path in plist" ;; esac
    else
        [[ "$first_arg" == /var/jb/* ]] || err "$(basename "$plist"): rootless plist ProgramArguments[0] must start with /var/jb"
    fi
    [[ "$(plutil -extract EnvironmentVariables.DISABLE_TWEAKS raw -o - "$plist" 2>/dev/null || true)" == 1 ]] || err "$(basename "$plist"): DISABLE_TWEAKS=1 missing"
    # the filter must not list the helper daemon
    label="$(plutil -extract Label raw -o - "$plist" 2>/dev/null || true)"
    [[ -n "$label" && -f "$filter" ]] && grep -q "$label" "$filter" && err "filter lists the helper daemon $label"
done

# --- preference bundle and its PreferenceLoader entry (prefs-bundle) ---
control_field() { [[ ! -f "$stage/DEBIAN/control" ]] || awk -F': ' -v k="$1" '$1==k{print $2; exit}' "$stage/DEBIAN/control"; }
pb_dir="$P/Library/PreferenceBundles"
pl_dir="$P/Library/PreferenceLoader/Preferences"
entry_targets="$(for entry in "$pl_dir"/*.plist; do
    [[ -f "$entry" ]] && plutil -extract entry.bundle raw -o - "$entry" 2>/dev/null; echo
done | grep . || true)"
for bundle in "$pb_dir"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    b="$(basename "$bundle")"
    info="$bundle/Info.plist"
    if [[ ! -f "$info" ]] || ! plutil -lint "$info" >/dev/null; then err "$b: missing or invalid Info.plist"; continue; fi
    info_get() { plutil -extract "$1" raw -o - "$info" 2>/dev/null || true; }
    exe="$(info_get CFBundleExecutable)"
    [[ -n "$exe" && -f "$bundle/$exe" ]] && is_macho "$bundle/$exe" || err "$b: CFBundleExecutable '$exe' is not a Mach-O in the bundle"
    [[ "$(info_get CFBundlePackageType)" == BNDL ]] || err "$b: CFBundlePackageType is not BNDL"
    principal="$(info_get NSPrincipalClass)"
    if [[ -z "$principal" ]]; then
        err "$b: no NSPrincipalClass"
    elif [[ -f "$bundle/$exe" ]] && ! strings -a "$bundle/$exe" | grep -xF "$principal" >/dev/null; then
        err "$b: NSPrincipalClass $principal is not defined in $exe"
    fi
    [[ -n "$(info_get CFBundleShortVersionString)" ]] || err "$b: no CFBundleShortVersionString"
    bundle_version="$(info_get CFBundleVersion)"
    control_version="$(control_field Version)"
    [[ -z "$control_version" || "$bundle_version" == "$control_version" ]] || err "$b: CFBundleVersion $bundle_version != control Version $control_version"
    [[ -f "$bundle/Root.plist" ]] && plutil -lint "$bundle/Root.plist" >/dev/null || err "$b: missing or invalid Root.plist"
    grep -qxF "${b%.bundle}" <<<"$entry_targets" || err "$b: no PreferenceLoader entry names it (unreachable from Settings)"
done
for entry in "$pl_dir"/*.plist; do
    [[ -f "$entry" ]] || continue
    e="$(basename "$entry")"
    plutil -lint "$entry" >/dev/null || { err "$e: fails plutil -lint"; continue; }
    target="$(plutil -extract entry.bundle raw -o - "$entry" 2>/dev/null || true)"
    if [[ -z "$target" || ! -d "$pb_dir/$target.bundle" ]]; then
        err "$e: entry.bundle '$target' does not name a shipped PreferenceBundles/<name>.bundle"
        continue
    fi
    icon="$(plutil -extract entry.icon raw -o - "$entry" 2>/dev/null || true)"
    if plutil -extract entry.icon raw -o - "$entry" >/dev/null 2>&1; then
        [[ -n "$icon" && -f "$pb_dir/$target.bundle/$icon" ]] || err "$e: entry.icon '$icon' is not a file in $target.bundle (ship it or drop the key)"
    fi
done

# --- Depends (control-fields, hook-lib-depends): floor first, then exactly the
#     configured providers and what the staged tree implies ---
if [[ -f "$stage/DEBIAN/control" ]]; then
    depends="$(control_field Depends)"
    providers_var="PROVIDERS_$(tr '[:lower:]' '[:upper:]' <<<"$flavor")"
    ceiling_var="CEILING_$(tr '[:lower:]' '[:upper:]' <<<"$flavor")"
    want=("firmware (>= $MIN_IOS)")
    for dep in ${!providers_var:-}; do want+=("$dep"); done
    [[ -d "$P/Library/PreferenceBundles" ]] && want+=("preferenceloader")
    [[ -d "$P/Applications" ]] && want+=("uikittools")
    ls "$P"/Library/LaunchDaemons/*.plist >/dev/null 2>&1 && want+=("launchctl")
    [[ -n "${!ceiling_var:-}" ]] && want+=("firmware (<< ${!ceiling_var})")
    want_depends="$(printf '%s, ' "${want[@]}")"; want_depends="${want_depends%, }"
    [[ "$depends" == "$want_depends" ]] || err "control Depends is '$depends', want '$want_depends'"
fi

# --- maintainer scripts re-grep (maintainer-scripts / lifecycle) ---
has_daemon=0; ls "$P"/Library/LaunchDaemons/*.plist >/dev/null 2>&1 && has_daemon=1
for script in "$stage"/DEBIAN/postinst "$stage"/DEBIAN/prerm "$stage"/DEBIAN/postrm; do
    [[ -f "$script" ]] || continue
    name="$(basename "$script")"
    sh -n "$script" || err "$name: sh -n failed"
    grep -qE '@[A-Z_]+@' "$script" && err "$name: unsubstituted placeholder"
    grep -qE '[^[:space:]<>&|;]2>' "$script" && err "$name: glued redirect"
    grep -q 'uicache' "$script" && err "$name: calls uicache"
    [[ "$(tail -n1 "$script")" == "exit 0" ]] || err "$name: does not end with exit 0"
    # /var/jb in executable (non-comment) lines only; the header comment mentions it.
    if [[ "$flavor" == roothide ]] && grep -vE '^[[:space:]]*#' "$script" | grep '/var/jb' >/dev/null; then
        err "$name: roothide script has literal /var/jb"
    fi
    if (( has_daemon )); then
        grep -q launchctl "$script" || err "$name: daemon package but no launchctl"
        [[ "$(grep -cE '^[[:space:]]*label=' "$script")" -le 1 ]] || err "$name: more than one label= line"
    else
        grep -q launchctl "$script" && err "$name: no daemon but references launchctl"
    fi
done
if (( has_daemon )); then
    grep -q launchctl "$stage/DEBIAN/postinst" 2>/dev/null && grep -q 'bootstrap system' "$stage/DEBIAN/postinst" || err "postinst missing bootstrap for daemon"
fi

# --- postrm purge branch (uninstall-and-purge-state) ---
if [[ -f "$stage/DEBIAN/postrm" ]]; then
    grep -q 'purge' "$stage/DEBIAN/postrm" || err "postrm has no purge branch"
    # state lives in the bootstrap; the preference plist on the real rootfs
    # (roothide's shell reaches it through /rootfs, rootless's directly)
    [[ "$flavor" == roothide ]] && rootfs_shell="/rootfs" || rootfs_shell=""
    want_state="${prefix:+/$prefix}/var/mobile/Library/$PACKAGE_ID\""
    want_prefs="\"$rootfs_shell/var/mobile/Library/Preferences/$PACKAGE_ID.plist\""
    grep -qF "$want_state" "$stage/DEBIAN/postrm" || err "postrm does not purge the state dir ${prefix:+/$prefix}/var/mobile/Library/$PACKAGE_ID"
    grep -qF "$want_prefs" "$stage/DEBIAN/postrm" || err "postrm does not purge the preference plist at $rootfs_shell/var/mobile/Library/Preferences/$PACKAGE_ID.plist"
fi

finished=1
if (( fail )); then echo "verify-payload: FAILED for $flavor" >&2; exit 65; fi
echo "verify-payload: OK ($flavor, $arch)" >&2
