#import "DLIFoldController.h"
#import "DLIStatusFoldView.h"
#import "DLIStatusItems.h"
#import <objc/message.h>
#import <objc/runtime.h>

// The last avoidance frame the system asked a status bar for, so it can be re-applied
// (clipped or not) whenever the fold changes direction.
@interface DLIAvoidanceRequest : NSObject
@property (nonatomic) CGRect frame;
@property (nonatomic, strong) id settings;
@property (nonatomic) NSUInteger options;
@property (nonatomic) BOOL animated;
@property (nonatomic) BOOL appliedSuppressed; // whether the frame last given to the system was clipped
@end

@implementation DLIAvoidanceRequest
@end

static char DLIAvoidanceRequestKey;

@implementation DLIFoldController {
    NSHashTable<UIView *> *_statusBars;
    NSMapTable<UIView *, DLIStatusFoldView *> *_foldViews;
    NSHashTable<UIView *> *_pendingReloads;
    BOOL _hasPhase;
    BOOL _suppressesAvoidance;
    BOOL _reapplyingAvoidance;
    BOOL _contentReloadPending;
    BOOL _subscribed;
    NSMapTable<UIView *, DLIStatusFoldView *> *_idleViews; // detached fold views kept for the next fold
    CFTimeInterval _lastFrameTime;                          // target time of the last display-link frame
    __weak id _pacedSettings;
}

+ (instancetype)sharedController {
    static DLIFoldController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [DLIFoldController new];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _timeline = [DLIFoldTimeline new];
        _observer = [DLIApertureObserver new];
        _statusBars = [NSHashTable weakObjectsHashTable];
        _foldViews = [NSMapTable weakToStrongObjectsMapTable];
        _idleViews = [NSMapTable weakToStrongObjectsMapTable];
        _pendingReloads = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

#pragma mark - Phase

// The design splits the island more slowly than iOS: 0.15 s into the split its primary
// island edge has 55 % of the way left, the system's 38 %. A 1.35x longer response on the
// springs that choreograph two elements (the bubble's Minimal transition and the primary
// island's Inert Collapsing / Compensating transitions) matches that; single-element
// transitions keep the system's timing. The settings objects are edited in place (the
// System Aperture reads their values directly), once per object.
static const double DLIMitosisResponseScale = 1.35;
static char DLIMitosisPacedKey; // the response this tweak last wrote into a settings object

static void DLIPaceMitosis(UIViewController *apertureViewController) {
    id settings = nil;
    @try {
        settings = [apertureViewController valueForKey:@"_settings"];
    } @catch (__unused NSException *e) {
        return;
    }
    for (NSString *transitionKey in @[ @"inertCollapsingInterfaceElementTransitionSettings",
                                        @"inertCompensatingInterfaceElementTransitionSettings",
                                        @"minimalInterfaceElementTransitionSettings" ]) {
        for (NSString *behaviorKey in @[ @"centerBehaviorSettings", @"boundsBehaviorSettings", @"cornerRadiusBehaviorSettings",
                                          @"alphaBehaviorSettings", @"backgroundColorBehaviorSettings", @"defaultBehaviorSettings" ]) {
            @try {
                id behavior = [[settings valueForKey:transitionKey] valueForKey:behaviorKey];
                if (!behavior) continue;
                // A value this tweak wrote is left alone; any other (a new object, a reload
                // of the defaults) is the system's and gets scaled once.
                double response = [[behavior valueForKey:@"response"] doubleValue];
                NSNumber *written = objc_getAssociatedObject(behavior, &DLIMitosisPacedKey);
                if (response <= 0 || (written && fabs(written.doubleValue - response) < 1e-9)) continue;
                double paced = response * DLIMitosisResponseScale;
                [behavior setValue:@(paced) forKey:@"response"];
                objc_setAssociatedObject(behavior, &DLIMitosisPacedKey, @(paced), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } @catch (__unused NSException *e) {
            }
        }
    }
}

- (void)apertureDidLayout:(UIViewController *)apertureViewController {
    id settings = nil;
    @try {
        settings = [apertureViewController valueForKey:@"_settings"];
    } @catch (__unused NSException *e) {
    }
    if (settings && settings != _pacedSettings) {
        _pacedSettings = settings;
        DLIPaceMitosis(apertureViewController);
    }
    BOOL changed = [_observer updateFromApertureViewController:apertureViewController];
    if (!changed && _hasPhase) return;
    BOOL animated = _hasPhase;
    _hasPhase = YES;
    switch (_observer.phase) {
        case DLIAperturePhaseSplit:
            [self setFolded:YES animated:animated];
            break;
        case DLIAperturePhaseSingle:
            [self setFolded:NO animated:animated];
            break;
        case DLIAperturePhaseLandscape:
            [self setFolded:NO animated:NO];
            break;
        case DLIAperturePhaseExpanded:
        case DLIAperturePhaseUnknown:
            // An expanded element covers the status bar; keep whatever is there and
            // decide again when the island collapses.
            break;
    }
}

- (void)setFolded:(BOOL)folded animated:(BOOL)animated {
    CFTimeInterval now = [self renderTime];
    if (folded == _timeline.folded && ![_timeline isAnimatingAtTime:now] && (folded || ![self hasFoldViews])) return;
    _timeline.reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    [_timeline setFolded:folded atTime:now animated:animated];
    if (folded) {
        // Copies first, where the icons are drawn right now; then the icons go back to
        // their normal layout (hidden), which the ring is placed against from the next
        // frame on.
        for (UIView *statusBar in _statusBars.allObjects) [self attachIfEligible:statusBar snapshots:YES];
        [self renderAtTime:now];
        [self setSuppressesAvoidance:YES];
    } else {
        // Snapshots skipped while resting folded are needed from here on.
        for (UIView *statusBar in _foldViews.keyEnumerator.allObjects) [[_foldViews objectForKey:statusBar] takeSnapshotsIfNeeded];
        [self renderAtTime:now];
        [self setSuppressesAvoidance:NO];
    }
    if ([_timeline isAnimatingAtTime:now] && [self hasFoldViews]) {
        [self subscribe];
    } else if (!folded) {
        [self detachAll];
    }
}

#pragma mark - Status bars

// Only status bars laid out around the island fold: the normal mode (Control Center's
// expanded header is mode 1) and as wide as the screen (switcher cards scale their
// status bar from outside, its own width stays the screen's).
- (BOOL)isEligible:(UIView *)statusBar {
    UIWindow *window = statusBar.window;
    if (!window || window.hidden || !DLIStatusBarIsPortrait(statusBar) || !DLIStatusBarForegroundView(statusBar)) return NO;
    if (DLIStatusBarMode(statusBar) != 0) return NO;
    CGFloat screenWidth = (window.screen ?: UIScreen.mainScreen).bounds.size.width;
    return fabs(statusBar.bounds.size.width - screenWidth) < 1;
}

// NSMapTable keeps counting (and holding the values of) entries whose weak key is gone;
// only live status bars count.
- (BOOL)hasFoldViews {
    return _foldViews.keyEnumerator.allObjects.count > 0;
}

// Whether status bars that show up now should get a ring: only while folding or folded.
// One joining mid-unfold stays as it is rather than show a ring it never had.
- (BOOL)acceptsNewStatusBars {
    return _timeline.folded;
}

// Whether fold views are up (folded, or still moving): decided by the controller's own
// state, never by a clock, so it cannot disagree with the display link's last frame.
- (BOOL)isActive {
    return _timeline.folded || _subscribed;
}

- (void)attachIfEligible:(UIView *)statusBar snapshots:(BOOL)snapshots {
    DLIStatusFoldView *view = [_foldViews objectForKey:statusBar];
    if (![self isEligible:statusBar]) {
        if (view) [self detachViewOfStatusBar:statusBar];
        return;
    }
    if (!view) {
        // Fold views outlive a fold: building one (some twenty layers) on the island's
        // first frame would delay it.
        view = [_idleViews objectForKey:statusBar] ?: [[DLIStatusFoldView alloc] initWithStatusBar:statusBar];
        [_idleViews removeObjectForKey:statusBar];
        [_foldViews setObject:view forKey:statusBar];
        snapshots = YES;
        [view reloadItemsTakingSnapshots:snapshots];
        if (!view.items.battery) {
            [self detachViewOfStatusBar:statusBar];
            return;
        }
        if ([_timeline isAnimatingAtTime:[self renderTime]]) [self subscribe];
        [self reapplyAvoidanceForStatusBar:statusBar];
        return;
    }
    [view reloadItemsTakingSnapshots:snapshots];
    // Every iPhone status bar has a battery on the trailing side; finding none means
    // this iOS lays its items out differently, and a ring would be a fake one.
    if (!view.items.battery) [self detachViewOfStatusBar:statusBar];
}

- (void)detachViewOfStatusBar:(UIView *)statusBar {
    DLIStatusFoldView *view = [_foldViews objectForKey:statusBar];
    if (!view) return;
    [view detach];
    [_foldViews removeObjectForKey:statusBar];
    if (statusBar.window) [_idleViews setObject:view forKey:statusBar];
    [self reapplyAvoidanceForStatusBar:statusBar];
}

- (void)detachAll {
    for (UIView *statusBar in _foldViews.keyEnumerator.allObjects) [self detachViewOfStatusBar:statusBar];
    for (DLIStatusFoldView *view in _foldViews.objectEnumerator.allObjects) [view detach]; // keys already gone
    [_foldViews removeAllObjects];
}

// While the display link runs, a render outside it uses the frame being prepared, never
// an earlier time, so nothing steps back.
- (CFTimeInterval)renderTime {
    CFTimeInterval now = CACurrentMediaTime();
    return _subscribed ? MAX(now, _lastFrameTime) : now;
}

- (void)statusBarDidLayout:(UIView *)statusBar {
    // Status bars introduce themselves here (they lay out when created and whenever
    // they enter a window); one that left its window is skipped until it is back.
    if (!statusBar.window) return;
    [_statusBars addObject:statusBar];
    [self reapplyAvoidanceForStatusBar:statusBar];
    DLIStatusFoldView *view = [_foldViews objectForKey:statusBar];
    if (!view) {
        // A status bar can join before it has a size (an app's, as the app launches);
        // fold it once it is laid out.
        if ([self acceptsNewStatusBars] && [self isEligible:statusBar]) [self scheduleContentReloadFor:statusBar];
        return;
    }
    // Layout passes are frequent; only a changed set of icons needs a reload.
    if (view.superview != DLIStatusBarForegroundView(statusBar) || ![self isEligible:statusBar]) {
        [self scheduleContentReloadFor:statusBar];
        return;
    }
    DLIStatusItemSet *items = [DLIStatusItemSet itemsOfStatusBar:statusBar];
    if (![items isEquivalentToSet:view.items]) {
        // An icon that just appeared is hidden in this very commit; snapshots and the
        // rest of the reload can wait for the next turn.
        for (DLIStatusItem *item in items.items) [view hideSystemIcon:item.view];
        [self scheduleContentReloadFor:statusBar];
    }
}

- (void)statusBarDidUpdateContent:(UIView *)statusBar {
    if ([_foldViews objectForKey:statusBar]) [self scheduleContentReloadFor:statusBar];
}

// Data, style and layout updates arrive in bursts; reload each status bar once after
// the burst.
- (void)scheduleContentReloadFor:(UIView *)statusBar {
    [_pendingReloads addObject:statusBar];
    if (_contentReloadPending) return;
    _contentReloadPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_contentReloadPending = NO;
        NSArray<UIView *> *bars = self->_pendingReloads.allObjects;
        [self->_pendingReloads removeAllObjects];
        CFTimeInterval now = [self renderTime];
        if (![self isActive]) return;
        // At rest the snapshots are not on screen; they are retaken when the fold moves.
        BOOL moving = [self->_timeline isAnimatingAtTime:now];
        for (UIView *bar in bars) {
            if ([self->_foldViews objectForKey:bar] || [self acceptsNewStatusBars]) [self attachIfEligible:bar snapshots:moving];
        }
        [self renderAtTime:now];
    });
}

#pragma mark - Rendering

- (void)subscribe {
    if (_subscribed) return;
    _subscribed = YES;
    [DLIDisplayLink.sharedLink addSubscriber:self];
}

- (void)unsubscribe {
    if (!_subscribed) return;
    _subscribed = NO;
    [DLIDisplayLink.sharedLink removeSubscriber:self];
}

- (void)renderAtTime:(CFTimeInterval)time {
    if (![self hasFoldViews]) return;
    DLIFoldProgress progress;
    memset(&progress, 0, sizeof(progress));
    for (NSInteger i = 0; i < DLIFoldPartCount; i++) progress.parts[i] = [_timeline progressOfPart:i atTime:time];
    // Status bars lay out in screen-sized coordinates even when a switcher card scales
    // them, so the island's screen frame is the right reference for all of them.
    CGRect island = _observer.islandFrame;
    BOOL keepRing = !_timeline.folded;
    BOOL moving = [_timeline isAnimatingAtTime:time];
    for (UIView *statusBar in _foldViews.keyEnumerator.allObjects)
        [[_foldViews objectForKey:statusBar] renderWithProgress:progress crossfade:_timeline.crossfading island:island
                                                         keepRing:keepRing moving:moving time:time];
}

- (void)displayLinkWillDrawFrameAt:(CFTimeInterval)targetTimestamp {
    _lastFrameTime = targetTimestamp;
    [self renderAtTime:targetTimestamp];
    if ([_timeline isAnimatingAtTime:targetTimestamp]) return;
    [self unsubscribe];
    if (!_timeline.folded) [self detachAll];
}

#pragma mark - Avoidance

- (void)setSuppressesAvoidance:(BOOL)suppresses {
    if (_suppressesAvoidance == suppresses) return;
    _suppressesAvoidance = suppresses;
    for (UIView *statusBar in _statusBars.allObjects) [self reapplyAvoidanceForStatusBar:statusBar];
}

- (BOOL)clipsAvoidanceOfStatusBar:(UIView *)statusBar {
    return _suppressesAvoidance && [_foldViews objectForKey:statusBar] != nil;
}

- (CGRect)adjustedAvoidanceFrame:(CGRect)frame forStatusBar:(UIView *)statusBar {
    if (![self clipsAvoidanceOfStatusBar:statusBar] || CGRectIsNull(frame) || CGRectIsEmpty(frame)) return frame;
    CGRect island = _observer.islandFrame;
    if (CGRectIsNull(island)) return frame;
    // In mitosis the primary element ends at the island's right edge; everything right
    // of it is the bubble, which the ring replaces.
    CGFloat limit = CGRectGetMaxX(island) + 2;
    if (CGRectGetMaxX(frame) > limit) frame.size.width = MAX(0, limit - frame.origin.x);
    return frame;
}

- (id)livelierAvoidanceSettings:(id)settings {
    static Class springClass;
    if (!springClass) springClass = NSClassFromString(@"BSSpringAnimationSettings");
    if (!springClass || ![settings isKindOfClass:springClass]) return settings;
    @try {
        double mass = [[settings valueForKey:@"mass"] doubleValue];
        double stiffness = [[settings valueForKey:@"stiffness"] doubleValue];
        double damping = [[settings valueForKey:@"damping"] doubleValue];
        // Damping ratio 0.72 instead of the system's 0.816, never more damped than given.
        double target = 2 * 0.72 * sqrt(stiffness * mass);
        if (mass <= 0 || stiffness <= 0 || target >= damping) return settings;
        id lively = [settings mutableCopy];
        [lively setValue:@(target) forKey:@"damping"];
        return lively ?: settings;
    } @catch (__unused NSException *e) {
        return settings;
    }
}

- (void)statusBar:(UIView *)statusBar didRequestAvoidanceFrame:(CGRect)frame settings:(id)settings
          options:(NSUInteger)options animated:(BOOL)animated {
    if (_reapplyingAvoidance) return;
    DLIAvoidanceRequest *request = objc_getAssociatedObject(statusBar, &DLIAvoidanceRequestKey);
    if (!request) {
        request = [DLIAvoidanceRequest new];
        objc_setAssociatedObject(statusBar, &DLIAvoidanceRequestKey, request, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    request.frame = frame;
    request.settings = settings;
    request.options = options;
    request.animated = animated;
    request.appliedSuppressed = [self clipsAvoidanceOfStatusBar:statusBar];
}

- (void)reapplyAvoidanceForStatusBar:(UIView *)statusBar {
    DLIAvoidanceRequest *request = objc_getAssociatedObject(statusBar, &DLIAvoidanceRequestKey);
    BOOL clips = [self clipsAvoidanceOfStatusBar:statusBar];
    // A status bar outside a window gets its frame again when it comes back.
    if (!request || request.appliedSuppressed == clips || !statusBar.window) return;
    request.appliedSuppressed = clips;
    _reapplyingAvoidance = YES;
    if (request.animated) {
        SEL selector = NSSelectorFromString(@"setAvoidanceFrame:animationSettings:options:");
        if ([statusBar respondsToSelector:selector]) {
            ((void (*)(id, SEL, CGRect, id, NSUInteger))objc_msgSend)(statusBar, selector, request.frame, request.settings,
                                                                     request.options);
        }
    } else {
        SEL selector = NSSelectorFromString(@"setAvoidanceFrame:");
        if ([statusBar respondsToSelector:selector])
            ((void (*)(id, SEL, CGRect))objc_msgSend)(statusBar, selector, request.frame);
    }
    _reapplyingAvoidance = NO;
}

@end
