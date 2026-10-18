#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>

// One shared CADisplayLink for every DLI animation on the main screen, modeled on
// Lakr233/DisplayLink: subscribers are held weakly and called in subscription order,
// and the system link only exists while someone is subscribed, so a resting
// SpringBoard spends nothing on it. The frame rate follows the System Aperture's
// own mitosis range (80-120 Hz) and drops to 60 Hz in Low Power Mode.

@protocol DLIDisplayLinkSubscriber <NSObject>
// targetTimestamp is the time the frame being prepared will be shown.
- (void)displayLinkWillDrawFrameAt:(CFTimeInterval)targetTimestamp;
@end

@interface DLIDisplayLink : NSObject
+ (instancetype)sharedLink;
- (void)addSubscriber:(id<DLIDisplayLinkSubscriber>)subscriber;
- (void)removeSubscriber:(id<DLIDisplayLinkSubscriber>)subscriber;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@end
