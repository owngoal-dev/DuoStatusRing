# DuoStatusRing — Checklist

One time, before the first release. `make check` runs `scripts/check-checklist.sh`
first, and every build target depends on it, so nothing builds until every box
below is ticked. Tick a box only after doing or deciding the thing, never to get
past the gate; tick an item that does not apply with the reason written after it.
Where an item is evidence-backed, name the verifiable artifact beside the box.
"SKILL.md" is platformize-tweak-ios's; the quoted name is its section.

## Identity and rename

- [x] `configuration/build.env` is filled (TWEAK_NAME, PACKAGE_ID, FILTER_BUNDLE, MIN_IOS, SDK settings) and the author placeholder sweep is empty: `grep -rnE '@[A-Z][A-Z0-9_]*@' --exclude-dir=.git .` shows only the packager tokens. Filled: DuoStatusRing, wiki.qaq.duostatusring, com.apple.springboard, MIN_IOS 16.0 (the Dynamic Island needs iOS 16), Xcode SDK; the placeholder sweep shows only packager tokens.
      SKILL.md "Template", sibling-sweeps.
- [x] The sibling-name sweep prints nothing across `template`-derived files (no product this skill was derived from). Checked by `make check` and a manual grep.
      SKILL.md "Review gates", sibling-sweeps.
- [x] There is no `CLAUDE.md`; `AGENTS.md` is filled and no file names a package manager. AGENTS.md is filled; no package manager is named.
      SKILL.md "The contract".

## Hook targets and filter

- [x] The target class, selector and `TW_ENC(...)` encoding of every `TW_HOOK` are the real ones, and `packaging/TWEAK.plist` scopes to the same bundle/executable the constructor's identity guard matches. Six hooks in `src/tweak.m`, encodings checked against the iOS 26.6.2 class dump; the filter and the identity guard both target SpringBoard.
      `src/tweak.m`, `packaging/TWEAK.plist`; SKILL.md "Preferred ways".
- [x] The constructor's first statement is the identity guard, and the kill-switch marker path (through the path macro) is documented in the release notes. `getprogname()` check first; the kill switch is `TW_JBROOT("/var/mobile/Library/wiki.qaq.duostatusring/disabled")`, documented in the release notes.
      `src/tweak.m`; SKILL.md constructor-safe-mode.

## Substrate provider

- [x] The provider(s) in `configuration/depends.env` are decided; if MSHook* is used it is resolved via `dlsym`, never a load command, and "Depends verified: <provider> on <iOS version>" is recorded in `AGENTS.md`. mobilesubstrate (ElleKit provides it); no MSHook* is used at all (pure runtime hooks); attestation through dpkg is recorded as pending in AGENTS.md.
      SKILL.md substrate-runtime-resolution, hook-lib-depends.

## Scheme paths

- [x] Every bootstrap-relative path goes through `TW_JBROOT` / the path macro; the literal `/var/jb` appears only in `src/tw_jbpath.h`; persistent state is under `TW_JBROOT("/var/...")`. Only the kill-switch path, through TW_JBROOT; the tweak keeps no other state.
      `src/tw_jbpath.h`; SKILL.md jbroot-by-scheme, data-locations.

## arm64e proof

- [x] Both flavors built; `verify-payload.sh` passes; the roothide slice is arm64e USR00 and links only our own `stubs/libroothide.tbd`; the rootless slice is fat and links no libroothide. (ptrauth correctness of hook code stays untested until an A12+ device run.) `make debs` passes verify-payload for both; roothide is arm64e and links our libroothide stub, rootless is arm64+arm64e with no libroothide.
      `make debs`; SKILL.md arch-and-slices, own-libroothide-stub.

## Preference bundle

- [x] If `src/prefs/` ships, `PREFS_SDK` points at an SDK with the private Preferences framework, the bundle builds as MH_BUNDLE, and `preferenceloader` is in Depends; otherwise `src/prefs/` is removed and this is ticked N/A. N/A: no settings by design; src/prefs removed.
      SKILL.md prefs-bundle.

## Helper / daemon trust

- [x] If a helper ships, `HELPER_LABEL`/`HELPER_SERVICE` are set, the wire is a closed enum of jobs (no `exec(path, argv)`), the plist is on-demand (no KeepAlive/RunAtLoad without a documented exception), and its entitlements are the reviewed set; otherwise the helper files are removed and this is ticked N/A. N/A: no helper; helper files removed.
      SKILL.md helper-daemon-hardening, helper-entitlements.

## postinst restart

- [x] The maintainer scripts restart only what the filter targets (SpringBoard respring / executable kill / nothing), boot out the daemon from all three domains if one ships, and `purge` deletes only the recorded state paths. SpringBoard respring on configure only; no daemon; purge removes only the state dir.
      `packaging/DEBIAN/`; SKILL.md maintainer-scripts, uninstall-and-purge-state.

## Licenses

- [x] `Licenses/PROVENANCE.md` and `Licenses/NOTICE` are accurate; everything shipped is MIT/BSD/Apache-2.0/ISC/zlib; no GPL/LGPL text is copied in; `LICENSE` names the right holder and year. Own MIT code plus the vendored MIT roothide.h; LICENSE is MIT, OwnGoal Studio 2026.
      SKILL.md license-provenance.

## Release

- [x] The tag, workflow names, pinned SHAs, draft-then-public flow and `owngoal-packages` asset contract are in place; nothing built locally is ever uploaded; the sensitive-information read-through is a step of every push, tag and release. Template workflows unchanged; tag v1.0.0; Release drafts, the read-through precedes publishing.
      SKILL.md ci-release, review-gate-reading.
