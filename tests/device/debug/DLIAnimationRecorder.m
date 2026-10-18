#import "DLIAnimationRecorder.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>

// Records every CAAnimation the system adds to layers of the System Aperture and
// status bar windows while recording is on, so animation curves come from the
// system rather than from guesses. Toggle with app.yellowplus.dli.record.start / .stop;
// the log lands in DLIAnimationRecorderPath.

static NSString *const DLIAnimationRecorderPath = @"/var/mobile/Library/Caches/dli_animations.txt";
static BOOL DLIAnimationRecorderActive = NO;
static NSMutableString *DLIAnimationRecorderLog = nil;
static CFTimeInterval DLIAnimationRecorderStart = 0;
static IMP DLIAnimationRecorderOriginalAdd = NULL;

static NSString *DLIAnimationRecorderOwnerPath(CALayer *layer) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    CALayer *cursor = layer;
    NSUInteger depth = 0;
    while (cursor && depth < 6) {
        id delegate = cursor.delegate;
        NSString *name = delegate ? NSStringFromClass([delegate class]) : NSStringFromClass(cursor.class);
        [names insertObject:name atIndex:0];
        cursor = cursor.superlayer;
        depth++;
    }
    return [names componentsJoinedByString:@">"];
}

static BOOL DLIAnimationRecorderIsInteresting(CALayer *layer) {
    CALayer *cursor = layer;
    while (cursor) {
        id delegate = cursor.delegate;
        if ([delegate isKindOfClass:UIWindow.class]) {
            NSString *name = NSStringFromClass([delegate class]);
            return [name rangeOfString:@"Aperture"].location != NSNotFound
                || [name rangeOfString:@"StatusBar"].location != NSNotFound;
        }
        cursor = cursor.superlayer;
    }
    return NO;
}

static NSString *DLIAnimationRecorderDescribe(CAAnimation *animation) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@", NSStringFromClass(animation.class)];
    if ([animation isKindOfClass:CAPropertyAnimation.class]) {
        [s appendFormat:@" keyPath=%@ additive=%d", ((CAPropertyAnimation *)animation).keyPath,
            ((CAPropertyAnimation *)animation).additive];
    }
    [s appendFormat:@" duration=%.4f beginTime=%.4f speed=%.3f fill=%@", animation.duration, animation.beginTime,
        animation.speed, animation.fillMode];
    if (animation.timingFunction) {
        float c[4] = {0};
        [animation.timingFunction getControlPointAtIndex:1 values:&c[0]];
        [animation.timingFunction getControlPointAtIndex:2 values:&c[2]];
        [s appendFormat:@" timing=(%.3f,%.3f,%.3f,%.3f)", c[0], c[1], c[2], c[3]];
    }
    if ([animation isKindOfClass:CASpringAnimation.class]) {
        CASpringAnimation *spring = (CASpringAnimation *)animation;
        [s appendFormat:@" mass=%.4f stiffness=%.4f damping=%.4f initialVelocity=%.4f settling=%.4f",
            spring.mass, spring.stiffness, spring.damping, spring.initialVelocity, spring.settlingDuration];
    }
    if ([animation isKindOfClass:CABasicAnimation.class]) {
        CABasicAnimation *basic = (CABasicAnimation *)animation;
        [s appendFormat:@" from=%@ to=%@ by=%@", basic.fromValue, basic.toValue, basic.byValue];
    }
    if ([animation isKindOfClass:CAKeyframeAnimation.class]) {
        CAKeyframeAnimation *keyframe = (CAKeyframeAnimation *)animation;
        [s appendFormat:@" values=%@ keyTimes=%@", keyframe.values, keyframe.keyTimes];
    }
    // Private high-frame-rate and preferred-rate hints, when present.
    for (NSString *key in @[ @"highFrameRateReason", @"preferredFrameRateRange", @"frameInterval" ]) {
        @try {
            id value = [animation valueForKey:key];
            if (value) [s appendFormat:@" %@=%@", key, value];
        } @catch (__unused NSException *e) {
        }
    }
    if ([animation isKindOfClass:CAAnimationGroup.class]) {
        for (CAAnimation *child in ((CAAnimationGroup *)animation).animations)
            [s appendFormat:@"\n      child: %@", DLIAnimationRecorderDescribe(child)];
    }
    return s;
}

static void DLIAnimationRecorderAdd(CALayer *self, SEL _cmd, CAAnimation *animation, NSString *key) {
    if (DLIAnimationRecorderActive && animation && DLIAnimationRecorderIsInteresting(self)) {
        [DLIAnimationRecorderLog appendFormat:@"t=%.4f layer=%@ %p key=%@ frame=%@\n    %@\n",
            CACurrentMediaTime() - DLIAnimationRecorderStart, DLIAnimationRecorderOwnerPath(self), self, key,
            NSStringFromCGRect(self.frame), DLIAnimationRecorderDescribe(animation)];
    }
    ((void (*)(CALayer *, SEL, CAAnimation *, NSString *))DLIAnimationRecorderOriginalAdd)(self, _cmd, animation, key);
}

// Samples the on-screen (presentation) geometry of every rounded view in the System
// Aperture windows once per display frame, so the real motion curves can be compared
// with the reference video frame by frame.
@interface DLIAnimationRecorderSampler : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@end

@implementation DLIAnimationRecorderSampler
- (void)start {
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    self.link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)stop {
    [self.link invalidate];
    self.link = nil;
}
- (void)appendLayer:(CALayer *)layer depth:(NSUInteger)depth into:(NSMutableString *)line {
    CALayer *presentation = layer.presentationLayer ?: layer;
    if (presentation.hidden || presentation.opacity < 0.01) return;
    if (presentation.cornerRadius > 1 && presentation.bounds.size.width > 4) {
        CGRect frame = [presentation convertRect:presentation.bounds toLayer:nil];
        id delegate = layer.delegate;
        [line appendFormat:@" [%@ %.2f %.2f %.2f %.2f r%.2f a%.2f]", delegate ? NSStringFromClass([delegate class]) : @"CALayer",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, presentation.cornerRadius, presentation.opacity];
    }
    if (depth > 14) return;
    for (CALayer *sub in layer.sublayers) [self appendLayer:sub depth:depth + 1 into:line];
}
- (void)tick:(CADisplayLink *)link {
    NSMutableString *line = [NSMutableString stringWithFormat:@"F t=%.4f", link.timestamp - DLIAnimationRecorderStart];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([NSStringFromClass(window.class) rangeOfString:@"SystemAperture"].location == NSNotFound) continue;
            [self appendLayer:window.layer depth:0 into:line];
        }
    }
    [DLIAnimationRecorderLog appendFormat:@"%@\n", line];
    // Status bar items (and our own fold layers) in every visible status bar.
    NSMutableString *bar = [NSMutableString stringWithFormat:@"B t=%.4f", link.timestamp - DLIAnimationRecorderStart];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden) continue;
            [self appendStatusBarsIn:window into:bar];
        }
    }
    [DLIAnimationRecorderLog appendFormat:@"%@\n", bar];
}
- (void)appendStatusBarsIn:(UIView *)view into:(NSMutableString *)line {
    if (view.hidden || view.alpha < 0.01) return;
    if ([NSStringFromClass(view.class) isEqualToString:@"STUIStatusBarForegroundView"]) {
        [line appendFormat:@" {%@", NSStringFromClass(view.window.class)];
        for (UIView *item in view.subviews) {
            CALayer *p = item.layer.presentationLayer ?: item.layer;
            if (item.hidden || p.opacity < 0.01) continue;
            CGRect f = [p convertRect:p.bounds toLayer:nil];
            [line appendFormat:@" [%@ %.2f %.2f %.2f %.2f a%.2f%@]", NSStringFromClass(item.class), f.origin.x, f.origin.y,
                f.size.width, f.size.height, p.opacity, [item.layer.mask.name isEqualToString:@"dli.mask"] ? @" M" : @""];
            for (CALayer *sub in p.sublayers) {
                if (![sub.name hasPrefix:@"dli."] || sub.hidden || sub.opacity < 0.01) continue;
                CGRect g = [sub convertRect:sub.bounds toLayer:nil];
                [line appendFormat:@" [%@ %.2f %.2f %.2f %.2f a%.2f]", sub.name, g.origin.x, g.origin.y, g.size.width,
                    g.size.height, sub.opacity];
            }
        }
        [line appendString:@"}"];
        return;
    }
    for (UIView *sub in view.subviews) [self appendStatusBarsIn:sub into:line];
}
@end

static DLIAnimationRecorderSampler *DLIAnimationRecorderActiveSampler = nil;
static IMP DLIAnimationRecorderOriginalResponse = NULL;

// Logs which fluid behavior settings the system reads while recording.
static double DLIAnimationRecorderResponse(id self, SEL _cmd) {
    double value = ((double (*)(id, SEL))DLIAnimationRecorderOriginalResponse)(self, _cmd);
    if (DLIAnimationRecorderActive) {
        NSString *name = nil;
        @try { name = [self valueForKey:@"name"]; } @catch (__unused NSException *e) {}
        double damping = 0;
        @try { damping = [[self valueForKey:@"dampingRatio"] doubleValue]; } @catch (__unused NSException *e) {}
        [DLIAnimationRecorderLog appendFormat:@"S t=%.4f settings=%@ %p response=%.4f damping=%.4f\n",
            CACurrentMediaTime() - DLIAnimationRecorderStart, name, self, value, damping];
    }
    return value;
}

void DLIAnimationRecorderInstall(void) {
    Class fluid = NSClassFromString(@"SBFFluidBehaviorSettings");
    Method responseMethod = fluid ? class_getInstanceMethod(fluid, @selector(response)) : NULL;
    if (responseMethod) DLIAnimationRecorderOriginalResponse = method_setImplementation(responseMethod, (IMP)DLIAnimationRecorderResponse);
    Method method = class_getInstanceMethod(CALayer.class, @selector(addAnimation:forKey:));
    DLIAnimationRecorderOriginalAdd = method_setImplementation(method, (IMP)DLIAnimationRecorderAdd);
    int token = 0;
    notify_register_dispatch("app.yellowplus.dli.record.start", &token, dispatch_get_main_queue(), ^(int t) {
        DLIAnimationRecorderLog = [NSMutableString string];
        DLIAnimationRecorderStart = CACurrentMediaTime();
        DLIAnimationRecorderActive = YES;
        DLIAnimationRecorderActiveSampler = [DLIAnimationRecorderSampler new];
        [DLIAnimationRecorderActiveSampler start];
    });
    notify_register_dispatch("app.yellowplus.dli.record.stop", &token, dispatch_get_main_queue(), ^(int t) {
        DLIAnimationRecorderActive = NO;
        [DLIAnimationRecorderActiveSampler stop];
        DLIAnimationRecorderActiveSampler = nil;
        [DLIAnimationRecorderLog writeToFile:DLIAnimationRecorderPath atomically:YES encoding:NSUTF8StringEncoding
                                       error:nil];
    });
}

