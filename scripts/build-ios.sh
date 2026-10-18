#!/usr/bin/env bash
#
# build-ios.sh — compile the tweak for one bootstrap layout with the plain Xcode
# toolchain (xcrun clang), NO Theos. Produces a stripped-but-unsigned payload
# tree and a dSYM archive; scripts/package-deb.sh signs and packs it.
#
#   build-ios.sh --scheme roothide|rootless [--out <dir>]
#
# One compile+link per flavor (two-compiles-one-define): only the scheme macro,
# the arch slices, the roothide include/link and the install name differ. The
# path of the built dylib is printed on the LAST line of stdout.

set -Eeuo pipefail

scheme=""
out_override=""
while [[ $# -gt 0 ]]; do
    case "$1" in
    --scheme) scheme="${2:-}"; shift 2 ;;
    --out) out_override="${2:-}"; shift 2 ;;
    *) echo "usage: $0 --scheme roothide|rootless [--out <dir>]" >&2; exit 64 ;;
    esac
done
case "$scheme" in roothide | rootless) ;; *) echo "error: --scheme must be roothide or rootless" >&2; exit 64 ;; esac

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# CI injects a fetched SDK by exporting TWEAK_SDK/PREFS_SDK before the build; a
# pre-set (non-empty) value wins over build.env so the work tree stays clean.
# The pin it must match always comes from build.env (ci-pin-and-verify-inputs).
_env_tweak_sdk="${TWEAK_SDK:-}"; _env_prefs_sdk="${PREFS_SDK:-}"
_env_roothide_hdr="${ROOTHIDE_HEADER_DIR:-}"
# shellcheck source=../configuration/build.env
source "$root/configuration/build.env"
[[ -n "$_env_tweak_sdk" ]] && TWEAK_SDK="$_env_tweak_sdk"
[[ -n "$_env_prefs_sdk" ]] && PREFS_SDK="$_env_prefs_sdk"
[[ -n "$_env_roothide_hdr" ]] && ROOTHIDE_HEADER_DIR="$_env_roothide_hdr"

: "${TWEAK_NAME:?}"
: "${PACKAGE_ID:?}"
: "${MIN_IOS:?}"
version="$(tr -d '[:space:]' <"$root/configuration/version.txt")"

# --- deployment floor guard (deployment-floor) ---
floor_key() { local IFS=.; local p=($1 0 0); printf '%d' $(( ${p[0]} * 10000 + ${p[1]} * 100 + ${p[2]} )); }
(( $(floor_key "$MIN_IOS") >= $(floor_key 14.0) )) || { echo "error: MIN_IOS $MIN_IOS is below 14.0" >&2; exit 65; }

build_dir="${BUILD_DIR:-$root/build}"
out="${out_override:-$build_dir/$scheme}"
obj="$out/obj"
product="$out/product"
rm -rf "$out"
mkdir -p "$obj" "$product"

# --- resolve and identify the SDK (sdk-identity) ---
if [[ "${TWEAK_SDK:-xcode}" == "xcode" || -z "${TWEAK_SDK:-}" ]]; then
    sdkroot="$(xcrun --sdk iphoneos --show-sdk-path)"
    custom_sdk=0
else
    sdkroot="$TWEAK_SDK"
    custom_sdk=1
fi
[[ -d "$sdkroot" ]] || { echo "error: SDK not found: $sdkroot" >&2; exit 66; }
settings="$sdkroot/SDKSettings.json"
sdk_read() { plutil -extract "$1" raw "$settings" 2>/dev/null || true; }
sdk_version="$(sdk_read Version)"
sdk_display="$(sdk_read DisplayName)"
sdk_canonical="$(sdk_read CanonicalName)"
echo "==> SDK: $sdk_display ($sdk_canonical), reports Version $sdk_version" >&2

# --- a custom SDK must be the pinned one (ci-pin-and-verify-inputs) ---
sdk_digest() { # <method> <dir>
    local method="$1" dir="$2" scratch digest
    case "$method" in
    git-tree-id)
        # The tree object git would record for this directory, computed in a
        # throwaway object store so no checkout is needed.
        scratch="$(mktemp -d "${TMPDIR:-/tmp}/sdk-tree.XXXXXX")"
        git init -q --bare "$scratch"
        GIT_DIR="$scratch" GIT_INDEX_FILE="$scratch/index" git \
            -c core.autocrlf=false -c core.fileMode=true -c core.symlinks=true \
            --work-tree="$dir" add -A -f .
        digest="$(GIT_DIR="$scratch" GIT_INDEX_FILE="$scratch/index" git write-tree)"
        rm -rf "$scratch"
        printf '%s' "$digest" ;;
    sorted-file-sha256)
        (cd "$dir" && find . \( -type f -o -type l \) -print0 | LC_ALL=C sort -z |
            while IFS= read -r -d '' f; do
                if [[ -L "$f" ]]; then printf '%s - %s\n' "$f" "$(readlink "$f")"
                else printf '%s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"; fi
            done) | shasum -a 256 | cut -d' ' -f1 ;;
    *) echo "error: unknown SDK_DIGEST_METHOD '$method'" >&2; return 65 ;;
    esac
}
verified_sdks=()
verify_pinned_sdk() { # <dir> <role>
    local dir real reported got v
    dir="$1"; real="$(cd "$dir" && pwd -P)"
    for v in "${verified_sdks[@]}"; do [[ "$v" == "$real" ]] && return 0; done
    [[ -n "${SDK_VERSION:-}" && -n "${SDK_DIGEST_METHOD:-}" && -n "${SDK_DIGEST_VALUE:-}" ]] || {
        echo "error: $2 is a custom SDK but build.env has no SDK_VERSION/SDK_DIGEST_* pin" >&2; exit 65; }
    reported="$(plutil -extract Version raw "$dir/SDKSettings.json" 2>/dev/null || true)"
    [[ "$reported" == "$SDK_VERSION" ]] || {
        echo "error: $2 reports Version '$reported', build.env SDK_VERSION=$SDK_VERSION" >&2; exit 65; }
    got="$(sdk_digest "$SDK_DIGEST_METHOD" "$dir")"
    [[ "$got" == "$SDK_DIGEST_VALUE" ]] || {
        echo "error: $2 $SDK_DIGEST_METHOD is $got, build.env pins $SDK_DIGEST_VALUE" >&2; exit 65; }
    echo "==> $2 matches the pin: Version $reported, $SDK_DIGEST_METHOD $got" >&2
    verified_sdks+=("$real")
}
(( custom_sdk )) && verify_pinned_sdk "$sdkroot" TWEAK_SDK

# --- header shim for a missing-header, present-symbol gap (sdk-header-gap) ---
shim_flags=()
shim_dir="$build_dir/sdk-shim"
# An entry is a header or a header directory (e.g. xpc), relative to usr/include.
# Borrowed from Xcode's iphoneos SDK first (same platform), macOS only as a
# last resort.
if [[ -f "$root/configuration/sdk-shim.txt" ]]; then
    rm -rf "$shim_dir"
    mkdir -p "$shim_dir"
    used_shim=0
    while IFS= read -r header; do
        header="${header%%#*}"; header="$(echo "$header" | tr -d '[:space:]')"; header="${header%/}"
        [[ -n "$header" ]] || continue
        [[ -e "$sdkroot/usr/include/$header" ]] && continue     # SDK already has it: skip
        src=""
        for base in "$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)" \
                    "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"; do
            [[ -n "$base" && -e "$base/usr/include/$header" ]] && { src="$base/usr/include/$header"; break; }
        done
        [[ -n "$src" ]] || { echo "error: sdk-shim: no source for header $header" >&2; exit 65; }
        mkdir -p "$shim_dir/$(dirname "$header")"
        ln -sfn "$src" "$shim_dir/$header"
        echo "==> sdk-shim: $header from $src" >&2
        used_shim=1
    done <"$root/configuration/sdk-shim.txt"
    (( used_shim )) && shim_flags=(-isystem "$shim_dir")
fi

CC=(xcrun clang)
common=(
    -isysroot "$sdkroot"
    -mios-version-min="$MIN_IOS"
    -fobjc-arc -O2 -g
    -Wall -Wextra -Werror=unguarded-availability-new
    -fvisibility=hidden
    -I"$root/src"
    -ffile-prefix-map="$root=." -ffile-prefix-map="$sdkroot=/sdk"
    -DTW_PACKAGE_ID="\"$PACKAGE_ID\"" -DTW_VERSION="\"$version\""
    "${shim_flags[@]}"
)
(( custom_sdk )) && common+=(-Wno-incompatible-sysroot)

dylib_install_dir="/Library/MobileSubstrate/DynamicLibraries"
dylib_rel="$dylib_install_dir/$TWEAK_NAME.dylib"

if [[ "$scheme" == roothide ]]; then
    archs=(-arch arm64e)                              # roothide is arm64e-only by default
    scheme_flags=(-DTW_SCHEME_ROOTHIDE=1 -I"$root/${ROOTHIDE_HEADER_DIR:-stubs/roothide}")
    link_extra=(-L"$root/stubs" -lroothide)
    install_name="@loader_path/.jbroot$dylib_rel"
    dylib_rpath=()
else
    archs=(-arch arm64 -arch arm64e)                  # rootless is fat
    scheme_flags=(-DTW_SCHEME_ROOTLESS=1)
    link_extra=()
    install_name="@rpath/$TWEAK_NAME.dylib"
    dylib_rpath=(-Wl,-rpath,/var/jb/Library/Frameworks -Wl,-rpath,/var/jb/usr/lib)
fi

# --- compile objects, keep them (dsym-before-strip needs the .o) ---
# Every source in src/ (hooks live in tweak.m only; the rest is the fold itself).
sources=("$root"/src/*.m)
objects=()
for src in "${sources[@]}"; do
    o="$obj/$(basename "${src%.m}").o"
    "${CC[@]}" "${common[@]}" "${scheme_flags[@]}" "${archs[@]}" -c "$src" -o "$o"
    objects+=("$o")
done

dylib="$product$dylib_rel"
mkdir -p "$(dirname "$dylib")"
"${CC[@]}" "${common[@]}" "${archs[@]}" -dynamiclib \
    -install_name "$install_name" "${dylib_rpath[@]}" \
    -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics "${link_extra[@]}" \
    "${objects[@]}" -o "$dylib"

# --- dSYM before strip; require debug info; record UUIDs ---
dsym_dir="$out/$TWEAK_NAME.dylib.dSYM"
dsymutil "$dylib" -o "$dsym_dir" 2>"$out/dsymutil.log" || { cat "$out/dsymutil.log" >&2; exit 65; }
[[ -s "$out/dsymutil.log" ]] && { echo "error: dsymutil emitted warnings:" >&2; cat "$out/dsymutil.log" >&2; exit 65; }
otool -l "$dsym_dir/Contents/Resources/DWARF/$TWEAK_NAME.dylib" | grep __debug_info >/dev/null || {
    echo "error: dSYM has no __debug_info" >&2; exit 65; }
echo "==> dylib UUIDs:" >&2
dwarfdump --uuid "$dylib" >&2
print_build_versions() { # what each slice was built for and against
    local arch
    for arch in $(lipo -archs "$1"); do
        vtool -arch "$arch" -show-build "$1" |
            awk -v f="$(basename "$1")" -v a="$arch" '$1=="minos"{m=$2} $1=="sdk"{s=$2} END{printf "==> %s (%s): minos %s, sdk %s\n", f, a, m, s}' >&2
    done
}
print_build_versions "$dylib"

# --- import denylist gate on the final linked Mach-O (import-denylist) ---
"$root/scripts/verify-symbols.sh" dylib "$dylib" >&2

# --- filter plist: convert to XML, mode 0644 ---
filter_dst="$product$dylib_install_dir/$TWEAK_NAME.plist"
plutil -convert xml1 "$root/packaging/TWEAK.plist" -o "$filter_dst"
chmod 0644 "$filter_dst"

# --- NOTICE (license-provenance) ---
notice_dir="$product/usr/share/doc/$PACKAGE_ID"
mkdir -p "$notice_dir"
cp "$root/Licenses/NOTICE" "$notice_dir/NOTICE"

# --- optional preference bundle (prefs-bundle); built only when an SDK with the
#     private Preferences framework is available (Xcode's SDK has none) ---
if [[ -d "$root/src/prefs" ]]; then
    prefs_sdk="${PREFS_SDK:-}"
    [[ -z "$prefs_sdk" && -d "$sdkroot/System/Library/PrivateFrameworks/Preferences.framework" ]] && prefs_sdk="$sdkroot"
    if [[ -z "$prefs_sdk" ]]; then
        echo "note: src/prefs present but no SDK with PrivateFrameworks/Preferences; set PREFS_SDK to build it" >&2
    elif [[ ! -d "$prefs_sdk/System/Library/PrivateFrameworks/Preferences.framework" ]]; then
        echo "error: PREFS_SDK $prefs_sdk has no PrivateFrameworks/Preferences.framework" >&2; exit 65
    else
        verify_pinned_sdk "$prefs_sdk" PREFS_SDK
        bundle="$product/Library/PreferenceBundles/$TWEAK_NAME.bundle"
        mkdir -p "$bundle"
        prefs_objs=()
        for src in "$root"/src/prefs/*.m; do
            o="$obj/prefs-$(basename "${src%.m}").o"
            "${CC[@]}" "${common[@]}" "${archs[@]}" -I"$root/src/prefs" -c "$src" -o "$o"
            prefs_objs+=("$o")
        done
        prefs_bin="$bundle/$TWEAK_NAME"
        "${CC[@]}" "${common[@]}" "${archs[@]}" -bundle \
            -F"$prefs_sdk/System/Library/PrivateFrameworks" -framework Preferences \
            -framework Foundation -framework UIKit \
            "${prefs_objs[@]}" -o "$prefs_bin"
        dsymutil "$prefs_bin" -o "$out/$TWEAK_NAME.bundle.dSYM" 2>>"$out/dsymutil.log" || true
        "$root/scripts/verify-symbols.sh" bundle "$prefs_bin" >&2
        print_build_versions "$prefs_bin"
        # Specifier plists and images ship inside the bundle (Root.plist is what
        # loadSpecifiersFromPlistName:@"Root" reads); entry.plist does not, it
        # is the PreferenceLoader entry installed below.
        for res in "$root"/src/prefs/*.plist "$root"/src/prefs/*.png; do
            [[ -e "$res" ]] || continue
            case "$(basename "$res")" in entry.plist) continue ;; esac
            if [[ "$res" == *.plist ]]; then
                plutil -convert xml1 "$res" -o "$bundle/$(basename "$res")"
            else
                cp "$res" "$bundle/"
            fi
        done
        [[ -f "$bundle/Root.plist" ]] || { echo "error: src/prefs/Root.plist is missing" >&2; exit 65; }
        # Info.plist generated from version.txt
        cat >"$bundle/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>$TWEAK_NAME</string>
<key>CFBundleIdentifier</key><string>$PACKAGE_ID.prefs</string>
<key>CFBundleName</key><string>$TWEAK_NAME</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>${version%%-*}</string>
<key>CFBundleVersion</key><string>$version</string>
<key>NSPrincipalClass</key><string>TWListController</string>
</dict></plist>
PLIST
        plutil -convert xml1 "$bundle/Info.plist"
        # PreferenceLoader entry
        pl_dir="$product/Library/PreferenceLoader/Preferences"
        mkdir -p "$pl_dir"
        plutil -convert xml1 "$root/src/prefs/entry.plist" -o "$pl_dir/$TWEAK_NAME.plist"
    fi
fi

# --- optional helper daemon (helper-daemon-hardening); built only when named ---
if [[ -n "${HELPER_LABEL:-}" && -d "$root/src/helper" ]]; then
    helper_bin="$product/usr/libexec/$HELPER_LABEL"
    mkdir -p "$(dirname "$helper_bin")"
    helper_objs=()
    for src in "$root"/src/helper/*.m; do
        o="$obj/helper-$(basename "${src%.m}").o"
        "${CC[@]}" "${common[@]}" "${archs[@]}" -I"$root/src/helper" \
            -DTW_SERVICE_NAME="\"${HELPER_SERVICE:-$PACKAGE_ID.helper}\"" -c "$src" -o "$o"
        helper_objs+=("$o")
    done
    # A helper is MH_EXECUTE: no install name.
    "${CC[@]}" "${common[@]}" "${archs[@]}" \
        -framework Foundation \
        "${helper_objs[@]}" -o "$helper_bin"
    dsymutil "$helper_bin" -o "$out/$HELPER_LABEL.dSYM" 2>>"$out/dsymutil.log" || true
    "$root/scripts/verify-symbols.sh" helper "$helper_bin" >&2
    print_build_versions "$helper_bin"
    # LaunchDaemons plist: @PREFIX@ is the layout prefix for this scheme.
    [[ "$scheme" == roothide ]] && plist_prefix="" || plist_prefix="/var/jb"
    mkdir -p "$product/Library/LaunchDaemons"
    sed -e "s|@PREFIX@|$plist_prefix|g" \
        -e "s|@HELPER_LABEL@|$HELPER_LABEL|g" \
        -e "s|@HELPER_SERVICE@|${HELPER_SERVICE:-$PACKAGE_ID.helper}|g" \
        "$root/packaging/HELPER.plist" >"$product/Library/LaunchDaemons/$HELPER_LABEL.plist"
    plutil -lint "$product/Library/LaunchDaemons/$HELPER_LABEL.plist" >/dev/null
fi

echo "==> built $scheme payload at $product" >&2
printf '%s\n' "$dylib"
