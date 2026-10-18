#import <UIKit/UIKit.h>
#import "DLIApertureObserver.h"
#import "DLIDisplayLink.h"
#import "DLIFoldTimeline.h"

// Folds the trailing status bar icons into a ring while the System Aperture shows two
// elements side by side (native mitosis), and unfolds them when it goes back to one.
// The island itself is never touched; the controller only follows its layout reports.
//
// While folded, the trailing half of the status bar avoidance frame is clipped at the
// island so the system keeps its icons in their normal places (hidden under the
// ring) instead of squeezing them away from the bubble; the leading half, which moves
// the clock, stays native.

@interface DLIFoldController : NSObject <DLIDisplayLinkSubscriber>
+ (instancetype)sharedController;

@property (nonatomic, readonly) DLIFoldTimeline *timeline;
@property (nonatomic, readonly) DLIApertureObserver *observer;

- (void)apertureDidLayout:(UIViewController *)apertureViewController;

- (void)statusBarDidLayout:(UIView *)statusBar;
- (void)statusBarDidUpdateContent:(UIView *)statusBar;

// Avoidance frame plumbing for -[STUIStatusBar setAvoidanceFrame:...].
- (CGRect)adjustedAvoidanceFrame:(CGRect)frame forStatusBar:(UIView *)statusBar;
// The status bar follows the island's width changes with the island's own spring; this
// keeps its response and lowers the damping a little so the clock and icons settle
// with a slight bounce.
- (id)livelierAvoidanceSettings:(id)settings;
- (void)statusBar:(UIView *)statusBar didRequestAvoidanceFrame:(CGRect)frame settings:(id)settings
          options:(NSUInteger)options animated:(BOOL)animated;
@end
