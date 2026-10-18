#!/usr/bin/env bash
#
# apply-version.sh <version> — write the package version to
# configuration/version.txt. Accepts a v-prefixed release tag too, because CI
# hands it "$GITHUB_REF_NAME". X.Y.Z is the tweak's own release; X.Y.Z-N a
# packaging respin. This is the single source of the version; control, the prefs
# Info.plist and the TW_VERSION marker are generated from it at build time.

set -Eeuo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <version>" >&2; exit 64; }
version="${1#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]] || {
    echo "error: version must look like 1.2.3 or 1.2.3-2 (got '$1')" >&2; exit 64; }

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
printf '%s\n' "$version" >"$root/configuration/version.txt"
echo "version is now $version"
