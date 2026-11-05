// Upscaling for games that render below the screen's size: Cartouche's Wine runs games without
// Retina mode, so they render in points and the window server doubles them on a Retina screen.
// FGUpscaler brings a frame up to the output size with CMAA2, MetalFX's spatial scaler and RCAS
// (any of them can be off); FGUpscale shows the result in a layer of ours over the game's, at the
// screen's size, so the window, the game's layer and the mouse stay as they are.

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
	int cmaa;        // CMAA2 on the game's frame before scaling
	int metalfx;     // MetalFX's spatial scaler; bilinear when 0
	float sharpness; // RCAS after scaling, in stops (0 the sharpest); off when negative
} FGUpscaleSettings;

// "chain" (cmaa2+metalfx), "metalfx", "bilinear", "bilinear+rcas=0.5"...: the parts joined by "+";
// rcas takes its stops after "=", 2 without. NO for a word it does not know.
FOUNDATION_EXPORT BOOL FGUpscaleParse(const char *text, FGUpscaleSettings *settings);

@interface FGUpscaler : NSObject

@property (nonatomic, readonly) FGUpscaleSettings settings;
// What runs: MetalFX can refuse a size or format, and bilinear stands in
@property (nonatomic, readonly) BOOL metalfxInUse;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device settings:(FGUpscaleSettings)settings
                                  error:(NSString *_Nullable *_Nullable)error;
// From a frame of this size and format to an output of that size and format; frees the old ones
- (BOOL)prepareInputWidth:(NSUInteger)inputWidth height:(NSUInteger)inputHeight format:(MTLPixelFormat)inputFormat
              outputWidth:(NSUInteger)outputWidth height:(NSUInteger)outputHeight format:(MTLPixelFormat)outputFormat
                    error:(NSString *_Nullable *_Nullable)error;
// output must allow rendering; input is only read
- (void)encode:(id<MTLTexture>)input to:(id<MTLTexture>)output commandBuffer:(id<MTLCommandBuffer>)buffer;
@end

// The one RCAS: from input into output of the same size, on an open encoder (a temporal scaler's
// fence can wrap it), stops 0 the sharpest; hdr for float colour. NO if the kernel failed.
FOUNDATION_EXPORT BOOL FGSharpen(id<MTLComputeCommandEncoder> encoder, id<MTLTexture> input, id<MTLTexture> output,
                                 float stops, BOOL hdr);
// The same RCAS on a Metal 4 encoder: textures through table, its 8 bytes of settings written at
// params, which stays until the GPU is done with it
API_AVAILABLE(macos(26.0))
FOUNDATION_EXPORT BOOL FGSharpen4(id<MTL4ComputeCommandEncoder> encoder, id<MTL4ArgumentTable> table, id<MTLTexture> input,
                                  id<MTLTexture> output, float stops, BOOL hdr, id<MTLBuffer> params, NSUInteger offset);
// A compute pipeline of upscale.metal, made once per device
FOUNDATION_EXPORT id<MTLComputePipelineState> _Nullable FGUpscaleKernel(id<MTLDevice> device, NSString *name);

API_AVAILABLE(macos(26.0))
@interface FGUpscale : NSObject

// From CARTOUCHE_FRAMEGEN_UPSCALE; nil when it is unset or wrong
+ (nullable instancetype)upscaleForLayer:(CAMetalLayer *)layer device:(id<MTLDevice>)device;
// Our layer's drawable for a frame of the game's, filled from texture in buffer; nil when the
// frame is already at the screen's size, or before our layer is up
- (nullable id<CAMetalDrawable>)drawableFrom:(id<MTLTexture>)texture commandBuffer:(id<MTLCommandBuffer>)buffer;
// An empty drawable of our layer for a generated frame, and how to fill it; nil as above. fits says
// whether our layer shows this frame: then nil means late, not the game's layer.
- (nullable id<CAMetalDrawable>)nextDrawableFor:(id<MTLTexture>)texture fits:(nullable BOOL *)fits;
- (void)encode:(id<MTLTexture>)texture into:(id<CAMetalDrawable>)drawable commandBuffer:(id<MTLCommandBuffer>)buffer;
// Our layer comes down and the game's shows again
- (void)stop;

@end

// upscale.metal compiled for device, once per device
FOUNDATION_EXPORT id<MTLLibrary> _Nullable FGUpscaleLibrary(id<MTLDevice> device, NSError *_Nullable *_Nullable error);

// The library turned itself off: every layer of ours comes down
FOUNDATION_EXPORT void FGUpscaleStopAll(void);

// Tests only (CARTOUCHE_FRAMEGEN_DUMP=<file.ppm>[:<first>[:<every>]]): the shown image of real
// frame number first, then of every every-th one after it, written to file; a %ld in the name
// takes the frame's number, else the last one stays
FOUNDATION_EXPORT void FGDumpShown(id<MTLTexture> texture, id<MTLCommandBuffer> buffer);

NS_ASSUME_NONNULL_END
