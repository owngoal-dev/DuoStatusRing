#import "DLIStatusFoldView.h"
#import "DLIStatusItems.h"
#import "DLIWifiGlyphLayer.h"

@implementation DLIStatusFoldView {
    CALayer *_dots[DLI_MAX_BARS];
    CALayer *_center;
    DLIWifiGlyphLayer *_glyph;
    CALayer *_battery;
    CALayer *_capsule;
    CALayer *_capsuleFill;
    CALayer *_capsuleTrack;
    CAShapeLayer *_track;
    CAShapeLayer *_fill;
    NSMutableArray<CALayer *> *_ghosts; // one per item, at the item's live state
    NSInteger _barCount;
    DLIBarShape _barShapes[DLI_MAX_BARS];
    NSArray<UIColor *> *_barColors;
    UIColor *_inactiveColor;
    UIColor *_trackColor;                // the arc's empty part (design: 30 % of the foreground)
    UIColor *_fillColor;
    CGFloat _level;
    CGRect _body;
    CGFloat _bodyCorner;
    CGPoint _pathCenter;
    CGFloat _pathRadius;
    NSHashTable<UIView *> *_hiddenViews; // every system icon this view has hidden
    DLIRing _ring;
    BOOL _hasRing;
    BOOL _hasGlyph;                      // the center is the ring's Wi-Fi glyph (or its lost state)
    BOOL _contentChanged;                // a reload changed data: animate colors and level once
    BOOL _rendered;
    BOOL _snapshotsDirty;                // icon snapshots are older than the icons
    CGFloat _signalShown;                // the bars' visibility, eased (the system hides them at once)
    CFTimeInterval _lastRenderTime;
    BOOL _hasSignalShown;
}

static CALayer *DLIFoldLayer(NSString *name) {
    CALayer *layer = [CALayer layer];
    layer.name = name;
    layer.hidden = YES;
    layer.contentsGravity = kCAGravityResize;
    return layer;
}

static CAShapeLayer *DLIFoldArcLayer(NSString *name) {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.name = name;
    layer.hidden = YES;
    layer.fillColor = nil;
    layer.lineCap = kCALineCapRound;
    return layer;
}

- (instancetype)initWithStatusBar:(UIView *)statusBar {
    if ((self = [super initWithFrame:CGRectZero])) {
        _statusBar = statusBar;
        self.userInteractionEnabled = NO;
        self.accessibilityElementsHidden = YES;
        self.layer.name = @"dli.fold";
        // Above every icon the status bar adds or reorders later.
        self.layer.zPosition = 1000;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _ghosts = [NSMutableArray array];
        _hiddenViews = [NSHashTable weakObjectsHashTable];
        _track = DLIFoldArcLayer(@"dli.track");
        _fill = DLIFoldArcLayer(@"dli.fill");
        _capsule = DLIFoldLayer(@"dli.capsule");
        // The shrinking battery keeps its split: charge on the left, the rest dim, as the
        // arc it turns into.
        _capsule.masksToBounds = YES;
        _capsuleFill = [CALayer layer];
        _capsuleTrack = [CALayer layer];
        _capsuleFill.anchorPoint = _capsuleTrack.anchorPoint = CGPointZero;
        [_capsule addSublayer:_capsuleTrack];
        [_capsule addSublayer:_capsuleFill];
        _battery = DLIFoldLayer(@"dli.battery");
        _center = DLIFoldLayer(@"dli.center");
        _glyph = [DLIWifiGlyphLayer layer];
        _glyph.name = @"dli.vector";
        _glyph.hidden = YES;
        [self.layer addSublayer:_track];
        [self.layer addSublayer:_fill];
        [self.layer addSublayer:_battery];
        [self.layer addSublayer:_capsule];
        [self.layer addSublayer:_center];
        [self.layer addSublayer:_glyph];
        for (NSInteger i = 0; i < DLI_MAX_BARS; i++) {
            _dots[i] = DLIFoldLayer([NSString stringWithFormat:@"dli.dot%ld", (long)i]);
            [self.layer addSublayer:_dots[i]];
        }
        _pathRadius = -1;
    }
    return self;
}

- (void)reloadItemsTakingSnapshots:(BOOL)snapshots {
    UIView *statusBar = _statusBar;
    UIView *foreground = DLIStatusBarForegroundView(statusBar);
    if (!foreground) return;
    // Called from inside system layout and animation blocks; nothing here may animate.
    [UIView performWithoutAnimation:^{
        if (self.superview != foreground) [foreground addSubview:self];
        if (!CGRectEqualToRect(self.frame, foreground.bounds)) self.frame = foreground.bounds;
    }];

    DLIStatusItemSet *items = [DLIStatusItemSet itemsOfStatusBar:statusBar];
    // An icon that leaves while folded (Wi-Fi drops, an indicator turns off) stays hidden:
    // the system fades it out where it was, outside the ring. Detaching restores it.
    // What the ring shows changes with a short crossfade instead of a cut.
    if (_items && ![items isEquivalentToSet:_items] && !self.layer.hidden) {
        CATransition *fade = [CATransition animation];
        fade.type = kCATransitionFade;
        fade.duration = 0.25;
        [self.layer addAnimation:fade forKey:@"dli.content"];
    }
    _items = items;

    UIColor *foregroundColor = DLIStatusBarForegroundColor(statusBar);
    CGColorRef colors[DLI_MAX_BARS] = {0};
    _barCount = items.signal ? DLIStatusSignalBars(items.signal.view, _barShapes, colors, DLI_MAX_BARS) : 0;
    NSMutableArray<UIColor *> *barColors = [NSMutableArray array];
    for (NSInteger i = 0; i < _barCount; i++)
        [barColors addObject:colors[i] ? [UIColor colorWithCGColor:colors[i]] : foregroundColor];
    _barColors = barColors;
    UIColor *inactive = nil;
    @try {
        inactive = [items.signal.view valueForKey:@"inactiveColor"];
    } @catch (__unused NSException *e) {
    }
    _inactiveColor = [inactive isKindOfClass:UIColor.class] ? inactive : [foregroundColor colorWithAlphaComponent:0.2];
    _trackColor = [foregroundColor colorWithAlphaComponent:0.3];

    UIView *batteryView = items.battery.view;
    _level = batteryView ? DLIStatusBatteryLevel(batteryView) : 1;
    _fillColor = batteryView ? DLIStatusBatteryFillColor(batteryView, foregroundColor) : foregroundColor;
    _body = batteryView ? DLIStatusBatteryBody(batteryView, &_bodyCorner) : CGRectZero;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UIView *centerView = items.center.view;
    Class wifiClass = NSClassFromString(@"STUIStatusBarWifiSignalView");
    // Signal changes fade the glyph's bands; losing the connection draws its slash in.
    if (!centerView) {
        _hasGlyph = YES;
        [_glyph setBars:0 lost:YES color:foregroundColor dimAlpha:0.2 animated:_rendered];
    } else if (wifiClass && [centerView isKindOfClass:wifiClass]) {
        UIColor *on = nil, *off = nil;
        NSInteger active = 3;
        @try {
            on = [centerView valueForKey:@"activeColor"];
            off = [centerView valueForKey:@"inactiveColor"];
            active = [[centerView valueForKey:@"numberOfActiveBars"] integerValue];
        } @catch (__unused NSException *e) {
        }
        if (![on isKindOfClass:UIColor.class]) on = foregroundColor;
        CGFloat dim = 0.2, white = 0;
        if ([off isKindOfClass:UIColor.class]) [off getWhite:&white alpha:&dim];
        _hasGlyph = YES;
        [_glyph setBars:active lost:NO color:on dimAlpha:dim animated:_rendered];
    } else {
        _hasGlyph = NO; // airplane or network type: keep the system icon
    }
    _contentChanged = _rendered;
    [CATransaction commit];

    // Snapshots only show while the fold moves (and a center icon other than Wi-Fi at
    // rest); at rest they are retaken when the next transition starts.
    _snapshotsDirty = YES;
    if (snapshots) {
        [self takeSnapshots];
    } else if (!_hasGlyph && centerView) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _center.contents = (__bridge id)DLIStatusItemSnapshot(centerView, [self snapshotScale] * 1.15).CGImage;
        [CATransaction commit];
    }

    for (DLIStatusItem *item in items.items) {
        DLIStatusItemSetHidden(item.view, YES);
        [_hiddenViews addObject:item.view];
    }
}

- (void)hideSystemIcon:(UIView *)view {
    if (!view) return;
    DLIStatusItemSetHidden(view, YES);
    [_hiddenViews addObject:view];
}

- (CGFloat)snapshotScale {
    return (self.window.screen ?: UIScreen.mainScreen).scale;
}

- (void)takeSnapshotsIfNeeded {
    if (_snapshotsDirty) [self takeSnapshots];
}

- (void)takeSnapshots {
    DLIStatusItemSet *items = _items;
    CGFloat scale = [self snapshotScale];
    BOOL crossfade = UIAccessibilityIsReduceMotionEnabled();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // The center grows inside the ring, so it is taken a little above screen scale.
    UIImage *center = items.center.view ? DLIStatusItemSnapshot(items.center.view, scale * 1.15) : nil;
    UIImage *battery = items.battery.view ? DLIStatusItemSnapshot(items.battery.view, scale) : nil;
    _center.contents = (__bridge id)center.CGImage;
    _battery.contents = (__bridge id)battery.CGImage;
    while (_ghosts.count < items.items.count) {
        CALayer *ghost = DLIFoldLayer(@"dli.ghost");
        [self.layer insertSublayer:ghost atIndex:0];
        [_ghosts addObject:ghost];
    }
    for (NSUInteger i = 0; i < _ghosts.count; i++) {
        DLIStatusItem *item = i < items.items.count ? items.items[i] : nil;
        UIImage *image = nil;
        // Ghosts of ring members only show in the Reduce Motion crossfade.
        if (item.role == DLIStatusItemRoleOther) image = DLIStatusItemSnapshot(item.view, scale);
        else if (crossfade && item.role == DLIStatusItemRoleCenter) image = center;
        else if (crossfade && item.role == DLIStatusItemRoleBattery) image = battery;
        else if (crossfade && item.view) image = DLIStatusItemSnapshot(item.view, scale);
        _ghosts[i].contents = (__bridge id)image.CGImage;
        if (!image) _ghosts[i].hidden = YES;
    }
    [CATransaction commit];
    _snapshotsDirty = NO;
}

// A value that changed because the status bar's data did (signal strength, battery level
// or color) eases to its new value instead of jumping. Geometry the fold drives is set
// directly every frame and never goes through here while the fold moves.
static void DLIEaseChange(CALayer *layer, NSString *keyPath, id to) {
    CALayer *shown = layer.presentationLayer ?: layer;
    id from = [shown valueForKeyPath:keyPath];
    if (!from || !to || [from isEqual:to]) return;
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:keyPath];
    animation.fromValue = from;
    animation.toValue = to;
    animation.duration = 0.3;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [layer addAnimation:animation forKey:[@"dli." stringByAppendingString:keyPath]];
}

static void DLIApplySnapshot(CALayer *layer, DLIItemState live, DLISnapshotState state) {
    layer.hidden = state.alpha <= 0.001 || !layer.contents;
    if (layer.hidden) return;
    layer.bounds = (CGRect){CGPointZero, live.size};
    layer.position = state.position;
    layer.transform = CATransform3DMakeScale(state.scaleX, state.scaleY, 1);
    layer.opacity = state.alpha;
}

static void DLIApplyShape(CALayer *layer, DLIShapeState state, UIColor *color) {
    layer.hidden = state.alpha <= 0.001 || state.size.width <= 0 || state.size.height <= 0;
    if (layer.hidden) return;
    layer.bounds = (CGRect){CGPointZero, state.size};
    layer.position = state.position;
    layer.cornerRadius = state.cornerRadius;
    layer.backgroundColor = color.CGColor;
    layer.opacity = state.alpha;
}

// The arc layers share one full circle that starts at the bottom of the ring and runs
// clockwise; every arc the fold draws lies inside (90, 450) degrees, so strokeStart and
// strokeEnd can describe it without rebuilding the path each frame.
static CGFloat DLIArcFraction(CGFloat angle) {
    if (!isfinite(angle)) return 0;
    CGFloat a = angle;
    while (a < M_PI_2) a += 2 * M_PI;
    while (a >= M_PI_2 + 2 * M_PI) a -= 2 * M_PI;
    return (a - M_PI_2) / (2 * M_PI);
}

- (void)updateArcPathWithRing:(DLIRing)ring {
    if (fabs(ring.center.x - _pathCenter.x) < 0.01 && fabs(ring.center.y - _pathCenter.y) < 0.01
        && fabs(ring.radius - _pathRadius) < 0.01) return;
    _pathCenter = ring.center;
    _pathRadius = ring.radius;
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:ring.center radius:ring.radius startAngle:M_PI_2
                                                    endAngle:M_PI_2 + 2 * M_PI clockwise:YES];
    _track.path = path.CGPath;
    _fill.path = path.CGPath;
}

- (void)renderWithProgress:(DLIFoldProgress)progress crossfade:(BOOL)crossfade island:(CGRect)island
                  keepRing:(BOOL)keepRing moving:(BOOL)moving time:(CFTimeInterval)time {
    UIView *foreground = self.superview;
    DLIStatusItemSet *items = _items;
    if (!foreground || !items) return;
    // Without a sane island and width there is nothing to place the ring against.
    if (CGRectIsNull(island) || !isfinite(island.origin.x) || island.size.height < 1 || foreground.bounds.size.width < 1) return;

    DLIFoldInput input;
    memset(&input, 0, sizeof(input));
    if (!keepRing || !_hasRing) {
        CGRect cluster = CGRectNull;
        UIView *members[3] = {items.signal.view, items.center.view, items.battery.view};
        for (int i = 0; i < 3; i++) {
            if (members[i]) cluster = CGRectUnion(cluster, DLIStatusItemRestingFrame(members[i], foreground));
        }
        _ring = DLIFoldRingMake(island, cluster, DLIFoldBubbleMaxX(island), foreground.bounds.size.width);
        _hasRing = YES;
    }
    input.ring = _ring;
    if (items.signal.view && _barCount > 0) {
        input.barCount = _barCount;
        input.signal = DLIStatusItemLiveState(items.signal.view, foreground);
        memcpy(input.bars, _barShapes, sizeof(_barShapes));
        // The system shows and hides the bars instantly when the island's width changes;
        // the ring follows that within about a tenth of a second instead of jumping.
        CGFloat target = input.signal.alpha;
        if (!_hasSignalShown) {
            _signalShown = target;
            _hasSignalShown = YES;
        } else {
            CFTimeInterval dt = MIN(MAX(time - _lastRenderTime, 0), 0.1);
            _signalShown += (target - _signalShown) * (1 - exp(-dt / 0.12));
        }
        input.signal.alpha = _signalShown;
    }
    _lastRenderTime = time;
    DLIItemState centerState = {0};
    if (items.center.view) {
        input.hasCenter = YES;
        centerState = DLIStatusItemLiveState(items.center.view, foreground);
        input.center = centerState;
    } else {
        input.phantomCenter = YES;
    }
    // Sized against the island like the rest of the ring.
    CGFloat k = input.ring.scale;
    if (_hasGlyph) {
        static CGSize glyph;
        if (glyph.width <= 0) glyph = [DLIWifiGlyphLayer glyphSize];
        input.vectorSize = CGSizeMake(glyph.width * k, glyph.height * k);
    }
    DLIItemState batteryState = {0};
    if (items.battery.view) {
        input.hasBattery = YES;
        batteryState = DLIStatusItemLiveState(items.battery.view, foreground);
        input.battery = batteryState;
        input.batteryBody = _body;
        input.batteryBodyCornerRadius = _bodyCorner;
        input.batteryLevel = _level;
    }
    DLIFoldOutput out = DLIFoldEvaluate(&input, progress, crossfade);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSInteger i = 0; i < DLI_MAX_BARS; i++) {
        if (i >= out.dotCount) {
            _dots[i].hidden = YES;
            continue;
        }
        UIColor *color = (input.barCount > 0 && i < (NSInteger)_barColors.count) ? _barColors[i] : _inactiveColor;
        if (_contentChanged && !_dots[i].hidden) DLIEaseChange(_dots[i], @"backgroundColor", (__bridge id)color.CGColor);
        DLIApplyShape(_dots[i], out.dots[i], color);
    }
    DLIApplySnapshot(_center, centerState, out.center);
    _glyph.hidden = !_hasGlyph || out.vector.alpha <= 0.001;
    if (!_glyph.hidden) {
        _glyph.position = out.vector.position;
        _glyph.transform = CATransform3DMakeScale(out.vector.scaleX * k, out.vector.scaleY * k, 1);
        _glyph.opacity = out.vector.alpha;
    }
    DLIApplySnapshot(_battery, batteryState, out.battery);
    if (_contentChanged && !_capsule.hidden) {
        DLIEaseChange(_capsuleFill, @"backgroundColor", (__bridge id)_fillColor.CGColor);
        DLIEaseChange(_capsuleTrack, @"backgroundColor", (__bridge id)_trackColor.CGColor);
    }
    DLIApplyShape(_capsule, out.capsule, UIColor.clearColor);
    if (!_capsule.hidden) {
        CGSize size = out.capsule.size;
        CGFloat split = size.width * out.capsuleFillFraction;
        _capsuleFill.frame = CGRectMake(0, 0, split, size.height);
        _capsuleTrack.frame = CGRectMake(split, 0, size.width - split, size.height);
        _capsuleFill.backgroundColor = _fillColor.CGColor;
        _capsuleTrack.backgroundColor = _trackColor.CGColor;
    }

    _track.hidden = _fill.hidden = !out.arcVisible;
    if (out.arcVisible) {
        [self updateArcPathWithRing:input.ring];
        CGFloat start = DLIArcFraction(out.arcStart);
        CGFloat fillEnd = start + (out.arcFillEnd - out.arcStart) / (2 * M_PI);
        CGFloat end = start + (out.arcEnd - out.arcStart) / (2 * M_PI);
        _fill.lineWidth = _track.lineWidth = input.ring.lineWidth;
        if (_contentChanged && !_fill.hidden) {
            DLIEaseChange(_fill, @"strokeColor", (__bridge id)_fillColor.CGColor);
            DLIEaseChange(_track, @"strokeColor", (__bridge id)_trackColor.CGColor);
            if (!moving) {
                // The battery level slides along the ring.
                DLIEaseChange(_fill, @"strokeEnd", @(fillEnd));
                DLIEaseChange(_track, @"strokeStart", @(fillEnd));
            }
        }
        if (moving) {
            // A level ease still running would pin the boundary while the fold moves it.
            [_fill removeAnimationForKey:@"dli.strokeEnd"];
            [_track removeAnimationForKey:@"dli.strokeStart"];
        }
        _fill.strokeColor = _fillColor.CGColor;
        _track.strokeColor = _trackColor.CGColor;
        _fill.strokeStart = start;
        _fill.strokeEnd = fillEnd;
        _fill.hidden = fillEnd - start <= 0;
        _track.strokeStart = fillEnd;
        _track.strokeEnd = end;
        _track.hidden = end - fillEnd <= 0;
        _fill.opacity = _track.opacity = out.arcAlpha;
    }

    for (NSUInteger i = 0; i < _ghosts.count; i++) {
        CALayer *ghost = _ghosts[i];
        DLIStatusItem *item = i < items.items.count ? items.items[i] : nil;
        BOOL show = item.view && (item.role == DLIStatusItemRoleOther || out.crossfade);
        if (!show) {
            ghost.hidden = YES;
            continue;
        }
        DLIItemState live = DLIStatusItemLiveState(item.view, foreground);
        DLISnapshotState state = {live.position, live.scaleX * out.othersScale, live.scaleY * out.othersScale,
            live.alpha * out.othersAlpha};
        DLIApplySnapshot(ghost, live, state);
    }
    [CATransaction commit];
    _contentChanged = NO;
    _rendered = YES;
}

- (void)detach {
    for (UIView *view in _hiddenViews.allObjects) DLIStatusItemSetHidden(view, NO);
    [_hiddenViews removeAllObjects];
    _items = nil;
    _hasSignalShown = NO;
    // An idle view keeps its layers, not the icons' pictures.
    _center.contents = nil;
    _battery.contents = nil;
    for (CALayer *ghost in _ghosts) ghost.contents = nil;
    [self removeFromSuperview];
}

@end
