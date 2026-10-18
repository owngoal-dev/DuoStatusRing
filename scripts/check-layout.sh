#!/usr/bin/env bash
#
# check-layout.sh — repo skeleton and hygiene (repo-hygiene, source-mode).
#
# Runs over the tracked files (git ls-files where available, else find) because
# macOS is case-insensitive and a casing mistake only shows on Linux CI.

set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
fail=0
err() { echo "error: $*" >&2; fail=1; }

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mapfile -t files < <(git ls-files)
else
    mapfile -t files < <(find . -type f -not -path './.git/*' -not -path './build/*' | sed 's|^\./||')
fi

# No CLAUDE.md, no agent-doc variants.
for f in "${files[@]}"; do
    case "$f" in
    CLAUDE.md|*/CLAUDE.md|.cursorrules|*/.cursorrules) err "$f must not exist (AGENTS.md only)" ;;
    esac
done

# Lowercase top-level dirs; only these names keep conventional case.
for f in "${files[@]}"; do
    top="${f%%/*}"
    case "$top" in
    configuration|packaging|scripts|patches|docs|src|stubs|Licenses|tests|.github) : ;;
    AGENTS.md|README.md|LICENSE|CHECKLIST.md|makefile|.gitignore|CHANGELOG.md|manifest.json) : ;;
    *) err "unexpected top-level entry: $top" ;;
    esac
done

# DEBIAN keeps its case exactly.
for f in "${files[@]}"; do
    case "$f" in
    packaging/debian/*|packaging/Debian/*) err "the control dir must be exactly DEBIAN: $f" ;;
    esac
done

# No tracked scratch, no tracked debs/dSYMs, no generator configs.
for f in "${files[@]}"; do
    case "$f" in
    plan.md|*/plan.md|scratch/*|*/scratch/*|*.draft.md) err "tracked scratch: $f" ;;
    *.deb) err "tracked .deb (Release publishes; never commit): $f" ;;
    *.dSYM/*) err "tracked dSYM: $f" ;;
    Tuist/*|Project.swift|Workspace.swift|*.xcodegen|project.yml) err "project generator config: $f" ;;
    esac
done

# .gitignore must ignore build output, macOS metadata and debs.
if [[ -f .gitignore ]]; then
    for line in '/build/' '.DS_Store' '*.deb'; do
        grep -qxF "$line" .gitignore || err ".gitignore missing line: $line"
    done
else
    err ".gitignore is missing"
fi

# The owngoal-packages entry lives at the root; under docs/ Pages would serve it.
[[ -f manifest.json ]] || err "manifest.json is missing at the repo root"
[[ -e docs/manifest.json ]] && err "docs/manifest.json: move it to the repo root"

# Source mode vs pinned-upstream mode (source-mode).
upstream_files=(configuration/upstream.env patches scripts/prepare-source.sh scripts/follow-upstream.sh scripts/rebase-patches.sh .github/workflows/follow-upstream.yml)
if [[ -f configuration/upstream.env ]]; then
    ref="$(grep -E '^UPSTREAM_REF=' configuration/upstream.env | head -n1 | cut -d= -f2)"
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || err "upstream mode: UPSTREAM_REF is not a full 40-hex sha"
    for u in scripts/prepare-source.sh scripts/rebase-patches.sh; do
        [[ -e "$u" ]] || err "upstream mode: missing $u"
    done
else
    # src mode: src/ must hold sources; upstream-only files must be absent.
    [[ -n "$(find src -type f 2>/dev/null)" ]] || err "src mode: src/ is empty"
    for u in "${upstream_files[@]}"; do
        [[ -e "$u" ]] && err "src mode: upstream-only path present: $u"
    done
fi

(( fail )) && exit 65
echo "==> layout ok" >&2
