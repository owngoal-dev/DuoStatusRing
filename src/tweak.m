// tweak.m — the injected dylib entry point and every hook.
//
// Shape (constructor-safe-mode): one constructor, gated on process identity, with
// one kill switch, that then installs the hooks. TW_HOOK bodies below only
// register into the table; nothing installs until tw_constructor() has passed the
// identity guard and the kill-switch stat(). Each encoding (TW_ENC) is compared
// against the live method before its hook installs; a mismatch leaves that method
// alone and the fold degrades instead of corrupting registers.
//
// The hooks only report to DLIFoldController (src/DLIFoldController.m), which owns
// all behavior. None of them changes what the system method does, except the two
// avoidance setters, which pass an adjusted frame and spring (see the controller).
#import <UIKit/UIKit.h>
#include <string.h>
#include <sys/stat.h>
#include "tw_config.h"
#include "tw_hook.h"
#include "tw_jbpath.h"
#import "DLIFoldController.h"

// TW_VERSION is emitted as a used, non-stripped constant with a fixed marker so
// it is readable from the shipped binary (version-single-source). It gets a
// section of its own: in __TEXT,__const the linker placed an optimized,
// unterminated constant right before it, and the two read as one string.
__attribute__((used, visibility("default"), section("__TEXT,__tw_version")))
const char tw_version_marker[] = "TWEAKVER=" TW_VERSION;

// The status bars and the Dynamic Island are drawn by SpringBoard alone (apps have
// no status bar view of their own on iOS 26), so SpringBoard is the only target.
static const char *const kTargetExecutables[] = { "SpringBoard" };

static os_log_t tw_ctor_log(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(TW_PACKAGE_ID, "load"); });
    return log;
}

// Set while either avoidance setter runs, in case one forwards to the other (iOS
// forwards the one-argument setter to the three-argument one): the frame is then
// already adjusted and must not be recorded or adjusted again.
static NSUInteger DLIAvoidanceDepth = 0;

// The System Aperture posts its layout (visible elements and their frames) here.
TW_HOOK(apertureLayout, "SBSystemApertureViewController", "_postLayoutDidChangeNotificationIfNecessary",
        TW_ENC(@encode(void), "@:"), void) {
    if (TW_ORIG(apertureLayout)) TW_ORIG(apertureLayout)(self, _cmd);
    [[DLIFoldController sharedController] apertureDidLayout:self];
}

// Every status bar lays out when it is created, moved to a window, resized or
// given new items: the one place to learn about them.
TW_HOOK(statusBarLayout, "STUIStatusBar", "layoutSubviews", TW_ENC(@encode(void), "@:"), void) {
    if (TW_ORIG(statusBarLayout)) TW_ORIG(statusBarLayout)(self, _cmd);
    [[DLIFoldController sharedController] statusBarDidLayout:self];
}

TW_HOOK(statusBarData, "STUIStatusBar", "_updateWithAggregatedData:",
        TW_ENC(@encode(void), "@:", @encode(id)), void, id data) {
    if (TW_ORIG(statusBarData)) TW_ORIG(statusBarData)(self, _cmd, data);
    [[DLIFoldController sharedController] statusBarDidUpdateContent:self];
}

TW_HOOK(statusBarStyle, "STUIStatusBar", "_updateStyleAttributes", TW_ENC(@encode(void), "@:"), void) {
    if (TW_ORIG(statusBarStyle)) TW_ORIG(statusBarStyle)(self, _cmd);
    [[DLIFoldController sharedController] statusBarDidUpdateContent:self];
}

TW_HOOK(avoidanceAnimated, "STUIStatusBar", "setAvoidanceFrame:animationSettings:options:",
        TW_ENC(@encode(void), "@:", @encode(CGRect), @encode(id), @encode(NSUInteger)), void,
        CGRect frame, id settings, NSUInteger options) {
    if (!TW_ORIG(avoidanceAnimated)) return;
    if (DLIAvoidanceDepth > 0) {
        TW_ORIG(avoidanceAnimated)(self, _cmd, frame, settings, options);
        return;
    }
    DLIFoldController *controller = [DLIFoldController sharedController];
    [controller statusBar:self didRequestAvoidanceFrame:frame settings:settings options:options animated:YES];
    DLIAvoidanceDepth++;
    TW_ORIG(avoidanceAnimated)(self, _cmd, [controller adjustedAvoidanceFrame:frame forStatusBar:self],
                               [controller livelierAvoidanceSettings:settings], options);
    DLIAvoidanceDepth--;
}

TW_HOOK(avoidance, "STUIStatusBar", "setAvoidanceFrame:", TW_ENC(@encode(void), "@:", @encode(CGRect)), void,
        CGRect frame) {
    if (!TW_ORIG(avoidance)) return;
    if (DLIAvoidanceDepth > 0) {
        TW_ORIG(avoidance)(self, _cmd, frame);
        return;
    }
    DLIFoldController *controller = [DLIFoldController sharedController];
    [controller statusBar:self didRequestAvoidanceFrame:frame settings:nil options:0 animated:NO];
    DLIAvoidanceDepth++;
    TW_ORIG(avoidance)(self, _cmd, [controller adjustedAvoidanceFrame:frame forStatusBar:self]);
    DLIAvoidanceDepth--;
}

static bool tw_is_target(void) {
    const char *name = getprogname();
    if (!name) return false;
    for (size_t i = 0; i < sizeof(kTargetExecutables) / sizeof(*kTargetExecutables); ++i) {
        if (strcmp(name, kTargetExecutables[i]) == 0) return true;
    }
    return false;
}

// One marker file in the tweak's own state dir disables injection: a present,
// readable marker turns the tweak off; missing or unreadable means run normally.
// The path is documented in the release notes.
static bool tw_kill_switch_present(void) {
    const char *marker = TW_JBROOT("/var/mobile/Library/" TW_PACKAGE_ID "/disabled");
    struct stat st;
    return marker && stat(marker, &st) == 0;
}

__attribute__((constructor)) static void tw_constructor(void) {
    if (!tw_is_target()) return;               // identity guard: first, cheap
    if (tw_kill_switch_present()) {            // one stat, before any hook
        os_log(tw_ctor_log(), "kill switch present; not injecting");
        return;
    }
    tw_install_all();
    os_log(tw_ctor_log(), "loaded %s", tw_version_marker);
}
