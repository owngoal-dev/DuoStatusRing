#import "DLIFoldGeometry.h"
#import "DLIFoldTimeline.h"

const CGFloat DLIFoldArcSeedAngle = -M_PI / 6;

static CGFloat DLIClamp(CGFloat x) {
    return x < 0 ? 0 : (x > 1 ? 1 : x);
}

static CGFloat DLILerp(CGFloat a, CGFloat b, CGFloat t) {
    return a + (b - a) * t;
}

static CGPoint DLILerpPoint(CGPoint a, CGPoint b, CGFloat t) {
    return CGPointMake(DLILerp(a.x, b.x, t), DLILerp(a.y, b.y, t));
}

// Smootherstep: zero velocity and acceleration at both ends, so a part that reverses
// halfway through its window and a part that starts from rest both look natural.
CGFloat DLIEaseInOut(CGFloat x) {
    x = DLIClamp(x);
    return x * x * x * (x * (x * 6 - 15) + 10);
}

CGPoint DLIRingPoint(CGPoint center, CGFloat radius, CGFloat angle) {
    return CGPointMake(center.x + radius * cos(angle), center.y + radius * sin(angle));
}

CGFloat DLIFoldBubbleMaxX(CGRect island) {
    // Native mitosis on iOS 26: an island-high bubble 8 pt (on a 37 pt island) right of it.
    CGFloat h = island.size.height;
    return CGRectGetMaxX(island) + h * 8.0 / 37.0 + h;
}

DLIRing DLIFoldRingMake(CGRect island, CGRect cluster, CGFloat bubbleMaxX, CGFloat width) {
    CGFloat h = island.size.height > 1 ? island.size.height : 37;
    CGFloat k = h / 37.0;
    DLIRing ring;
    // Weights measured on the design frames: arc 2.6-2.75 pt, dots 3.55 pt; the outer
    // diameter stays the island's height.
    ring.radius = 16.85 * k;
    ring.lineWidth = 2.6 * k;
    ring.dotRadius = 16.55 * k;
    ring.dotDiameter = 3.6 * k;
    ring.centerScale = 1.09;
    ring.centerLift = 0.2 * k;
    ring.scale = k;
    CGFloat outer = ring.radius + ring.lineWidth / 2;
    // At least the island-to-bubble gap (8 pt on a 37 pt island) after the bubble.
    CGFloat gap = 8 * k;
    BOOL hasCluster = !CGRectIsNull(cluster) && !CGRectIsEmpty(cluster);
    CGFloat cx = hasCluster ? CGRectGetMidX(cluster) + 0.85 * k : bubbleMaxX + gap + outer;
    if (bubbleMaxX > 0) cx = MAX(cx, bubbleMaxX + gap + outer);
    if (width > 0) cx = MIN(cx, width - outer - 4 * k);
    CGFloat cy = island.size.height > 1 ? CGRectGetMidY(island) : (hasCluster ? CGRectGetMidY(cluster) : h / 2);
    ring.center = CGPointMake(cx, cy);
    return ring;
}

// Progress values come from springs (DLIFoldTimeline): they may overshoot 0 or 1
// slightly, which positions keep (the bounce) and sizes and alphas clamp.
DLIFoldOutput DLIFoldEvaluate(const DLIFoldInput *in, DLIFoldProgress p, BOOL crossfade) {
    DLIFoldOutput out;
    memset(&out, 0, sizeof(out));
    DLIRing ring = in->ring;
    CGPoint c = ring.center;
    CGFloat dd = ring.dotDiameter;
    out.crossfade = crossfade;

    // Signal bars spiral down onto the ring and settle as dots at its bottom opening
    // (about 119, 99, 79, 58 degrees for four bars): radius and angle around the ring's
    // center move separately, the angle on the raw spring value (the bounce). When the
    // system has hidden the bars (a wide island needed the room) the dots fade in and out
    // at their places instead, blended by the bars' live opacity so nothing jumps.
    NSInteger n = in->barCount > 0 ? MIN(in->barCount, DLI_MAX_BARS) : DLI_MAX_BARS;
    out.dotCount = n;
    for (NSInteger i = 0; i < n; i++) {
        NSInteger slot = i + (DLI_MAX_BARS - n);
        CGFloat raw = p.parts[DLIFoldPartBar0 + slot];
        CGFloat x = DLIClamp(raw);
        CGFloat theta = (89.0 + 20.6 * ((n - 1) / 2.0 - i)) * M_PI / 180.0;
        CGPoint end = DLIRingPoint(c, ring.dotRadius, theta);
        DLIShapeState *dot = &out.dots[i];
        CGFloat shown = in->barCount > 0 && !crossfade ? DLIClamp(in->signal.alpha) : 0;
        if (shown <= 0) {
            dot->position = end;
            dot->size = CGSizeMake(dd, dd);
            dot->cornerRadius = dd / 2;
            dot->alpha = x;
            continue;
        }
        DLIItemState s = in->signal;
        DLIBarShape bar = in->bars[i];
        CGPoint start = CGPointMake(s.position.x + (CGRectGetMidX(bar.frame) - s.size.width / 2) * s.scaleX,
                                    s.position.y + (CGRectGetMidY(bar.frame) - s.size.height / 2) * s.scaleY);
        CGSize startSize = CGSizeMake(bar.frame.size.width * s.scaleX, bar.frame.size.height * s.scaleY);
        CGFloat startCorner = bar.cornerRadius * MIN(s.scaleX, s.scaleY);
        CGFloat r0 = hypot(start.x - c.x, start.y - c.y);
        CGFloat a0 = atan2(start.y - c.y, start.x - c.x);
        if (a0 < -M_PI_2) a0 += 2 * M_PI; // keep left-hand starts continuous through 180 degrees
        CGFloat r = DLILerp(r0, ring.dotRadius, DLIEaseInOut(x));
        CGFloat a = DLILerp(a0, theta, raw);
        CGFloat shrink = DLIEaseInOut(x * 1.3);
        CGPoint morph = DLIRingPoint(c, r, a);
        CGSize morphSize = CGSizeMake(DLILerp(startSize.width, dd, shrink), DLILerp(startSize.height, dd, shrink));
        CGFloat morphCorner = DLILerp(startCorner, dd / 2, shrink);
        dot->position = DLILerpPoint(end, morph, shown);
        dot->size = CGSizeMake(DLILerp(dd, morphSize.width, shown), DLILerp(dd, morphSize.height, shown));
        dot->cornerRadius = MIN(DLILerp(dd / 2, morphCorner, shown), MIN(dot->size.width, dot->size.height) / 2);
        dot->alpha = DLILerp(s.alpha, 1, x);
    }

    // The center glyph moves into the ring. The ring's own glyph (an SF Symbol with the
    // ring's stroke weight) fades in over the system icon on the way.
    CGPoint home = CGPointMake(c.x, c.y - ring.centerLift);
    CGFloat rawCenter = p.parts[DLIFoldPartCenter];
    CGFloat xc = DLIClamp(rawCenter);
    BOOL glyph = in->vectorSize.width > 0 && in->vectorSize.height > 0;
    if (!in->hasCenter && in->phantomCenter) {
        if (glyph) out.vector = (DLISnapshotState){home, 1, 1, xc};
    } else if (in->hasCenter) {
        DLIItemState s = in->center;
        // The ring's glyph is drawn at full strength from the start, under the system
        // icon; the icon's snapshot on top fades out early (in on the way back).
        CGFloat fade = DLIEaseInOut(xc / 0.25);
        // Inside the ring the center is as large as the ring's glyph, or 9 % larger than
        // the system icon when there is none.
        CGFloat endScaleX = glyph ? in->vectorSize.width / MAX(s.size.width, 1) : ring.centerScale;
        CGFloat endScaleY = glyph ? in->vectorSize.height / MAX(s.size.height, 1) : ring.centerScale;
        if (crossfade) {
            out.center = (DLISnapshotState){home, endScaleX, endScaleY, glyph ? 0 : xc};
            if (glyph) out.vector = (DLISnapshotState){home, 1, 1, xc};
        } else {
            CGPoint position = DLILerpPoint(s.position, home, rawCenter);
            CGFloat alpha = DLILerp(s.alpha, 1, xc);
            out.center.position = position;
            out.center.scaleX = MAX(0.05, DLILerp(s.scaleX, endScaleX, rawCenter));
            out.center.scaleY = MAX(0.05, DLILerp(s.scaleY, endScaleY, rawCenter));
            out.center.alpha = glyph ? s.alpha * (1 - fade) : alpha;
            if (glyph) {
                // Same footprint as the snapshot at every moment.
                out.vector.position = position;
                out.vector.scaleX = out.center.scaleX * s.size.width / in->vectorSize.width;
                out.vector.scaleY = out.center.scaleY * s.size.height / in->vectorSize.height;
                out.vector.alpha = alpha;
            }
        }
    }

    // The battery squeezes into a dot at the arc's seed point, then the arc grows out of
    // it clockwise and counterclockwise until it spans 240 degrees around the top (the
    // timeline never moves the two at once).
    if (in->hasBattery) {
        DLIItemState b = in->battery;
        CGFloat rawArc = p.parts[DLIFoldPartArc];
        CGFloat x = DLIClamp(p.parts[DLIFoldPartBattery]);
        CGFloat arc = rawArc;
        // The spring itself eases out; another curve on top would make it S-shaped.
        CGFloat e = x;
        CGFloat lw = ring.lineWidth;
        CGPoint seed = DLIRingPoint(c, ring.radius, DLIFoldArcSeedAngle);
        CGRect body = CGRectIsEmpty(in->batteryBody) ? (CGRect){CGPointZero, b.size} : in->batteryBody;
        CGPoint bodyCenter = CGPointMake(b.position.x + (CGRectGetMidX(body) - b.size.width / 2) * b.scaleX,
                                         b.position.y + (CGRectGetMidY(body) - b.size.height / 2) * b.scaleY);
        CGSize bodySize = CGSizeMake(body.size.width * b.scaleX, body.size.height * b.scaleY);
        if (!crossfade) {
            CGFloat w = MAX(b.size.width, 1), h = MAX(b.size.height, 1);
            out.battery.position = DLILerpPoint(b.position, seed, e);
            out.battery.scaleX = DLILerp(b.scaleX, lw / w, e);
            out.battery.scaleY = DLILerp(b.scaleY, lw / h, e);
            out.battery.alpha = b.alpha * (1 - DLIEaseInOut(x / 0.45));
            out.capsule.position = DLILerpPoint(bodyCenter, seed, e);
            out.capsule.size = CGSizeMake(DLILerp(bodySize.width, lw, e), DLILerp(bodySize.height, lw, e));
            CGFloat corner = DLILerp(in->batteryBodyCornerRadius * MIN(b.scaleX, b.scaleY), lw / 2, e);
            out.capsule.cornerRadius = MIN(corner, MIN(out.capsule.size.width, out.capsule.size.height) / 2);
            out.capsule.alpha = DLIEaseInOut(x / 0.3) * DLILerp(b.alpha, 1, e);
            out.capsuleFillFraction = DLIClamp(in->batteryLevel);
        }
        // An arc shorter than a third of its line width would draw as a stray dot (round
        // caps) - the tail of a spring settling at zero - so it is not drawn; the battery's
        // dot covers that range whenever there should be one.
        // Once the battery has left the seed the arc's last couple of points go too, so
        // no stub stays behind while it settles.
        CGFloat arcLength = (4 * M_PI / 3) * arc * ring.radius;
        BOOL stub = x < 0.98 && arc < 0.05;
        if (arc > 0 && !stub && (crossfade || arcLength >= ring.lineWidth / 3)) {
            CGFloat grow = crossfade ? 1 : arc;
            CGFloat mid = -M_PI_2 + (M_PI / 3) * (1 - grow);
            CGFloat half = (2 * M_PI / 3) * grow;
            CGFloat level = DLIClamp(in->batteryLevel);
            out.arcVisible = YES;
            out.arcStart = mid - half;
            out.arcEnd = mid + half;
            out.arcFillEnd = out.arcStart + (out.arcEnd - out.arcStart) * level;
            out.arcAlpha = crossfade ? DLIClamp(rawArc) : 1;
            // A zero-length stroke draws nothing, so the dot stays until the arc is at
            // least one line width long and its round caps can take over.
            CGFloat fromSeed = hypot(out.capsule.position.x - seed.x, out.capsule.position.y - seed.y);
            if ((out.arcEnd - out.arcStart) * ring.radius >= lw && fromSeed < 1) out.capsule.alpha = 0;
        }
    }

    CGFloat eo = DLIClamp(p.parts[DLIFoldPartOthers]);
    out.othersAlpha = 1 - eo;
    out.othersScale = crossfade ? 1 : 1 - 0.2 * eo;
    return out;
}
