DuoStatusRing — Fold the status bar into a ring when the Dynamic Island splits. Built for jailbroken iOS as a MobileSubstrate tweak, for both roothide and rootless bootstraps.

## Which one do I download?

The architecture field names the **bootstrap layout, not the CPU**.

| your bootstrap | download |
| -------------- | -------- |
| roothide | `@PACKAGE_ID@_@VERSION@_iphoneos-arm64e.deb` |
| rootless | `@PACKAGE_ID@_@VERSION@_iphoneos-arm64.deb` |

Not sure? Ask the device: `dpkg --print-architecture`.

Requires **iOS @MIN_IOS@ or later**. Or add the [OwnGoal Studio repository](https://github.com/owngoal-dev/owngoal-packages) and let your preferred package manager pick.

## What gets injected and restarted

@INJECTION_SUMMARY@

## Status

@STATUS_ROOTHIDE@
@STATUS_ROOTLESS@

## Uninstall and kill switch

Removing the package leaves your settings in place; choose **purge** in your preferred package manager to also delete this tweak's state and preference domain.

To disable injection without removing the package, create the marker file this tweak checks at load (`@KILL_SWITCH_PATH@`) and respring; delete it to re-enable. On roothide, per-app injection can also be turned off in the jailbreak's manager — if the tweak seems inactive in an app, check that first. Restart behavior is untested until run on a device.

## Verify your download

Check your download against `SHA256SUMS`.
