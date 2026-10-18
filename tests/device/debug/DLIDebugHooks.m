// DLIDebugHooks.m — development-only hooks for the vphone test harness.
//
// The VM has no baseband or Wi-Fi, so tests give every status bar simulated radio
// and battery data (see ^radios in DLIDebugDump.m). SpringBoard replaces or drops
// overlay data now and then; these hooks keep the simulated data on for a whole
// test. Setting overlay data re-enters -_updateWithAggregatedData: before the new
// data is stored (a direct re-apply recursed until the stack overflowed), so the
// check runs one turn of the run loop later, once per status bar.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DLIDebugDump.h"

static IMP DLIDebugOriginalUpdate;
static IMP DLIDebugOriginalLayout;

static void DLIDebugEnsureOverlay(UIView *bar) {
    static NSHashTable *pending;
    if (!pending) pending = [NSHashTable weakObjectsHashTable];
    if (!DLIDebugIsRadioOverlayActive() || [pending containsObject:bar]) return;
    [pending addObject:bar];
    __weak UIView *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strong = weakBar;
        if (!strong) return;
        [pending removeObject:strong];
        id current = nil;
        @try {
            current = [strong valueForKey:@"overlayData"];
        } @catch (__unused NSException *e) {
        }
        if (DLIDebugIsRadioOverlayActive() && !DLIDebugIsRadioOverlay(current)) DLIDebugApplyRadioOverlayIfNeeded(strong);
    });
}

static void DLIDebugUpdate(UIView *self, SEL _cmd, id data) {
    ((void (*)(id, SEL, id))DLIDebugOriginalUpdate)(self, _cmd, data);
    DLIDebugEnsureOverlay(self);
}

static void DLIDebugLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))DLIDebugOriginalLayout)(self, _cmd);
    DLIDebugEnsureOverlay(self);
}

void DLIDebugHooksInstall(void) {
    Class bar = NSClassFromString(@"STUIStatusBar");
    Method update = bar ? class_getInstanceMethod(bar, NSSelectorFromString(@"_updateWithAggregatedData:")) : NULL;
    Method layout = bar ? class_getInstanceMethod(bar, @selector(layoutSubviews)) : NULL;
    if (update) DLIDebugOriginalUpdate = method_setImplementation(update, (IMP)DLIDebugUpdate);
    if (layout) DLIDebugOriginalLayout = method_setImplementation(layout, (IMP)DLIDebugLayout);
}
