#import <Foundation/Foundation.h>

// Timing of the status bar fold. Every part of the morph has its own progress p
// (0 = the normal status bar, 1 = the ring) driven by a damped spring toward the
// current target. The delays and springs come from the design video (fold settles in
// about 0.5 s, unfold in about 0.8 s, parts staggered as in the video).
//
// Retargeting keeps both position and velocity: a part that is moving turns around
// with the momentum it has, a part at rest waits for its delay in the new direction.
// Each segment is solved in closed form, so progress is a pure function of time and a
// skipped or late frame (screen off, hitch) never desynchronizes anything.

typedef NS_ENUM(NSInteger, DLIFoldPart) {
    DLIFoldPartOthers = 0, // trailing icons that are not part of the ring
    DLIFoldPartBattery,
    DLIFoldPartCenter,     // Wi-Fi (or airplane / network type) glyph
    DLIFoldPartBar0,
    DLIFoldPartBar1,
    DLIFoldPartBar2,
    DLIFoldPartBar3,
    DLIFoldPartArc,
    DLIFoldPartCount
};

@interface DLIFoldTimeline : NSObject
@property (nonatomic, readonly, getter=isFolded) BOOL folded; // the current target
// Read when a new target is set; Reduce Motion turns the morph into a short crossfade.
@property (nonatomic) BOOL reduceMotion;
@property (nonatomic, readonly) BOOL crossfading; // the running transition is a crossfade
// Debug builds stretch every delay and spring by this factor (1 = design speed).
@property (nonatomic) double timeScale;

- (void)setFolded:(BOOL)folded atTime:(CFTimeInterval)time animated:(BOOL)animated;
- (double)progressOfPart:(DLIFoldPart)part atTime:(CFTimeInterval)time;
- (double)velocityOfPart:(DLIFoldPart)part atTime:(CFTimeInterval)time;
// YES while any part still moves or waits for its delay.
- (BOOL)isAnimatingAtTime:(CFTimeInterval)time;
// YES once the timeline sits fully unfolded and nothing is pending.
- (BOOL)isRestingUnfoldedAtTime:(CFTimeInterval)time;
@end
