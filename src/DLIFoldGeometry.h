#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// Where every piece of the folded status bar is drawn, as a pure function of the
// live status bar items and the per-part progress from DLIFoldTimeline. No UIKit, so
// the same code renders offline frames on the Mac for comparison with the design.
//
// Coordinates are the status bar's foreground view (points, y down). Angles are in
// radians, clockwise on screen, 0 pointing right: the top of the ring is -pi/2.

#define DLI_MAX_BARS 4

typedef struct {
    CGPoint position; // center, in status bar coordinates
    CGSize size;      // bounds size, before scaling
    CGFloat scaleX;
    CGFloat scaleY;
    CGFloat alpha;
} DLIItemState;

typedef struct {
    CGRect frame;          // in the signal view's bounds coordinates
    CGFloat cornerRadius;
} DLIBarShape;

typedef struct {
    CGPoint center;
    CGFloat radius;        // center line of the battery arc
    CGFloat lineWidth;
    CGFloat dotRadius;     // circle the signal dots sit on
    CGFloat dotDiameter;
    CGFloat centerScale;   // the center glyph grows a little inside the ring
    CGFloat centerLift;    // the center glyph sits this much above the ring's center
    CGFloat scale;         // island height / 37 pt: everything else scales with it
} DLIRing;

typedef struct {
    DLIRing ring;
    NSInteger barCount;    // bars of the signal item; 0 draws four dim dots instead
    DLIItemState signal;
    DLIBarShape bars[DLI_MAX_BARS];
    BOOL hasCenter;
    DLIItemState center;
    BOOL phantomCenter;    // no center icon: a "lost" glyph fades in at the ring's center
    // The center is redrawn as the ring's own glyph (an SF Symbol whose stroke matches
    // the ring: Wi-Fi, or Wi-Fi slashed when lost); the system icon crossfades into it on
    // the way. Zero: snapshot only.
    CGSize vectorSize;
    BOOL hasBattery;
    DLIItemState battery;
    CGRect batteryBody;    // body (without the pin), in the battery's bounds coordinates
    CGFloat batteryBodyCornerRadius;
    CGFloat batteryLevel;  // 0...1
    // The signal bars' live opacity: the system hides them when a wide island needs the
    // room, and then the dots fade in place instead of growing out of nothing.
} DLIFoldInput;

typedef struct {
    CGFloat parts[8];      // indexed by DLIFoldPart
} DLIFoldProgress;

typedef struct {
    CGPoint position;
    CGSize size;
    CGFloat cornerRadius;
    CGFloat alpha;
} DLIShapeState;

typedef struct {
    CGPoint position;
    CGFloat scaleX;
    CGFloat scaleY;
    CGFloat alpha;
} DLISnapshotState;

typedef struct {
    NSInteger dotCount;
    DLIShapeState dots[DLI_MAX_BARS]; // bars turning into dots
    DLISnapshotState center;          // the system icon's snapshot
    DLISnapshotState vector;          // the ring's glyph that replaces it inside the ring
    DLISnapshotState battery;         // the real battery icon, squeezed and faded
    DLIShapeState capsule;            // battery body shrinking into the arc's first point
    CGFloat capsuleFillFraction;      // left part in the fill color, the rest in the track color
    BOOL arcVisible;
    CGFloat arcStart;
    CGFloat arcEnd;
    CGFloat arcFillEnd;
    CGFloat arcAlpha;
    CGFloat othersAlpha;              // icons that do not join the ring
    CGFloat othersScale;
    BOOL crossfade;                   // Reduce Motion: show expanded snapshots at othersAlpha
} DLIFoldOutput;

FOUNDATION_EXTERN CGFloat DLIEaseInOut(CGFloat x);
FOUNDATION_EXTERN CGPoint DLIRingPoint(CGPoint center, CGFloat radius, CGFloat angle);
// Ring sized by the island height (design: 37 pt island, 17 pt arc radius, 2.3 pt line).
// cluster is the union of the trailing items in their normal layout; bubbleMaxX the
// right edge of the mitosis bubble; width the status bar width.
FOUNDATION_EXTERN DLIRing DLIFoldRingMake(CGRect island, CGRect cluster, CGFloat bubbleMaxX, CGFloat width);
// Right edge of the minimal bubble native mitosis places next to the island.
FOUNDATION_EXTERN CGFloat DLIFoldBubbleMaxX(CGRect island);
FOUNDATION_EXTERN DLIFoldOutput DLIFoldEvaluate(const DLIFoldInput *input, DLIFoldProgress progress, BOOL crossfade);
// Angle of the battery dot where the arc starts growing.
FOUNDATION_EXTERN const CGFloat DLIFoldArcSeedAngle;
