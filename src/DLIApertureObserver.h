#import <UIKit/UIKit.h>

// Reads the System Aperture's own layout report (posted whenever its elements or
// frames change) and reduces it to what the status bar needs.

typedef NS_ENUM(NSInteger, DLIAperturePhase) {
    DLIAperturePhaseUnknown = 0,
    DLIAperturePhaseSingle,   // idle, one compact element, or suppressed
    DLIAperturePhaseSplit,    // mitosis: two elements, the second as a minimal bubble
    DLIAperturePhaseExpanded, // an element is expanded (alert, long press, custom layout)
    DLIAperturePhaseLandscape,
};

@interface DLIApertureObserver : NSObject
@property (nonatomic, readonly) DLIAperturePhase phase;
@property (nonatomic, readonly) CGRect islandFrame;  // hardware island, screen coordinates
@property (nonatomic, readonly) CGRect primaryFrame; // first element, screen coordinates
// Returns YES when the phase changed.
- (BOOL)updateFromApertureViewController:(UIViewController *)viewController;
@end
