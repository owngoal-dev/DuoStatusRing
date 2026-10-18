#import "DLIDisplayLink.h"
#import <UIKit/UIKit.h>

// Breaks the CADisplayLink -> target retain cycle.
@interface DLIDisplayLinkProxy : NSObject
@property (nonatomic, weak) DLIDisplayLink *owner;
@end

@interface DLIDisplayLink ()
- (void)tick:(CADisplayLink *)link;
@end

@implementation DLIDisplayLinkProxy
- (void)tick:(CADisplayLink *)link {
    DLIDisplayLink *owner = self.owner;
    if (owner) [owner tick:link];
    else [link invalidate];
}
@end

@implementation DLIDisplayLink {
    CADisplayLink *_link;
    NSPointerArray *_subscribers;
}

+ (instancetype)sharedLink {
    static DLIDisplayLink *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [DLIDisplayLink new];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _subscribers = [NSPointerArray weakObjectsPointerArray];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(powerStateDidChange:)
                                                   name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    }
    return self;
}

- (BOOL)isRunning {
    return _link != nil;
}

- (BOOL)containsSubscriber:(id)subscriber {
    for (NSUInteger i = 0; i < _subscribers.count; i++) {
        if ([_subscribers pointerAtIndex:i] == (__bridge void *)subscriber) return YES;
    }
    return NO;
}

- (void)addSubscriber:(id<DLIDisplayLinkSubscriber>)subscriber {
    if (!subscriber || [self containsSubscriber:subscriber]) return;
    [_subscribers addPointer:(__bridge void *)subscriber];
    [self startIfNeeded];
}

// -[NSPointerArray compact] keeps entries whose weak object is gone; rebuilding from
// allObjects is what actually drops them.
- (void)purge {
    NSArray *alive = _subscribers.allObjects;
    if (alive.count == _subscribers.count) return;
    NSPointerArray *fresh = [NSPointerArray weakObjectsPointerArray];
    for (id subscriber in alive) [fresh addPointer:(__bridge void *)subscriber];
    _subscribers = fresh;
}

- (void)removeSubscriber:(id<DLIDisplayLinkSubscriber>)subscriber {
    for (NSUInteger i = _subscribers.count; i > 0; i--) {
        if ([_subscribers pointerAtIndex:i - 1] == (__bridge void *)subscriber) [_subscribers removePointerAtIndex:i - 1];
    }
    [self purge];
    // Stopping is left to the next tick so a subscriber that leaves and comes back
    // within one frame does not tear the link down and rebuild it.
}

- (CAFrameRateRange)preferredRange {
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) return CAFrameRateRangeMake(30, 60, 60);
    return CAFrameRateRangeMake(80, 120, 120);
}

- (void)startIfNeeded {
    if (_link) return;
    DLIDisplayLinkProxy *proxy = [DLIDisplayLinkProxy new];
    proxy.owner = self;
    _link = [UIScreen.mainScreen displayLinkWithTarget:proxy selector:@selector(tick:)];
    _link.preferredFrameRateRange = [self preferredRange];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [_link invalidate];
    _link = nil;
}

- (void)powerStateDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_link) self->_link.preferredFrameRateRange = [self preferredRange];
    });
}

- (void)tick:(CADisplayLink *)link {
    // Copy first: a subscriber may unsubscribe while being called.
    NSArray *subscribers = _subscribers.allObjects;
    if (subscribers.count == 0) {
        [self purge];
        [self stop];
        return;
    }
    CFTimeInterval target = link.targetTimestamp;
    for (id<DLIDisplayLinkSubscriber> subscriber in subscribers) [subscriber displayLinkWillDrawFrameAt:target];
}

@end
