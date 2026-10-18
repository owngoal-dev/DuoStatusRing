#import <UIKit/UIKit.h>

// The ring's Wi-Fi glyph, drawn by hand in the status bar icon's proportions (measured
// from the system icon: a 90 degree fan of a wedge and two bands with equal gaps, ends
// cut along the fan's edges, slightly rounded corners) with a 2.35 pt line instead of the
// icon's 2.8 pt, at the design's size. Each band and the "lost" slash are layers of their own,
// so a signal change fades the bands and losing the connection draws the slash in
// (cutting its gap through the bands as it goes) instead of swapping pictures.

FOUNDATION_EXTERN const CGFloat DLIWifiGlyphLineWidth;

@interface DLIWifiGlyphLayer : CALayer
// Size of the glyph for a 37 pt island; the fold scales it with the island.
+ (CGSize)glyphSize;
// bars: lit bands (0-3); lost: no connection at all, every band dim and slashed.
- (void)setBars:(NSInteger)bars lost:(BOOL)lost color:(UIColor *)color dimAlpha:(CGFloat)dimAlpha animated:(BOOL)animated;
@end
