#import "DLIDebugDump.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <objc/message.h>
#import "DLIDebugCapture.h"

// Writes runtime facts about SpringBoard to a file the host can read over vphoned.
// Trigger with the Darwin notification below; class names to inspect are read
// from DLIDebugClassListPath, one per line.

static NSString *DLIDebugDumpPathForProcess(void) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return @"/var/mobile/Library/Caches/dli_dump.txt";
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"dli_dump.txt"];
}
static NSString *const DLIDebugClassListPath = @"/var/mobile/Library/Caches/dli_classes.txt";

@interface UIWindow (DLIPrivate)
+ (NSArray<UIWindow *> *)allWindowsIncludingInternalWindows:(BOOL)internal onlyVisibleWindows:(BOOL)visible;
@end

static void DLIAppendView(NSMutableString *out, UIView *view, NSUInteger depth, NSUInteger maxDepth) {
    NSMutableString *pad = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [pad appendString:@"  "];
    CGRect f = [view convertRect:view.bounds toView:nil];
    [out appendFormat:@"%@%@ %p win=(%.1f %.1f %.1f %.1f)%@ a=%.2f%@\n", pad, NSStringFromClass(view.class), view,
        f.origin.x, f.origin.y, f.size.width, f.size.height, view.hidden ? @" HIDDEN" : @"", view.alpha,
        view.layer.cornerRadius > 0 ? [NSString stringWithFormat:@" r=%.1f", view.layer.cornerRadius] : @""];
    if (depth >= maxDepth) return;
    for (UIView *sub in view.subviews) DLIAppendView(out, sub, depth + 1, maxDepth);
}

static void DLIAppendClass(NSMutableString *out, NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) { [out appendFormat:@"\n## %@ (missing)\n", name]; return; }
    [out appendFormat:@"\n## %@ : %@\n", name, NSStringFromClass(class_getSuperclass(cls))];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count; i++)
        [out appendFormat:@"  ivar %s %s\n", ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i])];
    free(ivars);
    objc_property_t *props = class_copyPropertyList(cls, &count);
    for (unsigned int i = 0; i < count; i++)
        [out appendFormat:@"  @property %s\n", property_getName(props[i])];
    free(props);
    Method *methods = class_copyMethodList(object_getClass(cls), &count);
    for (unsigned int i = 0; i < count; i++)
        [out appendFormat:@"  + %s\n", sel_getName(method_getName(methods[i]))];
    free(methods);
    methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++)
        [out appendFormat:@"  - %s %s\n", sel_getName(method_getName(methods[i])), method_getTypeEncoding(methods[i])];
    free(methods);
}

// Prints scalar ivars of a settings object and recurses into nested *Settings ivars.
static void DLIAppendSettings(NSMutableString *out, id object, NSString *prefix, NSUInteger depth) {
    if (!object || depth > 5) return;
    for (Class cls = [object class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        NSString *className = NSStringFromClass(cls);
        if ([className isEqualToString:@"PTSettings"]) break;
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            NSString *ivarName = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
            NSString *path = [prefix stringByAppendingFormat:@".%@", ivarName];
            if (type[0] == '@') {
                id child = object_getIvar(object, ivars[i]);
                NSString *childClass = child ? NSStringFromClass([child class]) : @"nil";
                if ([childClass rangeOfString:@"Settings"].location != NSNotFound) {
                    [out appendFormat:@"%@ <%@>\n", path, childClass];
                    DLIAppendSettings(out, child, path, depth + 1);
                } else if ([child isKindOfClass:NSNumber.class] || [child isKindOfClass:NSString.class]) {
                    [out appendFormat:@"%@ = %@\n", path, child];
                }
            } else if (type[0] == 'd' || type[0] == 'f' || type[0] == 'B' || type[0] == 'q' || type[0] == 'Q'
                       || type[0] == 'i' || type[0] == 'c') {
                @try {
                    [out appendFormat:@"%@ = %@\n", path, [object valueForKey:[ivarName substringFromIndex:1]]];
                } @catch (__unused NSException *e) {
                    ptrdiff_t offset = ivar_getOffset(ivars[i]);
                    if (type[0] == 'd') [out appendFormat:@"%@ = %g\n", path, *(double *)((uint8_t *)(__bridge void *)object + offset)];
                }
            }
        }
        free(ivars);
    }
}

// The VM has no baseband or Wi-Fi, so tests draw the real system cellular and Wi-Fi
// items by giving every status bar overlay data. Debug builds only.
static NSArray<NSString *> *DLIDebugRadioOverlay = nil;
static char DLIDebugOverlayMarker;

static id DLIDebugEntry(NSString *className, NSDictionary<NSString *, id> *ivars) {
    id entry = [NSClassFromString(className) new];
    [entry setValue:@YES forKey:@"_enabled"];
    [ivars enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        [entry setValue:value forKey:key];
    }];
    return entry;
}

static void DLIDebugApplyRadioOverlay(UIView *statusBar) {
    if (!DLIDebugRadioOverlay) {
        [statusBar setValue:nil forKey:@"overlayData"];
        return;
    }
    // cellBars, wifiBars, cellStatus, cellType, wifiStatus, cellString, time
    NSArray<NSString *> *v = DLIDebugRadioOverlay;
    id data = [NSClassFromString(@"STMutableStatusBarData") new];
    long long cellBars = v[0].longLongValue, wifiBars = v[1].longLongValue;
    [data setValue:DLIDebugEntry(@"STStatusBarDataCellularEntry", @{
        @"_rawValue": @(cellBars), @"_displayValue": @(cellBars), @"_status": @(v[2].longLongValue),
        @"_type": @(v[3].longLongValue), @"_string": v[5]
    }) forKey:@"cellularEntry"];
    if (wifiBars == -2) {
        // Wi-Fi explicitly off.
        id wifi = DLIDebugEntry(@"STStatusBarDataWifiEntry", @{@"_status": @1});
        [wifi setValue:@NO forKey:@"_enabled"];
        [data setValue:wifi forKey:@"wifiEntry"];
    } else if (wifiBars >= 0) {
        [data setValue:DLIDebugEntry(@"STStatusBarDataWifiEntry", @{
            @"_rawValue": @(wifiBars), @"_displayValue": @(wifiBars), @"_status": @(v[4].longLongValue), @"_type": @0
        }) forKey:@"wifiEntry"];
    }
    if (v.count > 9) {
        // batteryPercent, batteryState (0 draining 1 charging 2 charged), saver
        [data setValue:DLIDebugEntry(@"STStatusBarDataBatteryEntry", @{
            @"_capacity": @(v[7].longLongValue), @"_state": @(v[8].longLongValue), @"_saverModeActive": @(v[9].boolValue),
            @"_detailString": [v[7] stringByAppendingString:@"%"]
        }) forKey:@"mainBatteryEntry"];
    }
    if (v.count > 6 && v[6].length) {
        [data setValue:DLIDebugEntry(@"STStatusBarDataStringEntry", @{@"_stringValue": v[6]}) forKey:@"timeEntry"];
        [data setValue:DLIDebugEntry(@"STStatusBarDataStringEntry", @{@"_stringValue": v[6]}) forKey:@"shortTimeEntry"];
    }
    objc_setAssociatedObject(data, &DLIDebugOverlayMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [statusBar setValue:data forKey:@"overlayData"];
}


void DLIDebugApplyRadioOverlayIfNeeded(UIView *statusBar) {
    if (DLIDebugRadioOverlay) DLIDebugApplyRadioOverlay(statusBar);
}

BOOL DLIDebugIsRadioOverlayActive(void) {
    return DLIDebugRadioOverlay != nil;
}

BOOL DLIDebugIsRadioOverlay(id data) {
    return data && objc_getAssociatedObject(data, &DLIDebugOverlayMarker) != nil;
}

static void DLIDebugForEachStatusBar(NSArray<UIWindow *> *windows, void (^block)(UIView *)) {
    Class cls = NSClassFromString(@"STUIStatusBar");
    __block void (^walk)(UIView *) = nil;
    void (^visit)(UIView *) = ^(UIView *v) {
        if ([v isKindOfClass:cls]) block(v);
        for (UIView *sub in v.subviews) walk(sub);
    };
    walk = visit;
    for (UIWindow *window in windows) visit(window);
    walk = nil;
}

void DLIDebugDumpNow(void) {
    NSMutableString *out = [NSMutableString string];
    NSArray<UIWindow *> *windows = [UIWindow allWindowsIncludingInternalWindows:YES onlyVisibleWindows:NO];
    for (UIWindow *window in windows) {
        [out appendFormat:@"\n# WINDOW %@ %p level=%.1f hidden=%d frame=%@\n", NSStringFromClass(window.class), window,
            window.windowLevel, window.hidden, NSStringFromCGRect(window.frame)];
        NSString *name = NSStringFromClass(window.class);
        BOOL interesting = ![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]
            || [name rangeOfString:@"Aperture"].location != NSNotFound
            || [name rangeOfString:@"StatusBar"].location != NSNotFound
            || [name rangeOfString:@"DLI"].location != NSNotFound;
        if (interesting && !window.hidden) DLIAppendView(out, window, 1, 40);
    }
    NSString *list = [NSString stringWithContentsOfFile:DLIDebugClassListPath encoding:NSUTF8StringEncoding error:nil];
    if (!list) list = @"?StatusBar\n%UIStatusBar_Modern:statusBar\n%STUIStatusBar:currentAggregatedData\n";
    for (NSString *line in [list componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *name = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([name hasPrefix:@"!"]) {
            // "!Class:selector" sends a no-argument selector to a kept instance of Class (test recipes).
            static NSMutableDictionary<NSString *, id> *instances;
            if (!instances) instances = [NSMutableDictionary dictionary];
            NSArray<NSString *> *parts = [[name substringFromIndex:1] componentsSeparatedByString:@":"];
            id instance = instances[parts.firstObject];
            if (!instance) {
                instance = [NSClassFromString(parts.firstObject) new];
                if (instance) instances[parts.firstObject] = instance;
            }
            SEL selector = NSSelectorFromString(parts.lastObject);
            if ([instance respondsToSelector:selector]) {
                ((void (*)(id, SEL))objc_msgSend)(instance, selector);
                [out appendFormat:@"\n## %@ sent to %@\n", name, instance];
            } else {
                [out appendFormat:@"\n## %@ failed (%@)\n", name, instance];
            }
        } else if ([name hasPrefix:@"%"]) {
            // "%ViewClass:key.path" evaluates a key path on the first view of that class in any window.
            NSArray<NSString *> *parts = [[name substringFromIndex:1] componentsSeparatedByString:@":"];
            Class cls = NSClassFromString(parts.firstObject);
            __block UIView *found = nil;
            __block void (^walk)(UIView *) = nil;
            void (^visit)(UIView *) = ^(UIView *v) {
                if (found) return;
                if (cls && [v isKindOfClass:cls]) { found = v; return; }
                for (UIView *sub in v.subviews) walk(sub);
            };
            walk = visit;
            for (UIWindow *window in windows) visit(window);
            walk = nil;
            id value = nil;
            @try {
                value = parts.count > 1 ? [found valueForKeyPath:parts[1]] : found;
            } @catch (NSException *e) {
                value = [NSString stringWithFormat:@"<exception %@>", e.reason];
            }
            [out appendFormat:@"\n## %@\n%@\n", name, value];
        } else if ([name hasPrefix:@"="]) {
            // "=Class:key.path" prints the description of a key path evaluated on the class object.
            NSArray<NSString *> *parts = [[name substringFromIndex:1] componentsSeparatedByString:@":"];
            Class cls = NSClassFromString(parts.firstObject);
            id value = nil;
            @try {
                value = parts.count > 1 ? [(id)cls valueForKeyPath:parts[1]] : cls;
            } @catch (NSException *e) {
                value = [NSString stringWithFormat:@"<exception %@>", e.reason];
            }
            [out appendFormat:@"\n## %@\n%@\n", name, value];
        } else if ([name hasPrefix:@"&"]) {
            // "&Class:key.path" dumps a settings object tree reached from the class object.
            NSArray<NSString *> *parts = [[name substringFromIndex:1] componentsSeparatedByString:@":"];
            id value = nil;
            @try {
                value = [(id)NSClassFromString(parts.firstObject) valueForKeyPath:parts[1]];
            } @catch (__unused NSException *e) {
            }
            [out appendFormat:@"\n## %@ <%@>\n", name, value ? NSStringFromClass([value class]) : @"nil"];
            DLIAppendSettings(out, value, @"", 0);
        } else if ([name hasPrefix:@"^radios:"]) {
            // "^radios:cellBars,wifiBars,cellStatus,cellType,wifiStatus,cellString[,time]" or "^radios:off"
            NSString *args = [name substringFromIndex:8];
            DLIDebugRadioOverlay = [args isEqualToString:@"off"] ? nil : [args componentsSeparatedByString:@","];
            __block NSUInteger count = 0;
            DLIDebugForEachStatusBar(windows, ^(UIView *bar) {
                @try {
                    DLIDebugApplyRadioOverlay(bar);
                } @catch (NSException *e) {
                    [out appendFormat:@"overlay exception %@\n", e.reason];
                }
                count++;
            });
            [out appendFormat:@"\n## %@ applied to %lu status bars\n", name, (unsigned long)count];
        } else if ([name hasPrefix:@"^seq:"]) {
            // "^seq:inc@0,dec@0.15,inc@0.4" drives the test recipe on SpringBoard's own clock,
            // so interruption tests hit exact moments.
            static id recipe;
            if (!recipe) recipe = [NSClassFromString(@"SBSystemApertureTestRecipe") new];
            for (NSString *step in [[name substringFromIndex:5] componentsSeparatedByString:@","]) {
                NSArray<NSString *> *parts = [step componentsSeparatedByString:@"@"];
                SEL selector = [parts[0] isEqualToString:@"inc"] ? NSSelectorFromString(@"handleVolumeIncrease")
                                                                  : NSSelectorFromString(@"handleVolumeDecrease");
                double delay = parts.count > 1 ? parts[1].doubleValue : 0;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ((void (*)(id, SEL))objc_msgSend)(recipe, selector);
                });
            }
            [out appendFormat:@"\n## %@ scheduled\n", name];
        } else if ([name hasPrefix:@"^snap:"]) {
            // "^snap:ViewClass" renders the first visible view of that class at 10x into dli_snap.png.
            Class cls = NSClassFromString([name substringFromIndex:6]);
            __block UIView *found = nil;
            __block void (^walk)(UIView *) = nil;
            void (^visit)(UIView *) = ^(UIView *v) {
                if (found) return;
                if (cls && [v isKindOfClass:cls] && v.window && !v.window.hidden) { found = v; return; }
                for (UIView *sub in v.subviews) walk(sub);
            };
            walk = visit;
            for (UIWindow *window in windows) visit(window);
            walk = nil;
            if (found) {
                CALayer *mask = found.layer.mask;
                found.layer.mask = nil;
                UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
                format.scale = 10;
                format.opaque = NO;
                UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:found.bounds.size format:format]
                    imageWithActions:^(UIGraphicsImageRendererContext *context) {
                        [found.layer renderInContext:context.CGContext];
                    }];
                found.layer.mask = mask;
                [UIImagePNGRepresentation(image) writeToFile:@"/var/mobile/Library/Caches/dli_snap.png" atomically:YES];
            }
            [out appendFormat:@"\n## %@ %@\n", name, found ? NSStringFromCGRect(found.bounds) : @"not found"];
        } else if ([name isEqualToString:@"^bars"]) {
            // Every status bar with the facts the fold uses to decide whether to fold it.
            DLIDebugForEachStatusBar(windows, ^(UIView *bar) {
                id provider = nil, mode = nil, orientation = nil;
                @try {
                    provider = [bar valueForKey:@"visualProvider"];
                    mode = [bar valueForKey:@"mode"];
                    orientation = [bar valueForKey:@"orientation"];
                } @catch (__unused NSException *e) {
                }
                [out appendFormat:@"bar %p win=%@ screen=%@ provider=%@ mode=%@ orientation=%@ hiddenWin=%d\n", bar,
                    NSStringFromClass(bar.window.class), NSStringFromCGRect([bar convertRect:bar.bounds toView:nil]),
                    NSStringFromClass([provider class]), mode, orientation, bar.window.hidden];
            });
        } else if ([name hasPrefix:@"^slow:"]) {
            // "^slow:4" stretches the fold timeline four times (1 = design speed).
            id controller = [NSClassFromString(@"DLIFoldController") valueForKey:@"sharedController"];
            [[controller valueForKey:@"timeline"] setValue:@([[name substringFromIndex:6] doubleValue]) forKey:@"timeScale"];
            [out appendFormat:@"\n## %@ ok\n", name];
        } else if ([name hasPrefix:@"^capture:"]) {
            // "^capture:start:<points>:<fps>" (0 points = full screen) or "^capture:stop"
            NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
            if ([parts[1] isEqualToString:@"stop"]) {
                [out appendFormat:@"\n## capture %@\n", DLIDebugCaptureStop()];
            } else {
                DLIDebugCaptureStart(parts.count > 2 ? parts[2].doubleValue : 0, parts.count > 3 ? parts[3].doubleValue : 60);
                [out appendString:@"\n## capture started\n"];
            }
        } else if ([name hasPrefix:@"^state"]) {
            // The tweak is a separate image; reach its controller through the runtime.
            id c = [NSClassFromString(@"DLIFoldController") valueForKey:@"sharedController"];
            id timeline = [c valueForKey:@"timeline"];
            id observer = [c valueForKey:@"observer"];
            BOOL animating = timeline ? ((BOOL (*)(id, SEL, CFTimeInterval))objc_msgSend)(timeline,
                NSSelectorFromString(@"isAnimatingAtTime:"), CACurrentMediaTime()) : NO;
            id link = [NSClassFromString(@"DLIDisplayLink") valueForKey:@"sharedLink"];
            [out appendFormat:@"\n## state phase=%@ folded=%@ island=%@ primary=%@ animating=%d link=%@ reduceMotion=%d lowPower=%d\n",
                [observer valueForKey:@"phase"], [timeline valueForKey:@"folded"], [observer valueForKey:@"islandFrame"],
                [observer valueForKey:@"primaryFrame"], animating, [link valueForKey:@"running"],
                UIAccessibilityIsReduceMotionEnabled(), NSProcessInfo.processInfo.isLowPowerModeEnabled];
        } else if ([name isEqualToString:@"^enums"]) {
            for (long long i = 0; i < 8; i++) {
                id cell = DLIDebugEntry(@"STStatusBarDataCellularEntry", @{@"_status": @(i), @"_type": @(i)});
                id wifi = DLIDebugEntry(@"STStatusBarDataWifiEntry", @{@"_status": @(i), @"_type": @(i)});
                id battery = DLIDebugEntry(@"STStatusBarDataBatteryEntry", @{@"_state": @(i)});
                [out appendFormat:@"%lld cell=%@\n  wifi=%@\n  battery=%@\n", i, cell, wifi, battery];
            }
            for (long long i = 8; i < 20; i++)
                [out appendFormat:@"%lld cell=%@\n", i, DLIDebugEntry(@"STStatusBarDataCellularEntry", @{@"_type": @(i)})];
        } else if ([name hasPrefix:@"$"]) {
            // "$ViewClass" prints the layer tree of the first view of that class.
            Class cls = NSClassFromString([name substringFromIndex:1]);
            __block UIView *found = nil;
            __block void (^walk)(UIView *) = nil;
            void (^visit)(UIView *) = ^(UIView *v) {
                if (found) return;
                if (cls && [v isKindOfClass:cls] && !v.hidden && v.window) { found = v; return; }
                for (UIView *sub in v.subviews) walk(sub);
            };
            walk = visit;
            for (UIWindow *window in windows) visit(window);
            walk = nil;
            [out appendFormat:@"\n## layers of %@ %p bounds=%@\n", [name substringFromIndex:1], found,
                NSStringFromCGRect(found.bounds)];
            __block void (^dumpLayer)(CALayer *, NSUInteger) = nil;
            void (^dumpOne)(CALayer *, NSUInteger) = ^(CALayer *l, NSUInteger depth) {
                NSMutableString *pad = [NSMutableString string];
                for (NSUInteger i = 0; i < depth; i++) [pad appendString:@"  "];
                NSString *extra = @"";
                if ([l isKindOfClass:CAShapeLayer.class]) {
                    CAShapeLayer *s = (CAShapeLayer *)l;
                    extra = [NSString stringWithFormat:@" shape fill=%@ stroke=%@ lw=%.2f path=%@", s.fillColor, s.strokeColor,
                        s.lineWidth, NSStringFromCGRect(CGPathGetBoundingBox(s.path))];
                }
                [out appendFormat:@"%@%@ %@ frame=%@ r=%.2f bg=%@ a=%.2f hidden=%d contents=%@ mask=%@ name=%@ filters=%@ compositing=%@%@\n", pad,
                    NSStringFromClass(l.class), l.delegate ? NSStringFromClass([l.delegate class]) : @"", NSStringFromCGRect(l.frame),
                    l.cornerRadius, l.backgroundColor ? [UIColor colorWithCGColor:l.backgroundColor] : nil, l.opacity, l.hidden,
                    l.contents ? @"yes" : @"no", l.mask, l.name, l.filters, l.compositingFilter, extra];
                for (CALayer *sub in l.sublayers) dumpLayer(sub, depth + 1);
            };
            dumpLayer = dumpOne;
            if (found) dumpOne(found.layer, 1);
            dumpLayer = nil;
        } else if ([name hasPrefix:@"#"]) {
            // "#ViewClass" lists every instance of a view class with its window and ancestor chain.
            Class cls = NSClassFromString([name substringFromIndex:1]);
            [out appendFormat:@"\n## instances of %@\n", [name substringFromIndex:1]];
            __block void (^walk)(UIView *) = nil;
            void (^visit)(UIView *) = ^(UIView *v) {
                if (cls && [v isKindOfClass:cls]) {
                    NSMutableString *chain = [NSMutableString string];
                    BOOL visible = YES;
                    for (UIView *a = v; a; a = a.superview) {
                        if (a.hidden || a.alpha < 0.01) visible = NO;
                        [chain appendFormat:@"%@(a%.2f%@) < ", NSStringFromClass(a.class), a.alpha, a.hidden ? @" H" : @""];
                    }
                    [out appendFormat:@"  %p visible=%d frame=%@ win=%@\n    %@\n", v, visible,
                        NSStringFromCGRect([v convertRect:v.bounds toView:nil]), NSStringFromClass(v.window.class), chain];
                }
                for (UIView *sub in v.subviews) walk(sub);
            };
            walk = visit;
            for (UIWindow *window in windows) visit(window);
            walk = nil;
        } else if ([name hasPrefix:@"?"]) {
            // "?Pattern" lists every loaded class whose name contains Pattern.
            NSString *pattern = [name substringFromIndex:1];
            unsigned int count = 0;
            Class *classes = objc_copyClassList(&count);
            [out appendFormat:@"\n## classes matching %@\n", pattern];
            for (unsigned int i = 0; i < count; i++) {
                NSString *cn = NSStringFromClass(classes[i]);
                if ([cn rangeOfString:pattern].location != NSNotFound) [out appendFormat:@"  %@\n", cn];
            }
            free(classes);
        } else if (name.length) {
            DLIAppendClass(out, name);
        }
    }
    [out writeToFile:DLIDebugDumpPathForProcess() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void DLIDebugDumpInstall(void) {
    int token = 0;
    notify_register_dispatch("app.yellowplus.dli.dump", &token, dispatch_get_main_queue(), ^(int t) {
        DLIDebugDumpNow();
    });
}

