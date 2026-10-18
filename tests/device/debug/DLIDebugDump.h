#import <UIKit/UIKit.h>

FOUNDATION_EXTERN void DLIDebugDumpInstall(void);
FOUNDATION_EXTERN void DLIDebugDumpNow(void);
// Gives a new status bar the simulated radio data the tests asked for, if any.
FOUNDATION_EXTERN void DLIDebugApplyRadioOverlayIfNeeded(UIView *statusBar);
FOUNDATION_EXTERN BOOL DLIDebugIsRadioOverlayActive(void);
FOUNDATION_EXTERN BOOL DLIDebugIsRadioOverlay(id data);
