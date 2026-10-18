#!/usr/bin/env bash
#
# package-deb.sh — stage, strip, leak-scan, ad-hoc sign (last), and build one
# .deb for one bootstrap layout from a product tree that build-ios.sh assembled.
#
#   package-deb.sh <flavor> <product-dir> <dsym-dir|-> <output-deb>
#
# flavor is roothide (empty prefix, iphoneos-arm64e) or rootless (/var/jb,
# iphoneos-arm64). A failed build never replaces the last good .deb: the archive
# is built to a temp file, verified, then atomically moved into place.

set -Eeuo pipefail
# A failing command under set -e must never end the build silently.
trap 'echo "package-deb: failed at line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

[[ $# -eq 4 ]] || { echo "usage: $0 <roothide|rootless> <product-dir> <dsym-dir|-> <output-deb>" >&2; exit 64; }
flavor="$1"; product="$2"; dsym="$3"; output_deb="$4"
case "$flavor" in
roothide) prefix=""; rootfs="/rootfs"; architecture="iphoneos-arm64e" ;;
rootless) prefix="/var/jb"; rootfs=""; architecture="iphoneos-arm64" ;;
*) echo "error: flavor must be roothide or rootless" >&2; exit 64 ;;
esac
[[ -d "$product" ]] || { echo "error: no product dir: $product" >&2; exit 66; }
[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# A custom SDK path is a build path too; take CI's exported values before
# build.env (where they are usually blank) overwrites them.
sdk_paths=("${TWEAK_SDK:-}" "${PREFS_SDK:-}")
# shellcheck source=../configuration/build.env
source "$root/configuration/build.env"
sdk_paths+=("${TWEAK_SDK:-}" "${PREFS_SDK:-}")
# shellcheck source=../configuration/depends.env
source "$root/configuration/depends.env"
# shellcheck source=macho-lib.sh
source "$root/scripts/macho-lib.sh"
: "${TWEAK_NAME:?}" "${PACKAGE_ID:?}" "${MIN_IOS:?}"
version="$(tr -d '[:space:]' <"$root/configuration/version.txt")"

for tool in ldid dpkg-deb plutil; do command -v "$tool" >/dev/null || { echo "error: $tool not installed" >&2; exit 69; }; done

# roothide package must never carry a /var/jb tree; architecture and prefix must
# name the same layout (arch-and-slices).
case "$architecture:$prefix" in
iphoneos-arm64e:|iphoneos-arm64:/var/jb) ;;
*) echo "error: architecture $architecture and prefix '$prefix' name different layouts" >&2; exit 64 ;;
esac

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_dir="$(cd -- "$(dirname -- "$output_deb")" && pwd -P)"
output_deb="$output_dir/$output_name"

stage="$(mktemp -d "${TMPDIR:-/tmp}/${TWEAK_NAME}-deb.XXXXXX")"
temp_deb="$output_dir/.$output_name.tmp.$$"
trap 'rm -rf -- "$stage"; rm -f -- "$temp_deb"' EXIT
chmod 0755 "$stage"

installed_root="$stage${prefix}"
mkdir -p "$stage/DEBIAN" "$installed_root"

export COPYFILE_DISABLE=1
/usr/bin/ditto "$product" "$installed_root"
find "$stage" \( -name .DS_Store -o -name '._*' \) -delete

# Collect the Mach-Os to strip/sign.
mach_list=()
while IFS= read -r -d '' f; do
    is_macho "$f" && mach_list+=("$f")
done < <(find "$stage" -path "$stage/DEBIAN" -prune -o -type f -print0)

# --- strip (dsym-before-strip: the dSYM was made in build-ios) ---
for m in "${mach_list[@]}"; do
    xcrun --sdk iphoneos strip -x -S "$m"
done

# --- every Mach-O loads on the floor it claims (deployment-floor) ---
"$root/scripts/audit-ios-floor.sh" "$MIN_IOS" "$stage" >&2

# --- build-path leak scan (no-build-path-leak), boundary-aware ---
LEAK_SDK_PATHS="$(printf '%s\n' "${sdk_paths[@]}")" python3 - "$root" "${mach_list[@]}" <<'PY'
import os, re, sys, subprocess
root = sys.argv[1]
machs = sys.argv[2:]
paths = {root, os.path.realpath(root), os.path.expanduser("~"),
         "/Users/runner/work", "/home/runner/work"}
for sdk in os.environ.get("LEAK_SDK_PATHS", "").splitlines():
    if sdk.startswith("/"):
        paths.add(os.path.normpath(sdk)); paths.add(os.path.realpath(sdk))
for name in ("GITHUB_WORKSPACE", "RUNNER_TEMP", "TMPDIR"):
    v = os.environ.get(name)
    if v:
        paths.add(os.path.normpath(v)); paths.add(os.path.realpath(v))
try:
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    paths.add(sdk); paths.add(os.path.realpath(sdk))
except Exception:
    pass
paths = sorted(p for p in paths if p and p != "/")
bad = 0
for m in machs:
    data = open(m, "rb").read()
    for p in paths:
        if re.search(re.escape(p.encode()) + rb'(?=/|\x00|$)', data):
            print(f"error: {m} embeds build path {p}", file=sys.stderr); bad = 1
raise SystemExit(bad)
PY

# --- ad-hoc sign LAST, then read back (sign-dylib-adhoc) ---
helper_ent="$root/packaging/HELPER.entitlements"
sign_and_verify() {
    local m="$1" role="$2"
    if [[ "$role" == helper ]]; then
        ldid -S"$helper_ent" -Cadhoc "$m"
    else
        ldid -S -Cadhoc "$m"
    fi
    local slices; slices="$(lipo -archs "$m" 2>/dev/null || echo "")"
    [[ -z "$slices" ]] && slices="$(otool -hv "$m" >/dev/null 2>&1 && echo default)"
    # ldid derives the code-directory Identifier from the file basename, and the
    # Identifier is hashed into the CDHash. Re-sign a copy that keeps the SAME
    # basename, so a mismatch means a genuinely stale signature (ldid -h alone
    # cannot see one), not a different name.
    local scratch_dir scratch; scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/resign.XXXXXX")"
    scratch="$scratch_dir/$(basename "$m")"
    cp "$m" "$scratch"
    if [[ "$role" == helper ]]; then ldid -S"$helper_ent" -Cadhoc "$scratch"; else ldid -S -Cadhoc "$scratch"; fi
    for a in $slices; do
        local head; head="$(ldid -arch "$a" -h "$m" 2>/dev/null || true)"
        grep -q 'flags=0x2(adhoc)' <<<"$head" || { echo "error: $m ($a) not adhoc-signed" >&2; exit 65; }
        grep -qi 'CDHash' <<<"$head" || { echo "error: $m ($a) has no CDHash" >&2; exit 65; }
        # Read whole outputs first: ldid prints several CDHash lines, and cutting
        # a pipe after the first (head -n1) can SIGPIPE it, which pipefail turns
        # into a silent exit.
        local a_cd b_cd
        a_cd="$(ldid -arch "$a" -h "$m" 2>/dev/null || true)"
        a_cd="$(grep -i -m1 CDHash <<<"$a_cd" || true)"
        b_cd="$(ldid -arch "$a" -h "$scratch" 2>/dev/null || true)"
        b_cd="$(grep -i -m1 CDHash <<<"$b_cd" || true)"
        [[ "$a_cd" == "$b_cd" ]] || { echo "error: $m ($a) CDHash is stale (differs from a fresh sign)" >&2; exit 65; }
    done
    rm -rf "$scratch_dir"
    if [[ "$role" == helper ]]; then
        # exact entitlement dictionary equality
        local got; got="$(mktemp)"; ldid -e "$m" >"$got"
        plutil -convert xml1 "$helper_ent" -o "$got.want" 2>/dev/null || cp "$helper_ent" "$got.want"
        plutil -convert xml1 "$got" -o "$got.got" 2>/dev/null || cp "$got" "$got.got"
        diff <(plutil -p "$got.want") <(plutil -p "$got.got") >/dev/null || { echo "error: $m entitlements differ from HELPER.entitlements" >&2; exit 65; }
        rm -f "$got" "$got.want" "$got.got"
    else
        [[ -z "$(ldid -e "$m" 2>/dev/null | tr -d '[:space:]')" ]] || { echo "error: $m (injected/prefs) must carry no entitlements" >&2; exit 65; }
    fi
}
for m in "${mach_list[@]}"; do
    rel="${m#"$installed_root"/}"
    role=dylib
    [[ "$rel" == usr/libexec/* ]] && role=helper
    sign_and_verify "$m" "$role"
done

# --- dSYM UUID must equal the shipped file's, arch by arch (dsym-before-strip) ---
if [[ "$dsym" != "-" && -d "$dsym" ]]; then
    shipped="$installed_root/Library/MobileSubstrate/DynamicLibraries/$TWEAK_NAME.dylib"
    dwarf="$dsym/Contents/Resources/DWARF/$TWEAK_NAME.dylib"
    if [[ -f "$dwarf" ]]; then
        a_uuid="$(dwarfdump --uuid "$shipped" | awk '{print $2, $3}' | sort)"
        b_uuid="$(dwarfdump --uuid "$dwarf" | awk '{print $2, $3}' | sort)"
        [[ "$a_uuid" == "$b_uuid" ]] || { echo "error: dSYM UUIDs do not match the shipped dylib" >&2; exit 65; }
    fi
fi

# --- permissions ---
find "$installed_root" -type d -exec chmod 0755 {} +
find "$installed_root" -type f ! -type l -exec chmod 0644 {} +
for m in "${mach_list[@]}"; do chmod 0755 "$m"; done

# --- render DEBIAN/control ---
installed_size="$(du -sk "$installed_root" | awk '{print $1}')"
providers_var="PROVIDERS_${flavor^^}"; ceiling_var="CEILING_${flavor^^}"
providers="${!providers_var:-}"; ceiling="${!ceiling_var:-}"
deps=()
for p in $providers; do deps+=("$p"); done
[[ -d "$installed_root/Library/PreferenceBundles" ]] && deps+=("preferenceloader")
[[ -d "$installed_root/Applications" ]] && deps+=("uikittools")
ls "$installed_root"/Library/LaunchDaemons/*.plist >/dev/null 2>&1 && deps+=("launchctl")
[[ -n "$ceiling" ]] && deps+=("firmware (<< $ceiling)")
depends_suffix=""
(( ${#deps[@]} )) && depends_suffix=", $(IFS=,; echo "${deps[*]}" | sed 's/,/, /g')"

sed \
    -e "s|@PACKAGE_ID@|$PACKAGE_ID|g" \
    -e "s|@VERSION@|$version|g" \
    -e "s|@ARCHITECTURE@|$architecture|g" \
    -e "s|@INSTALLED_SIZE@|$installed_size|g" \
    -e "s|@MIN_IOS@|$MIN_IOS|g" \
    -e "s|@DEPENDS@|$depends_suffix|g" \
    "$root/packaging/DEBIAN/control" >"$stage/DEBIAN/control"
chmod 0644 "$stage/DEBIAN/control"
grep -qE '@[A-Z_]+@' "$stage/DEBIAN/control" && { echo "error: control still holds placeholders" >&2; grep -nE '@[A-Z_]+@' "$stage/DEBIAN/control" >&2; exit 65; }

# --- render maintainer scripts (strip the launchd block by fact) ---
has_daemon=0; ls "$installed_root"/Library/LaunchDaemons/*.plist >/dev/null 2>&1 && has_daemon=1
strip_block() { # file marker keep(0/1)
    local f="$1" marker="$2" keep="$3"
    if (( keep )); then
        sed -i '' "/# >>> $marker/d; /# <<< $marker/d" "$f"
    else
        sed -i '' "/# >>> $marker/,/# <<< $marker/d" "$f"
    fi
}
helper_label="${HELPER_LABEL:-}"
for name in postinst prerm postrm; do
    src="$root/packaging/DEBIAN/$name"
    [[ -f "$src" ]] || continue
    dst="$stage/DEBIAN/$name"
    sed -e "s|@PREFIX@|$prefix|g" -e "s|@ROOTFS@|$rootfs|g" -e "s|@HELPER_LABEL@|$helper_label|g" -e "s|@PACKAGE_ID@|$PACKAGE_ID|g" "$src" >"$dst"
    strip_block "$dst" launchd "$has_daemon"
    chmod 0755 "$dst"
    sh -n "$dst" || { echo "error: $name failed sh -n after render" >&2; exit 65; }
    grep -qE '@[A-Z_]+@' "$dst" && { echo "error: $name has leftover placeholder" >&2; exit 65; }
    grep -qE '[^[:space:]<>&|;]2>' "$dst" && { echo "error: $name has a glued redirect" >&2; exit 65; }
    grep -q uicache "$dst" && { echo "error: $name calls uicache" >&2; exit 65; }
done

# --- build to a temp file, verify, then atomically move ---
"$root/scripts/verify-payload.sh" "$flavor" "$stage"

dpkg-deb --root-owner-group -Zzstd -b "$stage" "$temp_deb" >/dev/null
[[ "$(dpkg-deb -f "$temp_deb" Package)" == "$PACKAGE_ID" ]] || { echo "error: wrong Package in deb" >&2; exit 65; }
[[ "$(dpkg-deb -f "$temp_deb" Version)" == "$version" ]] || { echo "error: wrong Version in deb" >&2; exit 65; }
[[ "$(dpkg-deb -f "$temp_deb" Architecture)" == "$architecture" ]] || { echo "error: wrong Architecture in deb" >&2; exit 65; }
contents="$(dpkg-deb -c "$temp_deb")"
grep -qE '(/\._|/\.DS_Store)' <<<"$contents" && { echo "error: deb carries macOS metadata" >&2; exit 65; }

expected_name="${PACKAGE_ID}_${version}_${architecture}.deb"
[[ "$output_name" == "$expected_name" ]] || { echo "error: output name $output_name != $expected_name" >&2; exit 65; }

mv -f "$temp_deb" "$output_deb"
echo "packaged $PACKAGE_ID $version ($architecture): $output_deb" >&2
shasum -a 256 "$output_deb"
