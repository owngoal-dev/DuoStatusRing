#import "DLIWifiGlyphLayer.h"

const CGFloat DLIWifiGlyphLineWidth = 2.35;

// Sized to the design's ring glyph (16 x 12 pt on a 37 pt island).
static const CGFloat DLIWifiGap = 1.9;
static const CGFloat DLIWifiWedge = 3.8;
static const CGFloat DLIWifiCorner = 0.55;
static const CGFloat DLIWifiSlashClearance = 1.2; // gap cut on each side of the slash

static CGFloat DLIWifiOuterRadius(void) {
    return DLIWifiWedge + 2 * DLIWifiGap + 2 * DLIWifiGlyphLineWidth;
}

// One band of the fan between two radii (0 inner: the wedge), shrunk by the corner
// radius on every side; filled and stroked two corner radii wide with round joins it
// has exactly the requested extent and rounded corners.
static CGPathRef DLIWifiBandPath(CGPoint apex, CGFloat inner, CGFloat outer) {
    CGFloat corner = DLIWifiCorner, half = M_PI_4;
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat ro = outer - corner;
    CGFloat ao = half - corner / ro;
    [path addArcWithCenter:apex radius:ro startAngle:-M_PI_2 - ao endAngle:-M_PI_2 + ao clockwise:YES];
    if (inner <= 0) {
        // The wedge's tip moves up so the rounded tip still touches the apex.
        [path addLineToPoint:CGPointMake(apex.x, apex.y - corner / sin(half))];
    } else {
        CGFloat ri = inner + corner;
        CGFloat ai = half - corner / ri;
        [path addArcWithCenter:apex radius:ri startAngle:-M_PI_2 + ai endAngle:-M_PI_2 - ai clockwise:NO];
    }
    [path closePath];
    return CGPathRetain(path.CGPath);
}

// Outside rectangle plus a capsule from a to a + t (b - a) with radius t * r. The control
// points are linear in t, so Core Animation interpolating between t = 0 and t = 1 passes
// through every t in between, in step with the slash's strokeEnd.
static CGPathRef DLIWifiGapPath(CGRect bounds, CGPoint a, CGPoint b, CGFloat r, CGFloat t) {
    t = MAX(t, 0.001);
    CGPoint p = CGPointMake(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
    CGFloat radius = r * t;
    CGFloat angle = atan2(b.y - a.y, b.x - a.x);
    CGPoint n = CGPointMake(-sin(angle) * radius, cos(angle) * radius);
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:CGRectInset(bounds, -4, -4)];
    [path moveToPoint:CGPointMake(a.x + n.x, a.y + n.y)];
    [path addLineToPoint:CGPointMake(p.x + n.x, p.y + n.y)];
    [path addArcWithCenter:p radius:radius startAngle:angle + M_PI_2 endAngle:angle - M_PI_2 clockwise:NO];
    [path addLineToPoint:CGPointMake(a.x - n.x, a.y - n.y)];
    [path addArcWithCenter:a radius:radius startAngle:angle - M_PI_2 endAngle:angle + M_PI_2 clockwise:NO];
    [path closePath];
    return CGPathRetain(path.CGPath);
}

@implementation DLIWifiGlyphLayer {
    CALayer *_bandsLayer;
    CAShapeLayer *_bands[3];
    CAShapeLayer *_gap;
    CAShapeLayer *_slash;
    CGPoint _slashStart;
    CGPoint _slashEnd;
    BOOL _configured;
    BOOL _lost;
    NSInteger _bars;
    UIColor *_color;
    CGFloat _dimAlpha;
}

+ (CGSize)glyphSize {
    CGFloat outer = DLIWifiOuterRadius();
    return CGSizeMake(ceil(2 * outer * sin(M_PI_4) * 2 + 1) / 2, ceil(outer * 2 + 1) / 2);
}

- (instancetype)init {
    if ((self = [super init])) {
        CGSize size = [DLIWifiGlyphLayer glyphSize];
        self.bounds = (CGRect){CGPointZero, size};
        CGPoint apex = CGPointMake(size.width / 2, size.height - 0.25);
        CGFloat outer = DLIWifiOuterRadius();
        CGFloat line = DLIWifiGlyphLineWidth;

        _bandsLayer = [CALayer layer];
        _bandsLayer.frame = self.bounds;
        [self addSublayer:_bandsLayer];
        CGFloat radii[3][2] = {{0, DLIWifiWedge}, {DLIWifiWedge + DLIWifiGap, DLIWifiWedge + DLIWifiGap + line},
            {DLIWifiWedge + 2 * DLIWifiGap + line, outer}};
        for (NSInteger i = 0; i < 3; i++) {
            CAShapeLayer *band = [CAShapeLayer layer];
            band.frame = self.bounds;
            CGPathRef path = DLIWifiBandPath(apex, radii[i][0], radii[i][1]);
            band.path = path;
            CGPathRelease(path);
            band.lineWidth = DLIWifiCorner * 2;
            band.lineJoin = kCALineJoinRound;
            [_bandsLayer addSublayer:band];
            _bands[i] = band;
        }

        // Corner to corner of the fan, round caps included, nothing outside the glyph.
        _slashStart = CGPointMake(apex.x - outer * 0.52, line / 2 + 0.4);
        _slashEnd = CGPointMake(apex.x + outer * 0.52, apex.y - line / 2 - 0.2);
        _gap = [CAShapeLayer layer];
        _gap.frame = self.bounds;
        _gap.fillRule = kCAFillRuleEvenOdd;
        _gap.fillColor = UIColor.blackColor.CGColor;
        CGPathRef gap = DLIWifiGapPath(self.bounds, _slashStart, _slashEnd, line / 2 + DLIWifiSlashClearance, 0);
        _gap.path = gap;
        CGPathRelease(gap);
        _bandsLayer.mask = _gap;

        _slash = [CAShapeLayer layer];
        _slash.frame = self.bounds;
        UIBezierPath *slash = [UIBezierPath bezierPath];
        [slash moveToPoint:_slashStart];
        [slash addLineToPoint:_slashEnd];
        _slash.path = slash.CGPath;
        _slash.fillColor = nil;
        _slash.lineWidth = line;
        _slash.lineCap = kCALineCapRound;
        _slash.strokeEnd = 0;
        [self addSublayer:_slash];
    }
    return self;
}

- (void)setBars:(NSInteger)bars lost:(BOOL)lost color:(UIColor *)color dimAlpha:(CGFloat)dimAlpha animated:(BOOL)animated {
    if (_configured && bars == _bars && lost == _lost && dimAlpha == _dimAlpha && [color isEqual:_color]) return;
    _bars = bars;
    _color = color;
    _dimAlpha = dimAlpha;
    BOOL animate = animated && _configured;
    _configured = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:!animate];
    [CATransaction setAnimationDuration:0.3];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    for (NSInteger i = 0; i < 3; i++) {
        _bands[i].fillColor = color.CGColor;
        _bands[i].strokeColor = color.CGColor;
        _bands[i].opacity = (!lost && i < bars) ? 1 : dimAlpha;
    }
    _slash.strokeColor = color.CGColor;
    _slash.opacity = 0.85; // the strongest mark, but not brighter than the ring
    if (lost != _lost || !animate) {
        // The slash draws from its top end down and retracts the same way; the gap in
        // the bands follows its tip.
        [CATransaction setAnimationDuration:lost ? 0.4 : 0.3];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:lost ? kCAMediaTimingFunctionEaseOut
                                                                                               : kCAMediaTimingFunctionEaseIn]];
        _slash.strokeEnd = lost ? 1 : 0;
        CGPathRef gap = DLIWifiGapPath(self.bounds, _slashStart, _slashEnd, DLIWifiGlyphLineWidth / 2 + DLIWifiSlashClearance,
                                       lost ? 1 : 0);
        _gap.path = gap;
        CGPathRelease(gap);
    }
    _lost = lost;
    [CATransaction commit];
}

@end
