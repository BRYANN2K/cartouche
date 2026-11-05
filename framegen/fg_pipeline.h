// GPU side of frame generation: copies of the last two real frames, motion estimated
// between them, and the MetalFX interpolator that makes the frame in between.

#import <Metal/Metal.h>
#import <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

// What the test window can tune while a game runs
typedef struct {
	int block;          // block side for matching, in analysis pixels: 4, 8 or 16
	int radius;         // search radius, in analysis pixels, at most 31
	int factor;         // analysis runs at 1/factor of the frame size: 1, 2 or 4, or 0 to pick from the size
	int median;         // 3x3 median over block vectors
	int expand;         // 0 bilinear between blocks, 1 nearest block, 2 refined per pixel
	int zero;           // no motion at all
	int mode;           // 0 MetalFX, 1 50 % blend, 2 previous frame again, 3 motion view, 4 repair pass alone
	float bias;         // matching cost per pixel of distance
	float motionScale;  // multiplier on the vectors MetalFX gets, sign included
	float depth;        // the constant depth MetalFX gets
	int depthReversed;
	int realDeltaTime;  // 1: the measured interval, 0: zero
	int resetEvery;     // reset MetalFX's history on every frame
	int estimator;      // 0 block matching, 1 coarse-to-fine on a luma pyramid
	int still;          // pixels that did not change keep no motion
	int check;          // pyramid only: forward and backward vectors must agree; 1 full search back, 2 short one
	int cuts;           // a scene cut repeats the last frame instead of interpolating
	int downscale;      // MetalFX works at 1/downscale of the frame size: 1 or 2, or 0 to pick from the size
	int repair;         // replace MetalFX's pixels where a trusted reconstruction disagrees
	int hud;            // pixels unchanged for this many real frames come from the last one, 0 off
	int engine;         // use the game's own motion vectors when its upscaler hands them over
	int overlay;        // a green square in the top-left corner of each generated frame
} FGSettings;

// The repair pass's thresholds, see repair_frame in kernels.metal
typedef struct {
	float sigma, farLo, farHi, sureLo, sureHi, reach;
	float occlusion, flows; // with the Neural Engine: its mask in the mix, its flows as a candidate
} FGRepair;

FOUNDATION_EXPORT FGRepair FGDefaultRepair(void);

FOUNDATION_EXPORT FGSettings FGDefaultSettings(void);

// Set while the pipeline creates its own interpolator, so the hook can tell the runner's apart
FOUNDATION_EXPORT _Atomic int FGCreatingInterpolator;

API_AVAILABLE(macos(26.0))
@interface FGPipeline : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) MTLPixelFormat format;
@property (nonatomic, readonly) FGSettings settings;
// Reduced-size luma of the last capture, for tests
@property (nonatomic, readonly) id<MTLTexture> luma;
// Block vectors from the last motion pass, for tests
@property (nonatomic, readonly) id<MTLTexture> blockVectors;
// Tests only: motion and depth to hand the interpolator in place of the estimated ones
@property (nonatomic, strong, nullable) id<MTLTexture> motionOverride, depthOverride;
// The Neural Engine's flows for this pair, see FGNeural.flow; used in place of the estimate
@property (nonatomic, strong, nullable) id<MTLTexture> neuralFlow;
// Its blend mask for the same pair, see FGNeural.mask: the repair pass's occlusion prior
@property (nonatomic, strong, nullable) id<MTLTexture> neuralMask;
// Writes a frame at the network's size into one of FGNeural's input textures
- (void)encodeNeuralInput:(id<MTLTexture>)frame into:(id<MTLTexture>)planes commandBuffer:(id<MTLCommandBuffer>)buffer;
// The game's motion vectors, copied from its upscaler's inputs: in its pixels, pointing back
@property (nonatomic, strong, nullable) id<MTLTexture> engineMotion;
@property (nonatomic) float engineMotionScale;
// Tests only: the repair thresholds in use
@property (nonatomic) FGRepair repairTuning;
// Tests only: the MetalFX interpolator, to set its camera values
@property (nonatomic, readonly, nullable) id interpolator;
// Tests only: where the generated frame sits for the repair pass, 0 previous to 1 last (0.5)
@property (nonatomic) float phase;
// The UI of the next capture when the source keeps it apart, at the frame's size: premultiplied, or
// with uiComposited the final frame. Copied at capture. docs/FRAME-GENERATION.md, HUD.
@property (nonatomic, strong, nullable) id<MTLTexture> uiTexture;
@property (nonatomic) BOOL uiComposited;
// Tests only: MetalFX gets the UI too, when it works at full size and the UI was set before
// prepareWidth (its format goes in the descriptor); and no previous colour (macOS 27)
@property (nonatomic) BOOL uiToMetalFX, noPrevColor;
// The last finished repair pass: mean trust in the reconstruction (0 to 1) and share of pixels
// replaced (0 to 1). Frames in flight share the counters, so this is a sample, not exact.
- (void)repairConfidence:(double *)confidence replaced:(double *)replaced;
// The generated frame after encodeFrame:
@property (nonatomic, readonly) id<MTLTexture> output;

+ (BOOL)supportsDevice:(id<MTLDevice>)device;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device error:(NSString *_Nullable *_Nullable)error;
// Builds the textures and the interpolator for one size and format; frees the old ones
- (BOOL)prepareWidth:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format
               error:(NSString *_Nullable *_Nullable)error;
// New settings: recompiles the search or rebuilds the textures when they need it
- (BOOL)useSettings:(FGSettings)settings error:(NSString *_Nullable *_Nullable)error;
// Copies a real frame in. Returns NO when there is no earlier frame to interpolate from.
- (BOOL)encodeCapture:(id<MTLTexture>)frame commandBuffer:(id<MTLCommandBuffer>)buffer;
// Motion from the previous capture to the last one
- (void)encodeMotion:(id<MTLCommandBuffer>)buffer;
// Motion, then the frame half way between the previous capture and the last one, into output
- (void)encodeFrame:(id<MTLCommandBuffer>)buffer deltaTime:(float)deltaTime;
// Up to three generated frames, one MetalFX pass at the middle then a repair pass at each phase (0
// previous to 1 last); the frames go to outputAt:0, 1, 2. One frame only without the repair pass.
- (void)encodeFrames:(id<MTLCommandBuffer>)buffer deltaTime:(float)deltaTime phases:(const float *)phases count:(int)count;
- (id<MTLTexture>)outputAt:(int)index;
// Forget the previous frame, after a pause or a cut
- (void)reset;

@end

NS_ASSUME_NONNULL_END
