#import "DLIFoldTimeline.h"

typedef struct {
    double delay;    // seconds after the request; only parts starting from rest wait
    double response; // spring period as SBFFluidBehaviorSettings defines it, or tween length
    double damping;  // damping ratio (1 or more: critically damped); 0: linear tween of `response` s
    double kick;     // speed toward the target when starting from rest (progress per second)
} DLIFoldMotion;

// Folding (design clip 2, split at 1.10 s): icons that leave fade first, the battery
// squeezes into a dot, the Wi-Fi glyph heads for the center, the bars fall right to
// left, and the arc grows last. Springs a little under critical damping give the parts
// a slight bounce as they land.
static DLIFoldMotion DLIFoldMotionFor(DLIFoldPart part, BOOL folding, BOOL crossfade) {
    if (crossfade) return (DLIFoldMotion){0, 0.2, 0, 0};
    if (folding) {
        // Fitted to the design frames (fold of clip 2): the arc pops out of the dot with
        // some speed and settles with a slight bounce.
        switch (part) {
            case DLIFoldPartOthers: return (DLIFoldMotion){0.00, 0.24, 1.0, 0};
            case DLIFoldPartBattery: return (DLIFoldMotion){0.05, 0.30, 0.95, 0};
            case DLIFoldPartCenter: return (DLIFoldMotion){0.08, 0.44, 0.74, 0};
            case DLIFoldPartBar0: return (DLIFoldMotion){0.205, 0.50, 0.78, 0};
            case DLIFoldPartBar1: return (DLIFoldMotion){0.170, 0.50, 0.78, 0};
            case DLIFoldPartBar2: return (DLIFoldMotion){0.130, 0.50, 0.78, 0};
            case DLIFoldPartBar3: return (DLIFoldMotion){0.095, 0.50, 0.78, 0};
            case DLIFoldPartArc: return (DLIFoldMotion){0.235, 0.90, 0.80, 5};
            default: return (DLIFoldMotion){0, 0.3, 1, 0};
        }
    }
    // Unfolding (merge of clip 2): the arc retracts first, critically damped (a bounce at
    // zero would bring a sliver of it back), the dots climb back into bars left to right,
    // and the battery drops out of the dot last, easing out.
    switch (part) {
        case DLIFoldPartArc: return (DLIFoldMotion){0.075, 0.36, 1.0, 0};
        case DLIFoldPartBar0: return (DLIFoldMotion){0.12, 0.42, 0.78, 0};
        case DLIFoldPartBar1: return (DLIFoldMotion){0.15, 0.42, 0.78, 0};
        case DLIFoldPartBar2: return (DLIFoldMotion){0.18, 0.42, 0.78, 0};
        case DLIFoldPartBar3: return (DLIFoldMotion){0.21, 0.42, 0.78, 0};
        case DLIFoldPartCenter: return (DLIFoldMotion){0.19, 0.44, 0.78, 0};
        case DLIFoldPartBattery: return (DLIFoldMotion){0.365, 0.88, 0.80, 6};
        case DLIFoldPartOthers: return (DLIFoldMotion){0.50, 0.26, 1.0, 0};
        default: return (DLIFoldMotion){0, 0.3, 1, 0};
    }
}

typedef struct {
    double start;  // when the motion begins
    double end;    // from here on the part sits exactly on its target
    double p0;     // state at start
    double v0;
    double target;
    DLIFoldMotion motion;
} DLIFoldSegment;

// Closed-form damped spring (or tween) from (p0, v0) toward target.
static void DLIFoldSegmentEvaluate(const DLIFoldSegment *s, double t, double *p, double *v) {
    if (t >= s->end) {
        *p = s->target;
        *v = 0;
        return;
    }
    if (t <= s->start) {
        *p = s->p0;
        *v = s->v0;
        return;
    }
    double tau = t - s->start;
    double x0 = s->p0 - s->target;
    if (s->motion.damping <= 0) {
        double rate = -x0 / s->motion.response;
        *p = s->p0 + rate * tau;
        *v = rate;
        return;
    }
    double omega = 2 * M_PI / s->motion.response;
    double zeta = s->motion.damping;
    if (zeta < 1) {
        double a = zeta * omega, b = omega * sqrt(1 - zeta * zeta);
        double e = exp(-a * tau), c = cos(b * tau), sn = sin(b * tau);
        double B = (s->v0 + a * x0) / b;
        *p = s->target + e * (x0 * c + B * sn);
        *v = e * (s->v0 * c - (a * s->v0 + omega * omega * x0) / b * sn);
    } else {
        double C = s->v0 + omega * x0;
        double e = exp(-omega * tau);
        *p = s->target + e * (x0 + C * tau);
        *v = e * (s->v0 - omega * C * tau);
    }
}

// Time after which the remaining motion is below 1e-3 of the full travel (0.04 pt on
// the longest path), so the display link stops as soon as nothing visibly moves.
static double DLIFoldSegmentEnd(const DLIFoldSegment *s) {
    double x0 = fabs(s->p0 - s->target);
    if (x0 < 1e-9 && fabs(s->v0) < 1e-9) return s->start;
    if (s->motion.damping <= 0) return s->start + s->motion.response;
    double omega = 2 * M_PI / s->motion.response;
    double a = MIN(s->motion.damping, 1) * omega;
    double magnitude = x0 + fabs(s->v0) / omega;
    // The critically damped envelope carries a (1 + omega t) factor: allow for it.
    double margin = s->motion.damping >= 1 ? 1.25 : 1.0;
    return s->start + margin * log(MAX(magnitude, 1e-3) / 1e-3) / a;
}

// From when on the segment stays within `band` of its target. A part reversed with
// momentum can start inside the band and still swing out of it first.
static double DLIFoldSegmentArrival(const DLIFoldSegment *s, double band) {
    double arrival = s->start;
    for (double t = s->start; t < s->end; t += 0.004) {
        double p, v;
        DLIFoldSegmentEvaluate(s, t, &p, &v);
        if (fabs(p - s->target) >= band) arrival = t + 0.004;
    }
    return MIN(arrival, s->end);
}

// A part's motion: one segment, or two when it has to wait for another part first (it
// heads for its waiting place now and leaves for its target at `switchAt`, carrying the
// position and velocity it has there).
typedef struct {
    DLIFoldSegment first;
    DLIFoldSegment second;
    double switchAt;
    BOOL queued;
} DLIFoldTrack;

static void DLIFoldTrackEvaluate(const DLIFoldTrack *k, double t, double *p, double *v) {
    if (k->queued && t >= k->switchAt) DLIFoldSegmentEvaluate(&k->second, t, p, v);
    else DLIFoldSegmentEvaluate(&k->first, t, p, v);
}

static double DLIFoldTrackEnd(const DLIFoldTrack *k) {
    return k->queued ? MAX(k->second.end, k->switchAt) : k->first.end;
}

static double DLIFoldTrackTarget(const DLIFoldTrack *k) {
    return k->queued ? k->second.target : k->first.target;
}

static DLIFoldSegment DLIFoldSegmentMake(double start, double p0, double v0, double target, DLIFoldMotion motion) {
    DLIFoldSegment s = {start, 0, p0, v0, target, motion};
    if (fabs(p0 - target) < 1e-9 && fabs(v0) < 1e-9) {
        s.p0 = target;
        s.end = start;
    } else {
        s.end = DLIFoldSegmentEnd(&s);
    }
    return s;
}

@implementation DLIFoldTimeline {
    DLIFoldTrack _tracks[DLIFoldPartCount];
}

- (instancetype)init {
    if ((self = [super init])) {
        _timeScale = 1;
        for (NSInteger i = 0; i < DLIFoldPartCount; i++)
            _tracks[i].first = DLIFoldSegmentMake(0, 0, 0, 0, DLIFoldMotionFor(i, NO, NO));
    }
    return self;
}

- (double)progressOfPart:(DLIFoldPart)part atTime:(CFTimeInterval)time {
    if (part < 0 || part >= DLIFoldPartCount) return 0;
    double p, v;
    DLIFoldTrackEvaluate(&_tracks[part], time, &p, &v);
    return p;
}

- (double)velocityOfPart:(DLIFoldPart)part atTime:(CFTimeInterval)time {
    if (part < 0 || part >= DLIFoldPartCount) return 0;
    double p, v;
    DLIFoldTrackEvaluate(&_tracks[part], time, &p, &v);
    return v;
}

- (void)setFolded:(BOOL)folded atTime:(CFTimeInterval)time animated:(BOOL)animated {
    if (folded == _folded && animated) return;
    _folded = folded;
    // Morph or crossfade is chosen when everything is at rest; a transition that is
    // turned around keeps its kind even if Reduce Motion changed meanwhile.
    if (!animated || ![self isAnimatingAtTime:time]) _crossfading = animated && _reduceMotion;
    double scale = _timeScale > 0 ? _timeScale : 1;
    double target = folded ? 1 : 0;
    // The arc grows out of the battery's dot and goes back into it, so the one that
    // follows waits until the other is done: folding, the arc waits (at 0) for the
    // battery; unfolding, the battery waits (as a dot, at 1) for the arc. Leaders are
    // planned first.
    DLIFoldPart order[DLIFoldPartCount] = {DLIFoldPartOthers, DLIFoldPartCenter, DLIFoldPartBar0, DLIFoldPartBar1,
        DLIFoldPartBar2, DLIFoldPartBar3, folded ? DLIFoldPartBattery : DLIFoldPartArc,
        folded ? DLIFoldPartArc : DLIFoldPartBattery};
    for (NSInteger k = 0; k < DLIFoldPartCount; k++) {
        DLIFoldPart i = order[k];
        DLIFoldTrack *track = &_tracks[i];
        DLIFoldMotion motion = DLIFoldMotionFor(i, folded, _crossfading);
        motion.delay *= scale;
        motion.response *= scale;
        double p, v;
        DLIFoldTrackEvaluate(track, time, &p, &v);
        double oldTarget = DLIFoldTrackTarget(track);
        BOOL waiting = track->queued ? time < track->second.start : time < track->first.start;
        // A spring's tail is not motion anyone sees: a part within 2 % of its target and
        // barely moving counts as arrived and waits its turn like one at rest.
        BOOL settled = fabs(p - oldTarget) < 0.02 && fabs(v) < 0.2;
        BOOL resting = waiting || time >= DLIFoldTrackEnd(track) || settled;
        DLIFoldTrack next = {{0}, {0}, 0, NO};
        if (!animated) {
            next.first = DLIFoldSegmentMake(time, target, 0, target, motion);
        } else if (resting) {
            // From rest: wait for this part's turn in the new direction.
            double kick = fabs(p - target) > 1e-9 ? copysign(motion.kick, target - p) : 0;
            next.first = DLIFoldSegmentMake(time + motion.delay, p, kick, target, motion);
        } else {
            // In flight: turn around right away, keeping the momentum.
            next.first = DLIFoldSegmentMake(time, p, v, target, motion);
        }
        if (animated && k == DLIFoldPartCount - 1 && !_crossfading) {
            // Folding, the battery is visually a dot once 85 % there; unfolding, the arc
            // must be all but gone.
            double arrival = DLIFoldSegmentArrival(&_tracks[order[k - 1]].first, folded ? 0.15 : 0.03);
            if (arrival > next.first.start + 1e-6) {
                // The leader is not there yet: go to the waiting place with the momentum
                // there is, and leave for the target once the leader has arrived.
                double wait = folded ? 0 : 1;
                DLIFoldMotion hold = motion;
                hold.delay = 0;
                next.first = resting ? DLIFoldSegmentMake(time, p, 0, wait, hold) : DLIFoldSegmentMake(time, p, v, wait, hold);
                double p1, v1;
                DLIFoldSegmentEvaluate(&next.first, arrival, &p1, &v1);
                if (fabs(v1) < 1e-3 && fabs(p1 - wait) < 1e-3) v1 = copysign(motion.kick, target - wait);
                next.second = DLIFoldSegmentMake(MAX(arrival, time + motion.delay), p1, v1, target, motion);
                next.switchAt = arrival;
                next.queued = YES;
            }
        }
        *track = next;
    }
}

- (BOOL)isAnimatingAtTime:(CFTimeInterval)time {
    for (NSInteger i = 0; i < DLIFoldPartCount; i++) {
        if (time < DLIFoldTrackEnd(&_tracks[i])) return YES;
    }
    return NO;
}

- (BOOL)isRestingUnfoldedAtTime:(CFTimeInterval)time {
    return !_folded && ![self isAnimatingAtTime:time];
}

@end
