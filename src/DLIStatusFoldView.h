#import <UIKit/UIKit.h>
#import "DLIFoldGeometry.h"

// The ring drawn on top of one status bar's foreground view. While it is attached the
// system's trailing icons are hidden (see DLIStatusItemSetHidden) and replaced by
// copies that morph into the ring; detaching shows the system icons again.

@class DLIStatusItemSet;

@interface DLIStatusFoldView : UIView
@property (nonatomic, weak, readonly) UIView *statusBar;
@property (nonatomic, strong, readonly) DLIStatusItemSet *items;
- (instancetype)initWithStatusBar:(UIView *)statusBar;
// Re-reads which icons exist and their colors and hides them. Snapshots of the icons
// (used while the fold moves) are taken now or marked stale for takeSnapshotsIfNeeded.
- (void)reloadItemsTakingSnapshots:(BOOL)snapshots;
- (void)takeSnapshotsIfNeeded;
// Hides a system icon right away (an icon that appeared while folded).
- (void)hideSystemIcon:(UIView *)view;
// island: the hardware island in status bar coordinates (from DLIApertureObserver).
// keepRing: reuse the ring placed by the last render instead of measuring the icons
// again (while unfolding the icons move to their new places, the ring must not).
// moving: the fold itself is in motion this frame (data changes then do not animate the
// arc's level, which the fold is already moving).
- (void)renderWithProgress:(DLIFoldProgress)progress crossfade:(BOOL)crossfade island:(CGRect)island
                  keepRing:(BOOL)keepRing moving:(BOOL)moving time:(CFTimeInterval)time;
- (void)detach;
@end
