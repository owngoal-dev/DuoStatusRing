#import <Foundation/Foundation.h>

// Records the top of the real display (what the render server composites, island
// included) to an H.264 file inside SpringBoard, for test videos. Debug builds only.
FOUNDATION_EXTERN void DLIDebugCaptureInstall(void);
FOUNDATION_EXTERN void DLIDebugCaptureStart(CGFloat heightInPoints, double fps);
FOUNDATION_EXTERN NSString *DLIDebugCaptureStop(void);
