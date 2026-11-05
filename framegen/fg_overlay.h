// Cartouche's in-game HUD: the menu's HUD (Mini, Standard, Complet) in a corner with the numbers of
// fg_metrics.h, drawn over each shown frame as the last pass before its present, after upscaling and
// generation. CARTOUCHE_OVERLAY=off|mini|std|full (off by default), CARTOUCHE_OVERLAY_POS=tl|tr|bl|br.
// CARTOUCHE_OVERLAY_LANG=en|fr names its labels. CARTOUCHE_OVERLAY_CONTROL=1 keeps it ready when off, for the app's control block (fg_control_shm.h),
// which then sets level, corner, size and the warning capsule live.

#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, FGOverlayLevel) { FGOverlayOff, FGOverlayMini, FGOverlayStandard, FGOverlayFull };
typedef NS_ENUM(int, FGOverlayCorner) { FGOverlayTopLeft, FGOverlayTopRight, FGOverlayBottomLeft, FGOverlayBottomRight };

// NO for a word it does not know; NULL or empty gives off and top right
FOUNDATION_EXPORT BOOL FGOverlayParseLevel(const char *_Nullable text, FGOverlayLevel *level);
FOUNDATION_EXPORT BOOL FGOverlayParseCorner(const char *_Nullable text, FGOverlayCorner *corner);
// The HUD's labels: "fr…" is French, anything else English; NULL or empty reads the Mac's language
FOUNDATION_EXPORT BOOL FGOverlayFrench(const char *_Nullable language);

@interface FGOverlay : NSObject

@property (atomic) FGOverlayLevel level;
@property (atomic) FGOverlayCorner corner;
// 100, 125 or 150
@property (atomic) int sizePercent;
// Whether the app's control block is read
@property (atomic, readonly) BOOL controlled;
// Tests only: the clock in seconds when above 0
@property (atomic) double testTime;

// From the variables; nil when off or wrong, with a line in log
+ (nullable instancetype)overlayFromEnvironment:(id<MTLDevice>)device log:(void (*)(const char *format, ...))log;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device level:(FGOverlayLevel)level corner:(FGOverlayCorner)corner
                                  error:(NSString *_Nullable *_Nullable)error;
// Over texture, which must allow rendering; scale is its pixels per point. Skipped, never
// waited for, when its buffers are all in flight.
- (void)encodeOnto:(id<MTLTexture>)texture scale:(double)scale commandBuffer:(id<MTLCommandBuffer>)buffer;
// The panel on a target of that size, in its pixels from the top left, as last drawn
- (CGRect)panelForWidth:(NSUInteger)width height:(NSUInteger)height scale:(double)scale;
// Every pixel the last pass may touch: the panel, its shadow and the warning capsule
- (CGRect)boundsForWidth:(NSUInteger)width height:(NSUInteger)height scale:(double)scale;

@end

NS_ASSUME_NONNULL_END
