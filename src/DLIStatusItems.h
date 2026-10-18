#import <UIKit/UIKit.h>
#import "DLIFoldGeometry.h"

// Reads the trailing items of one STUIStatusBar and sorts them into the parts of the
// ring. Everything is read live from the system views, so the fold starts exactly
// where the real icons are and ends exactly where they will be.

typedef NS_ENUM(NSInteger, DLIStatusItemRole) {
    DLIStatusItemRoleOther = 0,
    DLIStatusItemRoleSignal,
    DLIStatusItemRoleCenter,
    DLIStatusItemRoleBattery,
};

@interface DLIStatusItem : NSObject
@property (nonatomic, weak, readonly) UIView *view;
@property (nonatomic, readonly) DLIStatusItemRole role;
@property (nonatomic, copy, readonly) NSString *identifier;
@end

@interface DLIStatusItemSet : NSObject
@property (nonatomic, copy, readonly) NSArray<DLIStatusItem *> *items;
@property (nonatomic, strong, readonly) DLIStatusItem *signal;
@property (nonatomic, strong, readonly) DLIStatusItem *center;
@property (nonatomic, strong, readonly) DLIStatusItem *battery;
@property (nonatomic, copy, readonly) NSArray<DLIStatusItem *> *others;
+ (instancetype)itemsOfStatusBar:(UIView *)statusBar;
// Same views in the same roles.
- (BOOL)isEquivalentToSet:(DLIStatusItemSet *)other;
@end

// The item's on-screen state (presentation layer) in the coordinates of space.
FOUNDATION_EXTERN DLIItemState DLIStatusItemLiveState(UIView *view, UIView *space);
// The item's resting frame (model layer, transform ignored) in the coordinates of space.
FOUNDATION_EXTERN CGRect DLIStatusItemRestingFrame(UIView *view, UIView *space);
// Renders the view as it looks unhidden, at scale, ignoring a DLI mask on it.
FOUNDATION_EXTERN UIImage *DLIStatusItemSnapshot(UIView *view, CGFloat scale);

// Hiding a system icon by giving its layer an empty mask, which the status bar never
// touches (it animates alpha, hidden and transform of these views itself).
FOUNDATION_EXTERN void DLIStatusItemSetHidden(UIView *view, BOOL hidden);
FOUNDATION_EXTERN BOOL DLIStatusItemIsHidden(UIView *view);

// Status bar facts.
FOUNDATION_EXTERN UIColor *DLIStatusBarForegroundColor(UIView *statusBar);
FOUNDATION_EXTERN UIView *DLIStatusBarForegroundView(UIView *statusBar);
FOUNDATION_EXTERN BOOL DLIStatusBarIsPortrait(UIView *statusBar);
FOUNDATION_EXTERN NSInteger DLIStatusBarMode(UIView *statusBar);

// Signal and battery details.
FOUNDATION_EXTERN NSInteger DLIStatusSignalBars(UIView *signalView, DLIBarShape *shapes, CGColorRef *colors, NSInteger max);
FOUNDATION_EXTERN CGFloat DLIStatusBatteryLevel(UIView *batteryView);
FOUNDATION_EXTERN UIColor *DLIStatusBatteryFillColor(UIView *batteryView, UIColor *fallback);
FOUNDATION_EXTERN CGRect DLIStatusBatteryBody(UIView *batteryView, CGFloat *cornerRadius);
