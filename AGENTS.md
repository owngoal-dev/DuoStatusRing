# DuoStatusRing — Agent Notes

DuoStatusRing — Fold the status bar into a ring when the Dynamic Island splits. A
MobileSubstrate tweak built for jailbroken iOS with the plain Xcode toolchain (no
Theos as a build system) and packaged for both **roothide** (iphoneos-arm64e) and
**rootless** (iphoneos-arm64). This repository holds the tweak's own source under
`src/`; everything runs through `scripts/`, so CI and a local checkout run the same
bytes.

Source mode: **own source** (there is no `configuration/upstream.env`).

## Hard rules

- **No Theos as a build system.** Build with `xcrun clang` and an explicit
  `-isysroot` (`TWEAK_SDK`). `scripts/check-no-theos.sh` enforces this.
- **Facts come from a device, an SDK or a build, never from memory.** Label each
  device-behavior fact below `statically verified` (name the command) or
  `device-observed` (name the run). Never paste a device hostname, serial, UDID,
  ECID or address anywhere.
- **Name no specific package manager.** Say "your preferred package manager".
- **Published packages come from the Release workflow only.** Local `make debs`
  proves the build; nothing built locally is uploaded.
- **Review for sensitive information by reading before every push, tag and
  release.** `scripts/check-docs.sh` and `audit-tweak-debs.py` are backstops.
- **Every symbol carries the DLI prefix** (classes, C functions, statics,
  associated-object keys, layer names `dli.`, animation keys `dli.`): SpringBoard
  hosts many tweaks. All hooks live in `src/tweak.m` and go through `tw_hook.h`.
- **No settings.** Every situation is handled automatically; there is no
  preference bundle and there must not be one.
- **The island stays native.** The tweak never draws or lays out System Aperture
  content. Its one change to the island is pacing (see below).
- **System icons are hidden with an empty `layer.mask`**, never with
  alpha/hidden/transform, which the status bar animates itself. Everything hidden
  is unhidden when the fold view detaches.

## How the tweak works

When the System Aperture (SA, the Dynamic Island) shows two elements side by side
(native mitosis: a primary island plus a minimal bubble), the status bar's trailing
icons fold into a ring beside the bubble: the battery squeezes into a dot that
grows into a 240° arc (fill = charge, in the system battery's fill color), the
signal bars fall onto the ring as four dots, and Wi-Fi moves into the center as a
hand-drawn glyph (`DLIWifiGlyphLayer`; slashed when there is no connection). When
the SA goes back to one element, everything unfolds. Copies drawn from the icons'
live state do the morph; the system icons stay in place, hidden.

Hooks (`src/tweak.m`, each checked against its type encoding before installing):

| class | selector | what it does |
| --- | --- | --- |
| `SBSystemApertureViewController` | `_postLayoutDidChangeNotificationIfNecessary` | after the original, reads the SA's layout report (`_cachedLayoutDidChangeUserInfo`: visible element identifiers and frames) and folds while two are visible |
| `STUIStatusBar` | `layoutSubviews` | registers the status bar, reloads its ring when its icons change |
| `STUIStatusBar` | `_updateWithAggregatedData:`, `_updateStyleAttributes` | data and style changes reach the ring (eased over 0.3 s) |
| `STUIStatusBar` | `setAvoidanceFrame:animationSettings:options:`, `setAvoidanceFrame:` | while folded, the trailing part of the avoidance frame is clipped at the island so the hidden icons keep their normal layout (the ring is placed against it); the leading part, which moves the clock, stays native. The spring gets damping ratio 0.72 so the clock and icons follow the island's width with a slight bounce |

Pacing: on the first SA layout, the response of the springs that choreograph two
elements (`minimal`, `inertCollapsing` and `inertCompensating` interface element
transition settings, all six behaviors each) is multiplied by 1.35 in place, once
per settings object (an associated marker records the value written). That
matches the design's split speed.

Folding applies only to status bars in normal mode, as wide as the screen,
portrait, in a visible window, with a battery item on the trailing side. Control
Center's expanded header (mode 1, narrower) and landscape are left alone.

| file | role |
| --- | --- |
| `DLIApertureObserver` | the SA report reduced to a phase: Single, Split, Expanded, Landscape |
| `DLIFoldController` | phase to fold target; fold views; display link; avoidance policy |
| `DLIFoldTimeline` | per-part closed-form damped springs; retargeting keeps position and velocity; the arc waits for the battery when folding and the battery for the arc when unfolding |
| `DLIFoldGeometry` | pure function from live icon states and progress to every drawn shape (tested on the Mac) |
| `DLIStatusItems` | reads and classifies a status bar's trailing items; live states, snapshots, masks |
| `DLIStatusFoldView` | the layers over one status bar's foreground view |
| `DLIWifiGlyphLayer` | the ring's Wi-Fi glyph; bands fade on signal changes, the lost slash draws in |
| `DLIDisplayLink` | one shared CADisplayLink, weak subscribers, released when idle; 80–120 Hz, 30–60 in Low Power Mode |

## Device facts

Observed on a virtual iPhone (iPhone Air, iOS 26.6.2, roothide bootstrap with
ElleKit), with the development dylib from `tests/device/`:

- The tweak loads into SpringBoard and folds and unfolds on the home screen, the
  lock screen and over apps; interruption sequences show no double drawing, blank
  frames or jumps (`tests/device/vphone/suite.sh`, `foldcheck.py`), and no
  SpringBoard crash report appears: **device-observed**, roothide, with the
  package's payload placed where it installs (the deb itself was not installed
  through dpkg; the guest has no dpkg entry point without ssh).
- App status bars are drawn by SpringBoard (in `SBMainSwitcherWindow`); apps have
  no status bar view of their own, so SpringBoard is the only target:
  **device-observed** (view tree dumps with an app in front).
- SA springs are SBFFluidBehaviorSettings with response 0.512, damping ratio 0.816
  for every interface element transition; `mitosisHeadstartDelay` 0.13. The SA
  animates with UIKit animatable properties, so presentation layers are the
  ground truth: **device-observed** (settings dump, per-frame recordings).
- The status bar's avoidance frame is the union of the visible SA elements. The
  DynamicSplit visual provider hides the cellular icon and condenses the rest
  when the bubble or a wide island is in the way: **device-observed**.
- `-[STUIStatusBar setAvoidanceFrame:]` forwards to
  `setAvoidanceFrame:animationSettings:options:` with nil settings: **statically
  verified** on iOS 18.6 (disassembly of SystemStatusUI during review); on 26.6.2
  the two-way depth guard in `tweak.m` covers either direction.
- `-[STUIStatusBar setOverlayData:]` re-enters `_updateWithAggregatedData:` before
  the data is stored (relevant to the development dylib's simulated radios):
  **device-observed** (a direct re-apply recursed).
- Status bar icons pop in from twice their size when the system re-adds them; the
  copies clamp the live scale to at most 1: **device-observed**.
- Injection on rootless: **untested**.
- Kill-switch marker disables injection: **untested**.
- Depends verified: `mobilesubstrate` (provided by ElleKit) on iOS 26.6.2:
  **not yet attested through dpkg**.

## Import exceptions

None. The injected dylib carries no import from the denylist.

## Allowed diagnostic files

None.

## Uninstall behavior

`remove` deletes only dpkg-installed files. `purge` also deletes the state dir
(with the kill-switch marker inside it, `@PREFIX@/var/mobile/Library/<id>`) and the
preference-domain plist on the real rootfs (the tweak writes none). roothide's
maintainer scripts see jbroot as `/` and the real rootfs as `/rootfs` (statically
verified: roothide `Developer/roothide.md`); that the rendered paths remove the
right files on a device is **untested**. Install and upgrade respring SpringBoard.

## Testing

`tests/host/run.sh` (Mac): end states, momentum on retarget, the battery/arc
dependency across every reversal time, and 400 random interruption sequences
checked frame by frame against the uninterrupted animation's speed and
acceleration.

On a virtual iPhone: `make deb-roothide`, then `tests/device/deploy.sh` (payload
plus the development dylib, respring) and `tests/device/vphone/ready.sh`. The
development dylib listens for `app.yellowplus.dli.dump` with commands written to
`/var/mobile/Library/Caches/dli_classes.txt` (`tests/device/vphone/dumpfetch.sh`):
`^radios:…` simulated radio and battery data, `^seq:inc@0,dec@0.3` timed test
elements (`SBSystemApertureTestRecipe`), `^capture:start:<pt>:<fps>` /
`^capture:stop` screen recording, `^state`, `^bars`, `^snap:Class`, `$Class`
layer tree. `suite.sh` runs interruption sequences with the per-frame recorder;
`foldcheck.py` flags double drawing, blank frames and jumps for every status bar;
`demo.sh` records the demo. Check `crashes.sh` after every run.

## Layout

```
configuration/build.env      author config (names, SDK + its pin)
configuration/version.txt     the one version source
configuration/depends.env     providers + optional ceiling per scheme
src/                          tweak.m (hooks), tw_config.h, tw_hook.h, tw_jbpath.h, DLI*
stubs/                        our MIT libroothide.tbd + vendored MIT roothide.h
packaging/                    control, maintainer scripts, TWEAK.plist, release notes
scripts/                      build, package, verify and gate scripts
tests/host/                   Mac tests of the timeline and geometry
tests/device/                 development dylib and virtual-iPhone scripts (never packaged)
docs/                         depiction.json, icon, header, preview (deployed to Pages)
manifest.json                 the owngoal-packages entry
build/                        generated; never committed
```
