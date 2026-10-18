#import "DLIStatusItems.h"
#import <objc/runtime.h>

static id DLIValue(id object, NSString *key) {
    if (!object) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

@interface DLIStatusItem ()
@property (nonatomic, weak, readwrite) UIView *view;
@property (nonatomic, readwrite) DLIStatusItemRole role;
@property (nonatomic, copy, readwrite) NSString *identifier;
@end

@implementation DLIStatusItem
@end

@interface DLIStatusItemSet ()
@property (nonatomic, copy, readwrite) NSArray<DLIStatusItem *> *items;
@property (nonatomic, strong, readwrite) DLIStatusItem *signal;
@property (nonatomic, strong, readwrite) DLIStatusItem *center;
@property (nonatomic, strong, readwrite) DLIStatusItem *battery;
@property (nonatomic, copy, readwrite) NSArray<DLIStatusItem *> *others;
@end

@implementation DLIStatusItemSet

static NSArray *DLITrailingDisplayItems(UIView *statusBar) {
    NSDictionary *regions = DLIValue(statusBar, @"regions");
    if (![regions isKindOfClass:NSDictionary.class]) return @[];
    id displayItems = DLIValue(regions[@"trailing"], @"displayItems");
    if ([displayItems isKindOfClass:NSOrderedSet.class]) return [displayItems array];
    if ([displayItems isKindOfClass:NSSet.class]) return [displayItems allObjects];
    if ([displayItems isKindOfClass:NSArray.class]) return displayItems;
    return @[];
}

// Lower is preferred for the ring's center.
static NSInteger DLICenterRank(UIView *view, NSString *identifier) {
    static Class wifi;
    if (!wifi) wifi = NSClassFromString(@"STUIStatusBarWifiSignalView");
    if (wifi && [view isKindOfClass:wifi]) return 0;
    if ([identifier rangeOfString:@"Airplane"].location != NSNotFound) return 1;
    if ([identifier rangeOfString:@"Cellular"].location != NSNotFound
        && [identifier rangeOfString:@"type" options:NSCaseInsensitiveSearch].location != NSNotFound) return 2;
    return NSNotFound;
}

+ (instancetype)itemsOfStatusBar:(UIView *)statusBar {
    DLIStatusItemSet *set = [DLIStatusItemSet new];
    NSMutableArray<DLIStatusItem *> *items = [NSMutableArray array];
    NSMutableArray<DLIStatusItem *> *others = [NSMutableArray array];
    static Class signalClass, batteryClass;
    if (!signalClass) signalClass = NSClassFromString(@"STUIStatusBarCellularSignalView");
    if (!batteryClass) batteryClass = NSClassFromString(@"_UIBatteryView");
    DLIStatusItem *center = nil;
    NSInteger centerRank = NSNotFound;
    for (id displayItem in DLITrailingDisplayItems(statusBar)) {
        UIView *view = DLIValue(displayItem, @"view");
        if (![view isKindOfClass:UIView.class] || !view.superview) continue;
        if (![DLIValue(displayItem, @"enabled") boolValue]) continue;
        DLIStatusItem *item = [DLIStatusItem new];
        item.view = view;
        item.identifier = [DLIValue(displayItem, @"identifier") description] ?: NSStringFromClass(view.class);
        [items addObject:item];
        NSInteger rank = DLICenterRank(view, item.identifier);
        if (signalClass && [view isKindOfClass:signalClass] && !set.signal) {
            item.role = DLIStatusItemRoleSignal;
            set.signal = item;
        } else if (batteryClass && [view isKindOfClass:batteryClass] && !set.battery) {
            item.role = DLIStatusItemRoleBattery;
            set.battery = item;
        } else if (rank != NSNotFound && (centerRank == NSNotFound || rank < centerRank)) {
            if (center) {
                center.role = DLIStatusItemRoleOther;
                [others addObject:center];
            }
            item.role = DLIStatusItemRoleCenter;
            center = item;
            centerRank = rank;
        } else {
            item.role = DLIStatusItemRoleOther;
            [others addObject:item];
        }
    }
    set.center = center;
    set.items = items;
    set.others = others;
    return set;
}

- (BOOL)isEquivalentToSet:(DLIStatusItemSet *)other {
    if (!other || other.items.count != self.items.count) return NO;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        DLIStatusItem *a = self.items[i], *b = other.items[i];
        if (a.view != b.view || a.role != b.role) return NO;
    }
    return YES;
}

@end

DLIItemState DLIStatusItemLiveState(UIView *view, UIView *space) {
    DLIItemState state;
    CALayer *model = view.layer;
    CALayer *layer = model.presentationLayer ?: model;
    CGSize size = layer.bounds.size;
    CATransform3D t = layer.transform;
    CGFloat sx = hypot(t.m11, t.m12), sy = hypot(t.m21, t.m22);
    // Status bar icons pop in from twice their size when the system re-adds them; the
    // copies follow the icon's place and fade, not that flourish.
    sx = MIN(MAX(sx, 0.3), 1.0);
    sy = MIN(MAX(sy, 0.3), 1.0);
    // position is the anchor point in the parent's coordinates; move it to the center.
    CGPoint center = layer.position;
    center.x += (0.5 - layer.anchorPoint.x) * size.width * sx;
    center.y += (0.5 - layer.anchorPoint.y) * size.height * sy;
    UIView *parent = view.superview;
    if (parent && space && parent != space) center = [parent convertPoint:center toView:space];
    state.position = center;
    state.size = size;
    state.scaleX = sx;
    state.scaleY = sy;
    state.alpha = (view.hidden || layer.hidden) ? 0 : layer.opacity;
    return state;
}

CGRect DLIStatusItemRestingFrame(UIView *view, UIView *space) {
    CGSize size = view.bounds.size;
    CGPoint center = view.center;
    UIView *parent = view.superview;
    if (parent && space && parent != space) center = [parent convertPoint:center toView:space];
    return CGRectMake(center.x - size.width / 2, center.y - size.height / 2, size.width, size.height);
}

static char DLIStatusItemMaskKey;

BOOL DLIStatusItemIsHidden(UIView *view) {
    CALayer *mask = objc_getAssociatedObject(view, &DLIStatusItemMaskKey);
    return mask && view.layer.mask == mask;
}

void DLIStatusItemSetHidden(UIView *view, BOOL hidden) {
    if (!view) return;
    CALayer *layer = view.layer;
    CALayer *ours = objc_getAssociatedObject(view, &DLIStatusItemMaskKey);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (hidden) {
        if (!(ours && layer.mask == ours) && !layer.mask) {
            CALayer *mask = [CALayer layer];
            mask.name = @"dli.mask";
            mask.frame = CGRectZero;
            objc_setAssociatedObject(view, &DLIStatusItemMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            layer.mask = mask;
        }
    } else {
        if (ours && layer.mask == ours) layer.mask = nil;
        objc_setAssociatedObject(view, &DLIStatusItemMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction commit];
}

UIImage *DLIStatusItemSnapshot(UIView *view, CGFloat scale) {
    CALayer *layer = view.layer;
    CGSize size = layer.bounds.size;
    if (size.width < 0.5 || size.height < 0.5) return nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALayer *mask = layer.mask;
    BOOL ours = DLIStatusItemIsHidden(view);
    if (ours) layer.mask = nil;
    float opacity = layer.opacity;
    layer.opacity = 1;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    format.opaque = NO;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard; // icons need no extended range
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextTranslateCTM(context.CGContext, -layer.bounds.origin.x, -layer.bounds.origin.y);
        [layer renderInContext:context.CGContext];
    }];
    layer.opacity = opacity;
    if (ours) layer.mask = mask;
    [CATransaction commit];
    return image;
}

UIView *DLIStatusBarForegroundView(UIView *statusBar) {
    UIView *view = DLIValue(statusBar, @"foregroundView");
    return [view isKindOfClass:UIView.class] ? view : nil;
}

BOOL DLIStatusBarIsPortrait(UIView *statusBar) {
    NSInteger orientation = [DLIValue(statusBar, @"orientation") integerValue];
    return orientation == 0 || orientation == UIInterfaceOrientationPortrait;
}

NSInteger DLIStatusBarMode(UIView *statusBar) {
    return [DLIValue(statusBar, @"mode") integerValue];
}

UIColor *DLIStatusBarForegroundColor(UIView *statusBar) {
    id attributes = DLIValue(statusBar, @"styleAttributes");
    for (NSString *key in @[ @"textColor", @"imageTintColor" ]) {
        UIColor *color = DLIValue(attributes, key);
        if ([color isKindOfClass:UIColor.class]) return color;
    }
    UIColor *color = DLIValue(statusBar, @"foregroundColor");
    if ([color isKindOfClass:UIColor.class]) return color;
    return [DLIValue(statusBar, @"style") integerValue] == 1 ? UIColor.whiteColor : UIColor.blackColor;
}

NSInteger DLIStatusSignalBars(UIView *signalView, DLIBarShape *shapes, CGColorRef *colors, NSInteger max) {
    NSMutableArray<CALayer *> *bars = [NSMutableArray array];
    for (CALayer *bar in signalView.layer.sublayers) {
        if (bar.hidden || bar.bounds.size.width <= 0 || bar.bounds.size.height <= 0) continue;
        [bars addObject:bar];
    }
    [bars sortUsingComparator:^NSComparisonResult(CALayer *a, CALayer *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending
            : (a.frame.origin.x > b.frame.origin.x ? NSOrderedDescending : NSOrderedSame);
    }];
    NSInteger n = 0;
    for (CALayer *bar in bars) {
        if (n >= max) break;
        shapes[n].frame = bar.frame;
        shapes[n].cornerRadius = bar.cornerRadius;
        colors[n] = bar.backgroundColor;
        n++;
    }
    return n;
}

CGFloat DLIStatusBatteryLevel(UIView *batteryView) {
    id value = DLIValue(batteryView, @"chargePercent");
    return value ? [value doubleValue] : 1;
}

UIColor *DLIStatusBatteryFillColor(UIView *batteryView, UIColor *fallback) {
    SEL selector = NSSelectorFromString(@"_batteryFillColor");
    if ([batteryView respondsToSelector:selector]) {
        UIColor *color = ((UIColor * (*)(id, SEL))[batteryView methodForSelector:selector])(batteryView, selector);
        if ([color isKindOfClass:UIColor.class]) return color;
    }
    UIColor *color = DLIValue(batteryView, @"fillColor");
    return [color isKindOfClass:UIColor.class] ? color : fallback;
}

CGRect DLIStatusBatteryBody(UIView *batteryView, CGFloat *cornerRadius) {
    CGRect body = batteryView.bounds;
    CALayer *fill = DLIValue(batteryView, @"fillLayer");
    if ([fill isKindOfClass:CALayer.class] && fill.superlayer) {
        // The fill sits inside the body with equal insets on every side.
        CGRect f = [fill.superlayer convertRect:fill.frame toLayer:batteryView.layer];
        body = CGRectMake(0, 0, CGRectGetMaxX(f) + f.origin.x, CGRectGetMaxY(f) + f.origin.y);
    } else {
        CALayer *pin = DLIValue(batteryView, @"pinLayer");
        if ([pin isKindOfClass:CALayer.class] && pin.frame.origin.x > 0) body.size.width = pin.frame.origin.x;
    }
    if (cornerRadius) *cornerRadius = body.size.height * 0.3;
    return body;
}
