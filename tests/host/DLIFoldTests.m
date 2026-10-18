// Host-side checks for the pure parts of the fold: timeline retargeting and geometry.
// Build and run: Tests/run-tests.sh
#import <Foundation/Foundation.h>
#import "DLIFoldGeometry.h"
#import "DLIFoldTimeline.h"

static int DLITestFailures = 0;
#define DLIExpect(cond, ...) do { if (!(cond)) { DLITestFailures++; NSLog(@"FAIL line %d: %@", __LINE__, [NSString stringWithFormat:__VA_ARGS__]); } } while (0)

static DLIFoldInput DLITestInput(void) {
    // Measured on the iPhone Air guest (420 pt wide), normal layout of the trailing icons.
    DLIFoldInput in;
    memset(&in, 0, sizeof(in));
    CGRect island = CGRectMake(147.33, 20, 125.33, 36.67);
    CGRect cluster = CGRectMake(298.33, 31, 87.33, 14.33);
    in.ring = DLIFoldRingMake(island, cluster, DLIFoldBubbleMaxX(island), 420);
    in.barCount = 4;
    in.signal = (DLIItemState){CGPointMake(309.17, 38.17), CGSizeMake(21.67, 13.67), 1, 1, 1};
    CGFloat heights[4] = {5.33, 7.67, 10.67, 13.67};
    for (int i = 0; i < 4; i++) in.bars[i] = (DLIBarShape){CGRectMake(6 * i, 13.67 - heights[i], 3.67, heights[i]), 1.2};
    in.hasCenter = YES;
    in.center = (DLIItemState){CGPointMake(337.17, 38), CGSizeMake(19.67, 14), 1, 1, 1};
    in.hasBattery = YES;
    in.battery = (DLIItemState){CGPointMake(370, 38.17), CGSizeMake(31.33, 14.33), 1, 1, 1};
    in.batteryBody = CGRectMake(0, 0, 28.33, 14.33);
    in.batteryBodyCornerRadius = 4.3;
    in.batteryLevel = 0.62;
    return in;
}

// Every drawn quantity, flattened, for frame-to-frame comparison.
static NSArray<NSNumber *> *DLIFlatten(DLIFoldOutput o) {
    NSMutableArray *v = [NSMutableArray array];
    for (int i = 0; i < o.dotCount; i++) {
        DLIShapeState d = o.dots[i];
        [v addObjectsFromArray:@[@(d.position.x), @(d.position.y), @(d.size.width), @(d.size.height), @(d.alpha * 10)]];
    }
    [v addObjectsFromArray:@[@(o.center.position.x), @(o.center.position.y), @(o.center.scaleX * 10), @(o.center.alpha * 10)]];
    [v addObjectsFromArray:@[@(o.capsule.position.x), @(o.capsule.position.y), @(o.capsule.size.width), @(o.capsule.size.height)]];
    [v addObjectsFromArray:@[@(o.battery.alpha * 10), @(o.othersAlpha * 10)]];
    // Arc ends in points along the ring (radius 17).
    // A hidden arc is a zero-length arc at its seed.
    [v addObjectsFromArray:@[@(o.arcVisible ? o.arcStart * 17 : DLIFoldArcSeedAngle * 17),
                             @(o.arcVisible ? o.arcEnd * 17 : DLIFoldArcSeedAngle * 17)]];
    return v;
}

static DLIFoldOutput DLIOutputAt(DLIFoldTimeline *timeline, const DLIFoldInput *in, CFTimeInterval t) {
    DLIFoldProgress p;
    memset(&p, 0, sizeof(p));
    for (int i = 0; i < DLIFoldPartCount; i++) p.parts[i] = [timeline progressOfPart:i atTime:t];
    return DLIFoldEvaluate(in, p, timeline.crossfading);
}

static void DLITestEndStates(void) {
    DLIFoldInput in = DLITestInput();
    DLIFoldTimeline *timeline = [DLIFoldTimeline new];
    DLIFoldOutput rest = DLIOutputAt(timeline, &in, 100);
    DLIExpect(rest.othersAlpha == 1 && !rest.arcVisible && rest.capsule.alpha == 0, @"unfolded rest state");
    DLIExpect(fabs(rest.center.position.x - in.center.position.x) < 1e-6, @"center glyph starts on the real icon");
    DLIExpect(fabs(rest.battery.alpha - 1) < 1e-6, @"battery snapshot fully visible at rest");
    // Bar 3 at rest sits exactly on the system bar.
    CGFloat x3 = in.signal.position.x + (CGRectGetMidX(in.bars[3].frame) - in.signal.size.width / 2);
    DLIExpect(fabs(rest.dots[3].position.x - x3) < 1e-6 && fabs(rest.dots[3].size.height - 13.67) < 1e-6, @"bar 3 rest");

    [timeline setFolded:YES atTime:100 animated:YES];
    DLIExpect([timeline isAnimatingAtTime:100.3], @"animating mid fold");
    DLIExpect(![timeline isAnimatingAtTime:102], @"fold settles");
    // Visually done by 0.7 s: every part within 3 % of the ring (the arc may still bounce).
    for (int i = 0; i < DLIFoldPartCount; i++)
        DLIExpect(fabs([timeline progressOfPart:i atTime:100.7] - 1) < 0.03, @"part %d at 0.7 s: %.3f", i, [timeline progressOfPart:i atTime:100.7]);
    DLIFoldOutput folded = DLIOutputAt(timeline, &in, 103);
    DLIExpect(folded.arcVisible && fabs((folded.arcEnd - folded.arcStart) - 4 * M_PI / 3) < 1e-6, @"arc spans 240 degrees");
    DLIExpect(fabs(folded.arcStart + 7 * M_PI / 6) < 1e-6, @"arc starts at 150 degrees");
    DLIExpect(fabs(folded.arcFillEnd - folded.arcStart - (4 * M_PI / 3) * 0.62) < 1e-6, @"fill follows the level");
    DLIExpect(folded.othersAlpha == 0 && folded.battery.alpha == 0 && folded.capsule.alpha == 0, @"folded hides the rest");
    for (int i = 0; i < 4; i++) {
        CGFloat theta = (89 + 20.6 * (1.5 - i)) * M_PI / 180;
        CGPoint expect = DLIRingPoint(in.ring.center, in.ring.dotRadius, theta);
        DLIExpect(hypot(folded.dots[i].position.x - expect.x, folded.dots[i].position.y - expect.y) < 1e-6, @"dot %d", i);
    }
    DLIExpect(hypot(folded.center.position.x - in.ring.center.x, folded.center.position.y - (in.ring.center.y - in.ring.centerLift)) < 1e-6,
              @"wifi centered");

    [timeline setFolded:NO atTime:103 animated:YES];
    DLIExpect([timeline isAnimatingAtTime:103.5], @"unfold still running at 0.5 s");
    for (int i = 0; i < DLIFoldPartCount; i++)
        DLIExpect(fabs([timeline progressOfPart:i atTime:104]) < 0.03, @"part %d unfolded at 1 s (bounce within 3 %%)", i);
    DLIExpect([timeline isRestingUnfoldedAtTime:106], @"unfold settles");
    NSArray *a = DLIFlatten(rest), *b = DLIFlatten(DLIOutputAt(timeline, &in, 106));
    for (NSUInteger i = 0; i < a.count; i++) DLIExpect(fabs([a[i] doubleValue] - [b[i] doubleValue]) < 1e-6, @"unfold returns to rest, value %lu", (unsigned long)i);
}

// Largest first and second differences of any drawn value between 120 Hz frames in an
// uninterrupted fold and unfold: the fastest the animation moves and accelerates.
static void DLIBaseline(const DLIFoldInput *in, double *speed, double *accel) {
    DLIFoldTimeline *timeline = [DLIFoldTimeline new];
    double dt = 1.0 / 120;
    *speed = *accel = 0;
    [timeline setFolded:YES atTime:0 animated:YES];
    NSArray<NSNumber *> *a = DLIFlatten(DLIOutputAt(timeline, in, 0)), *b = DLIFlatten(DLIOutputAt(timeline, in, dt));
    for (double t = 2 * dt; t < 4; t += dt) {
        if (fabs(t - 2) < dt / 2) [timeline setFolded:NO atTime:t animated:YES];
        NSArray<NSNumber *> *c = DLIFlatten(DLIOutputAt(timeline, in, t));
        for (NSUInteger i = 0; i < c.count; i++) {
            double d1 = c[i].doubleValue - b[i].doubleValue, d0 = b[i].doubleValue - a[i].doubleValue;
            *speed = MAX(*speed, fabs(d1));
            *accel = MAX(*accel, fabs(d1 - d0));
        }
        a = b;
        b = c;
    }
}

// Retargets at random moments: nothing may jump (speed) or snap around (acceleration)
// beyond what the uninterrupted animation does, so momentum survives interruptions.
static void DLITestInterruptions(void) {
    DLIFoldInput in = DLITestInput();
    double baseSpeed, baseAccel;
    DLIBaseline(&in, &baseSpeed, &baseAccel);
    srand48(7);
    double worstSpeed = 0, worstAccel = 0;
    for (int run = 0; run < 400; run++) {
        DLIFoldTimeline *timeline = [DLIFoldTimeline new];
        double t = 10, dt = 1.0 / 120;
        double nextToggle = t + drand48() * 0.6;
        BOOL folded = NO;
        NSArray<NSNumber *> *a = DLIFlatten(DLIOutputAt(timeline, &in, t));
        NSArray<NSNumber *> *b = DLIFlatten(DLIOutputAt(timeline, &in, t + dt));
        t += dt;
        for (int frame = 0; frame < 500; frame++) {
            t += dt;
            if (t >= nextToggle) {
                folded = !folded;
                [timeline setFolded:folded atTime:t - dt / 2 animated:YES];
                // Mostly rapid flips, sometimes long enough to settle.
                nextToggle = t + (drand48() < 0.7 ? drand48() * 0.25 : 0.3 + drand48() * 0.8);
            }
            NSArray<NSNumber *> *c = DLIFlatten(DLIOutputAt(timeline, &in, t));
            // The battery and the arc are never out together.
            double arc = [timeline progressOfPart:DLIFoldPartArc atTime:t];
            double battery = [timeline progressOfPart:DLIFoldPartBattery atTime:t];
            DLIExpect(!(arc > 0.05 && battery < 0.8), @"run %d frame %d arc %.3f with battery %.3f", run, frame, arc, battery);
            for (NSUInteger i = 0; i < c.count; i++) {
                double d1 = c[i].doubleValue - b[i].doubleValue, d0 = b[i].doubleValue - a[i].doubleValue;
                worstSpeed = MAX(worstSpeed, fabs(d1));
                worstAccel = MAX(worstAccel, fabs(d1 - d0));
                DLIExpect(fabs(d1) <= baseSpeed * 1.3, @"run %d frame %d value %lu moves %.2f", run, frame, (unsigned long)i, d1);
                DLIExpect(fabs(d1 - d0) <= baseAccel * 1.6, @"run %d frame %d value %lu snaps %.3f", run, frame, (unsigned long)i, d1 - d0);
            }
            a = b;
            b = c;
        }
    }
    NSLog(@"per-frame change: %.3f pt uninterrupted, %.3f pt interrupted; per-frame change of that: %.3f vs %.3f",
          baseSpeed, worstSpeed, baseAccel, worstAccel);
}

// Momentum: reversing mid-flight keeps the velocity of every part.
static void DLITestMomentum(void) {
    DLIFoldTimeline *timeline = [DLIFoldTimeline new];
    [timeline setFolded:YES atTime:0 animated:YES];
    double t = 0.3;
    double before[DLIFoldPartCount];
    for (int i = 0; i < DLIFoldPartCount; i++) before[i] = [timeline velocityOfPart:i atTime:t];
    [timeline setFolded:NO atTime:t animated:YES];
    for (int i = 0; i < DLIFoldPartCount; i++) {
        BOOL moving = fabs([timeline progressOfPart:i atTime:t - 1e-6] - 1) >= 0.02 || fabs(before[i]) >= 0.2;
        if (moving) DLIExpect(fabs([timeline velocityOfPart:i atTime:t] - before[i]) < 1e-9, @"part %d keeps its velocity", i);
    }
}

// Without signal or Wi-Fi the ring still shows four dim dots and no center glyph.
static void DLITestMissingItems(void) {
    DLIFoldInput in = DLITestInput();
    in.barCount = 0;
    in.hasCenter = NO;
    DLIFoldTimeline *timeline = [DLIFoldTimeline new];
    DLIFoldOutput rest = DLIOutputAt(timeline, &in, 5);
    for (int i = 0; i < 4; i++) DLIExpect(rest.dots[i].alpha == 0, @"phantom dot %d hidden at rest", i);
    [timeline setFolded:YES atTime:5 animated:YES];
    DLIFoldOutput folded = DLIOutputAt(timeline, &in, 8);
    for (int i = 0; i < 4; i++) DLIExpect(fabs(folded.dots[i].alpha - 1) < 1e-3, @"phantom dot %d shown folded", i);
    DLIExpect(folded.center.alpha == 0, @"no center glyph");
}

// Reversing at any moment of a fold keeps the battery waiting for the arc (and back).
static void DLITestDependencyAcrossReversals(void) {
    for (double at = 0.02; at < 1.2; at += 0.004) {
        DLIFoldTimeline *timeline = [DLIFoldTimeline new];
        [timeline setFolded:YES atTime:0 animated:YES];
        [timeline setFolded:NO atTime:at animated:YES];
        [timeline setFolded:YES atTime:at + 0.25 animated:YES];
        for (double t = 0; t < at + 2; t += 1.0 / 240) {
            double arc = [timeline progressOfPart:DLIFoldPartArc atTime:t];
            double battery = [timeline progressOfPart:DLIFoldPartBattery atTime:t];
            DLIExpect(!(arc > 0.05 && battery < 0.8), @"reverse at %.3f: t %.3f arc %.3f battery %.3f", at, t, arc, battery);
        }
    }
}

// Turning Reduce Motion on mid-transition does not switch the running transition.
static void DLITestReduceMotionMidFlight(void) {
    DLIFoldTimeline *timeline = [DLIFoldTimeline new];
    [timeline setFolded:YES atTime:0 animated:YES];
    timeline.reduceMotion = YES;
    [timeline setFolded:NO atTime:0.25 animated:YES];
    DLIExpect(!timeline.crossfading, @"a morph turned around stays a morph");
    [timeline setFolded:YES atTime:5 animated:YES];
    DLIExpect(timeline.crossfading, @"the next transition from rest crossfades");
}

static void DLITestReduceMotion(void) {
    DLIFoldInput in = DLITestInput();
    DLIFoldTimeline *timeline = [DLIFoldTimeline new];
    timeline.reduceMotion = YES;
    [timeline setFolded:YES atTime:1 animated:YES];
    DLIExpect(timeline.crossfading && ![timeline isAnimatingAtTime:1.201], @"crossfade lasts 0.2 s");
    DLIFoldOutput mid = DLIOutputAt(timeline, &in, 1.1);
    DLIExpect(fabs(mid.center.position.x - in.ring.center.x) < 1e-6, @"crossfade does not move the glyph");
    DLIExpect(mid.othersAlpha > 0 && mid.othersAlpha < 1, @"expanded copies fading");
}

int main(void) {
    @autoreleasepool {
        DLITestEndStates();
        DLITestInterruptions();
        DLITestMomentum();
        DLITestDependencyAcrossReversals();
        DLITestReduceMotionMidFlight();
        DLITestMissingItems();
        DLITestReduceMotion();
        NSLog(@"%@", DLITestFailures ? [NSString stringWithFormat:@"%d failures", DLITestFailures] : @"all passed");
        return DLITestFailures ? 1 : 0;
    }
}
