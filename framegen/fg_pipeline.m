#import "fg_pipeline.h"

#import <MetalFX/MetalFX.h>

#import "framegen_kernels.h"

typedef struct {
	float bias;
	float scale;
	uint32_t expand;
	uint32_t zero;
	uint32_t still;
} Motion;

typedef struct {
	int32_t radius;
	int32_t top;
	float bias;
} Level;

typedef struct {
	float sigma, farLo, farHi, sureLo, sureHi, reach, scale, factor, phase, occlusion, flows, own;
	float still, cuts;
} Repair;

enum { max_levels = 7 };

_Atomic int FGCreatingInterpolator;

FGRepair FGDefaultRepair(void)
{
	return (FGRepair){ .sigma = 0.04f, .farLo = 0.02f, .farHi = 0.06f, .sureLo = 0.08f, .sureHi = 0.2f, .reach = 16,
	                   .occlusion = 0, .flows = 1 };
}

FGSettings FGDefaultSettings(void)
{
	return (FGSettings){ .block = 16, .radius = 18, .factor = 0, .median = 1, .expand = 0, .zero = 0, .mode = 0,
	                     .bias = 0.02f, .motionScale = 1, .depth = 0.5f, .depthReversed = 0, .realDeltaTime = 1,
	                     .resetEvery = 0, .estimator = 1, .still = 1, .check = 1, .cuts = 1,
	                     .downscale = 0, .repair = 1, .hud = 4, .engine = 1 };
}

@implementation FGPipeline {
	NSString *_source;
	id<MTLCommandQueue> _setup;
	id<MTLComputePipelineState> _luma, _match, _median, _expand, _blend, _show;
	id<MTLComputePipelineState> _down, _lumaPyramid, _flow, _propagate, _check, _histogram, _cut, _fallback, _shrink, _grow,
		_repair, _repairWeights, _shrinkLuma, _stillCount, _keepStill, _uiOver,
		_engine, _aneInput, _aneMotion, _mark;
	id<MTLTexture> _pyramid[2][max_levels], _forward[max_levels], _backward[max_levels], _spare[max_levels], _checked,
		_filtered;
	int _levels;
	int _factor; // the analysis factor in use: the setting, or picked from the size when it is 0
	int _downscale; // the same for MetalFX's size
	id<MTLTexture> _small[2], _smallOutput; // MetalFX's own frames, the full ones when it works at full size
	id<MTLBuffer> _bins, _cutFlag, _repairCounts;
	id<MTLFXFrameInterpolator> _interpolator;
	id<MTLTexture> _frames[2], _luma2[2];
	id<MTLTexture> _vectors, _smooth, _motion, _depth, _output, _raw, _still[2], _weights[2], _none;
	int _passes; // repair passes in the last frame, which all add to the counters
	id<MTLTexture> _extra[2]; // outputs for the second and third generated frame, made on first use
	id<MTLTexture> _bare; // a generated frame before its UI goes on top, made on first use
	id<MTLTexture> _ui; // the UI of the last capture: the source may rewrite its own before we use it
	BOOL _haveUI;
	int _current;
	BOOL _havePrevious;
}

+ (BOOL)supportsDevice:(id<MTLDevice>)device
{
	return [MTLFXFrameInterpolatorDescriptor supportsDevice:device];
}

static id<MTLComputePipelineState> pipeline(id<MTLLibrary> library, NSString *name, NSString **error)
{
	id<MTLFunction> function = [library newFunctionWithName:name];
	NSError *failure = nil;
	id<MTLComputePipelineState> state = function != nil
		? [library.device newComputePipelineStateWithFunction:function error:&failure] : nil;
	if (state == nil && error != NULL)
		*error = [NSString stringWithFormat:@"kernel %@: %@", name, failure.localizedDescription ?: @"missing"];
	return state;
}

- (id<MTLLibrary>)libraryForBlock:(int)block radius:(int)radius error:(NSString **)error
{
	MTLCompileOptions *options = [MTLCompileOptions new];
	options.preprocessorMacros = @{ @"BLOCK": @(block), @"RADIUS": @(radius) };
	NSError *failure = nil;
	id<MTLLibrary> library = [_device newLibraryWithSource:_source options:options error:&failure];
	if (library == nil && error != NULL)
		*error = [NSString stringWithFormat:@"kernels: %@", failure.localizedDescription];
	return library;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSString **)error
{
	if ((self = [super init]) == nil)
		return nil;
	_device = device;
	_settings = FGDefaultSettings();
	_setup = [device newCommandQueue];
	_source = [[NSString alloc] initWithBytes:kernels_metal length:kernels_metal_len encoding:NSUTF8StringEncoding];
	id<MTLLibrary> library = [self libraryForBlock:_settings.block radius:_settings.radius error:error];
	if (library == nil)
		return nil;
	_luma = pipeline(library, @"luma_reduce", error);
	_match = _luma ? pipeline(library, @"block_match", error) : nil;
	_median = _match ? pipeline(library, @"median_blocks", error) : nil;
	_expand = _median ? pipeline(library, @"expand_motion", error) : nil;
	_blend = _expand ? pipeline(library, @"blend_frames", error) : nil;
	_show = _blend ? pipeline(library, @"show_motion", error) : nil;
	_down = _show ? pipeline(library, @"luma_down", error) : nil;
	_flow = _down ? pipeline(library, @"flow_level", error) : nil;
	_propagate = _flow ? pipeline(library, @"flow_propagate", error) : nil;
	_check = _propagate ? pipeline(library, @"flow_check", error) : nil;
	_histogram = _check ? pipeline(library, @"luma_histogram", error) : nil;
	_cut = _histogram ? pipeline(library, @"scene_cut", error) : nil;
	_fallback = _cut ? pipeline(library, @"cut_fallback", error) : nil;
	_shrink = _fallback ? pipeline(library, @"shrink_color", error) : nil;
	_grow = _shrink ? pipeline(library, @"grow_color", error) : nil;
	_lumaPyramid = _grow ? pipeline(library, @"luma_pyramid", error) : nil;
	_repair = _grow ? pipeline(library, @"repair_frame", error) : nil;
	_repairWeights = _repair ? pipeline(library, @"repair_weights", error) : nil;
	_shrinkLuma = _repairWeights ? pipeline(library, @"shrink_luma", error) : nil;
	_stillCount = _shrinkLuma ? pipeline(library, @"still_count", error) : nil;
	_keepStill = _stillCount ? pipeline(library, @"keep_still", error) : nil;
	_uiOver = _keepStill ? pipeline(library, @"ui_over", error) : nil;
	_engine = _uiOver ? pipeline(library, @"engine_motion", error) : nil;
	_aneInput = _engine ? pipeline(library, @"ane_input", error) : nil;
	_aneMotion = _aneInput ? pipeline(library, @"ane_motion", error) : nil;
	_mark = _aneMotion ? pipeline(library, @"mark_generated", error) : nil;
	_repairTuning = FGDefaultRepair();
	_phase = 0.5f;
	// Histograms and cut flags for the whole frame and 3x3 regions, see luma_histogram
	_bins = [device newBufferWithLength:2 * 10 * 16 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
	_cutFlag = [device newBufferWithLength:10 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
	_repairCounts = [device newBufferWithLength:2 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
	// Stands in for the Neural Engine's flow and mask when the repair pass goes without them
	_none = [self texture:MTLPixelFormatR16Float width:4 height:4 usage:MTLTextureUsageShaderRead];
	return _mark != nil ? self : nil;
}

- (id<MTLTexture>)luma { return _luma2[_current]; }
- (id<MTLTexture>)blockVectors { return _vectors; }
- (id<MTLTexture>)output { return _output; }

- (id<MTLTexture>)outputAt:(int)index
{
	return index <= 0 ? _output : _extra[MIN(index, 2) - 1];
}

- (void)encodeNeuralInput:(id<MTLTexture>)frame into:(id<MTLTexture>)planes commandBuffer:(id<MTLCommandBuffer>)buffer
{
	id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
	[compute setComputePipelineState:_aneInput];
	[compute setTexture:frame atIndex:0];
	[compute setTexture:planes atIndex:1];
	[compute dispatchThreads:MTLSizeMake(planes.width, planes.height / 3, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[compute endEncoding];
}

- (void)repairConfidence:(double *)confidence replaced:(double *)replaced
{
	const uint32_t *counts = _repairCounts.contents;
	double pixels = (double)_width * (double)_height * MAX(1, _passes);
	*confidence = pixels > 0 ? counts[0] / 256.0 / pixels : 0;
	*replaced = pixels > 0 ? counts[1] / pixels : 0;
}

- (id<MTLTexture>)texture:(MTLPixelFormat)format width:(NSUInteger)width height:(NSUInteger)height
                    usage:(MTLTextureUsage)usage
{
	MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
	                                                                                      width:width
	                                                                                     height:height
	                                                                                  mipmapped:NO];
	descriptor.usage = usage;
	descriptor.storageMode = MTLStorageModePrivate;
	return [_device newTextureWithDescriptor:descriptor];
}

- (void)clearDepth
{
	id<MTLCommandBuffer> buffer = [_setup commandBuffer];
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.depthAttachment.texture = _depth;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = _settings.depth;
	pass.depthAttachment.storeAction = MTLStoreActionStore;
	[[buffer renderCommandEncoderWithDescriptor:pass] endEncoding];
	[buffer commit];
}

- (BOOL)prepareWidth:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format
               error:(NSString **)error
{
	// Automatic: from 1280 pixels wide MetalFX works at half size, a quarter of its cost; the
	// repair pass at full size keeps the detail (same ghosting on the tune scene, 3 ms less at 1080p)
	_downscale = _settings.downscale > 0 ? _settings.downscale : width >= 1280 ? 2 : 1;
	NSUInteger iw = (width + _downscale - 1) / _downscale, ih = (height + _downscale - 1) / _downscale;
	MTLFXFrameInterpolatorDescriptor *descriptor = [MTLFXFrameInterpolatorDescriptor new];
	descriptor.colorTextureFormat = format;
	descriptor.outputTextureFormat = format;
	descriptor.depthTextureFormat = MTLPixelFormatDepth32Float;
	descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
	descriptor.inputWidth = descriptor.outputWidth = iw;
	descriptor.inputHeight = descriptor.outputHeight = ih;
	if (_uiTexture != nil && _uiToMetalFX)
		descriptor.uiTextureFormat = _uiTexture.pixelFormat;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
	if (_noPrevColor) {
		if (@available(macOS 27.0, *))
			descriptor.requiresPrevColorTexture = NO;
	}
#endif
	atomic_store(&FGCreatingInterpolator, 1);
	id<MTLFXFrameInterpolator> interpolator = [descriptor newFrameInterpolatorWithDevice:_device];
	atomic_store(&FGCreatingInterpolator, 0);
	if (interpolator == nil) {
		if (error != NULL)
			*error = [NSString stringWithFormat:@"no interpolator for %lux%lu format %lu",
			          (unsigned long)width, (unsigned long)height, (unsigned long)format];
		return NO;
	}

	// Automatic: analysis at a quarter from 1600 pixels wide, at half from 1000; at 1080p a quarter
	// with the short way back costs 2 ms instead of 5.5, for as many wrong blocks
	_factor = _settings.factor > 0 ? _settings.factor : width >= 1600 ? 4 : width > 1000 ? 2 : 1;
	NSUInteger factor = (NSUInteger)_factor, block = (NSUInteger)_settings.block;
	NSUInteger aw = (width + factor - 1) / factor, ah = (height + factor - 1) / factor;
	MTLTextureUsage read = MTLTextureUsageShaderRead, write = MTLTextureUsageShaderWrite;
	for (int i = 0; i < 2; i++) {
		_frames[i] = [self texture:format width:width height:height usage:interpolator.colorTextureUsage | read];
		_small[i] = _downscale == 1 ? _frames[i]
		                            : [self texture:format width:iw height:ih usage:interpolator.colorTextureUsage | read | write];
		_luma2[i] = [self texture:MTLPixelFormatR16Float width:aw height:ah usage:read | write];
	}
	_vectors = [self texture:MTLPixelFormatRG16Float width:(aw + block - 1) / block height:(ah + block - 1) / block
	                   usage:read | write];
	_smooth = [self texture:MTLPixelFormatRG16Float width:_vectors.width height:_vectors.height usage:read | write];
	_motion = [self texture:MTLPixelFormatRG16Float width:iw height:ih
	                  usage:interpolator.motionTextureUsage | read | write];
	_depth = [self texture:MTLPixelFormatDepth32Float width:iw height:ih
	                 usage:interpolator.depthTextureUsage | MTLTextureUsageRenderTarget];
	_output = [self texture:format width:width height:height usage:interpolator.outputTextureUsage | read | write];
	// MetalFX's own frame at full size, before the repair pass writes the output
	_raw = [self texture:format width:width height:height usage:interpolator.outputTextureUsage | read | write];
	for (int i = 0; i < 2; i++) {
		_still[i] = [self texture:MTLPixelFormatR8Uint width:width height:height usage:read | write];
		_weights[i] = [self texture:MTLPixelFormatRGBA16Float width:aw height:ah usage:read | write];
	}
	_smallOutput = _downscale == 1 ? _output
	                               : [self texture:format width:iw height:ih usage:interpolator.outputTextureUsage | read | write];
	// The pyramid starts from the analysis luma and halves while the smallest side keeps 16 pixels
	_levels = 0;
	for (NSUInteger w = aw, h = ah; _levels < max_levels && (_levels == 0 || MIN(w, h) >= 16); w = (w + 1) / 2, h = (h + 1) / 2) {
		for (int i = 0; i < 2; i++)
			_pyramid[i][_levels] = _levels == 0 ? _luma2[i]
			                                    : [self texture:MTLPixelFormatR16Float width:w height:h usage:read | write];
		_forward[_levels] = [self texture:MTLPixelFormatRGBA16Float width:(w + 3) / 4 height:(h + 3) / 4
		                            usage:read | write];
		_backward[_levels] = [self texture:MTLPixelFormatRGBA16Float width:(w + 3) / 4 height:(h + 3) / 4
		                             usage:read | write];
		_spare[_levels] = [self texture:MTLPixelFormatRGBA16Float width:(w + 3) / 4 height:(h + 3) / 4
		                          usage:read | write];
		_levels++;
	}
	_checked = [self texture:MTLPixelFormatRGBA16Float width:_forward[0].width height:_forward[0].height
	                   usage:read | write];
	_filtered = [self texture:MTLPixelFormatRGBA16Float width:_forward[0].width height:_forward[0].height
	                    usage:read | write];
	if (_frames[1] == nil || _small[1] == nil || _luma2[1] == nil || _smooth == nil || _motion == nil || _depth == nil ||
	    _output == nil || _raw == nil || _still[1] == nil || _weights[1] == nil || _smallOutput == nil) {
		if (error != NULL)
			*error = @"out of GPU memory";
		return NO;
	}
	_interpolator = interpolator;
	[self clearDepth];

	interpolator.depthTexture = _depth;
	interpolator.motionTexture = _motion;
	interpolator.outputTexture = _smallOutput;
	interpolator.nearPlane = 0.1f;
	interpolator.farPlane = 1000.0f;
	interpolator.fieldOfView = 60.0f;
	interpolator.aspectRatio = (float)width / (float)height;
	_width = width;
	_height = height;
	_format = format;
	_extra[0] = _extra[1] = nil;
	_bare = nil;
	_ui = nil;
	_haveUI = NO;
	[self reset];
	return YES;
}

- (BOOL)useSettings:(FGSettings)next error:(NSString **)error
{
	next.block = next.block <= 4 ? 4 : next.block >= 16 ? 16 : 8;
	next.radius = MAX(1, MIN(31, next.radius));
	next.factor = next.factor <= 0 ? 0 : next.factor == 1 ? 1 : next.factor >= 4 ? 4 : 2;
	FGSettings old = _settings;
	if (next.block != old.block || next.radius != old.radius) {
		id<MTLLibrary> library = [self libraryForBlock:next.block radius:next.radius error:error];
		id<MTLComputePipelineState> match = library ? pipeline(library, @"block_match", error) : nil;
		if (match == nil)
			return NO;
		_match = match;
	}
	_settings = next;
	next.downscale = next.downscale <= 0 ? 0 : next.downscale >= 2 ? 2 : 1;
	if (_width > 0 && (next.block != old.block || next.factor != old.factor || next.downscale != old.downscale))
		return [self prepareWidth:_width height:_height format:_format error:error];
	if (_width > 0 && next.depth != old.depth)
		[self clearDepth];
	if (next.mode != old.mode || next.zero != old.zero)
		[self reset];
	return YES;
}

- (id)interpolator
{
	return _interpolator;
}

- (void)reset
{
	_havePrevious = NO;
	_interpolator.shouldResetHistory = YES;
}

static MTLSize groups(id<MTLTexture> texture, NSUInteger side)
{
	return MTLSizeMake((texture.width + side - 1) / side, (texture.height + side - 1) / side, 1);
}

- (BOOL)encodeCapture:(id<MTLTexture>)frame commandBuffer:(id<MTLCommandBuffer>)buffer
{
	BOOL had = _havePrevious;
	_current ^= 1;
	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	[blit copyFromTexture:frame sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
	           sourceSize:MTLSizeMake(_width, _height, 1)
	            toTexture:_frames[_current] destinationSlice:0 destinationLevel:0
	    destinationOrigin:MTLOriginMake(0, 0, 0)];
	_haveUI = [self hasUI];
	if (_haveUI) {
		if (_ui == nil || _ui.pixelFormat != _uiTexture.pixelFormat)
			_ui = [self texture:_uiTexture.pixelFormat width:_width height:_height usage:MTLTextureUsageShaderRead];
		[blit copyFromTexture:_uiTexture toTexture:_ui];
	}
	[blit endEncoding];

	uint32_t factor = (uint32_t)_factor;
	id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
	if (_downscale == 2 && _factor == 4) {
		// One pass writes both the MetalFX-size frame and the analysis luma
		[compute setComputePipelineState:_shrinkLuma];
		[compute setTexture:_frames[_current] atIndex:0];
		[compute setTexture:_small[_current] atIndex:1];
		[compute setTexture:_luma2[_current] atIndex:2];
		[compute dispatchThreadgroups:groups(_luma2[_current], 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	} else {
		[compute setComputePipelineState:_luma];
		[compute setTexture:_frames[_current] atIndex:0];
		[compute setTexture:_luma2[_current] atIndex:1];
		[compute setBytes:&factor length:sizeof(factor) atIndex:0];
		[compute dispatchThreadgroups:groups(_luma2[_current], 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		if (_downscale > 1) {
			[compute setComputePipelineState:_shrink];
			[compute setTexture:_frames[_current] atIndex:0];
			[compute setTexture:_small[_current] atIndex:1];
			[compute dispatchThreadgroups:groups(_small[_current], 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		}
	}
	if ((_settings.estimator == 1 || _settings.cuts) && _levels > 1) {
		// One tile pass builds the whole local pyramid; deeper levels only exist past 4K
		uint32_t depth = MIN((uint32_t)_levels - 1, 5);
		[compute setComputePipelineState:_lumaPyramid];
		for (int l = 0; l <= 5; l++)
			[compute setTexture:_pyramid[_current][MIN(l, _levels - 1)] atIndex:l];
		[compute setBytes:&depth length:sizeof(depth) atIndex:0];
		[compute dispatchThreadgroups:groups(_pyramid[_current][1], 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		for (int l = 6; l < _levels; l++) {
			[compute setComputePipelineState:_down];
			[compute setTexture:_pyramid[_current][l - 1] atIndex:0];
			[compute setTexture:_pyramid[_current][l] atIndex:1];
			[compute dispatchThreadgroups:groups(_pyramid[_current][l], 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		}
	}
	if (_settings.hud > 0) {
		uint32_t fresh = had ? 0 : 1;
		[compute setComputePipelineState:_stillCount];
		[compute setTexture:_frames[_current ^ 1] atIndex:0];
		[compute setTexture:_frames[_current] atIndex:1];
		[compute setTexture:_still[_current ^ 1] atIndex:2];
		[compute setTexture:_still[_current] atIndex:3];
		[compute setBytes:&fresh length:sizeof(fresh) atIndex:0];
		[compute dispatchThreadgroups:groups(_still[_current], 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	}
	[compute endEncoding];
	if (_settings.cuts) {
		id<MTLTexture> small = _pyramid[_current][MIN(2, _levels - 1)];
		id<MTLBlitCommandEncoder> clear = [buffer blitCommandEncoder];
		[clear fillBuffer:_bins range:NSMakeRange((NSUInteger)_current * 160 * sizeof(uint32_t), 160 * sizeof(uint32_t))
		            value:0];
		[clear endEncoding];
		compute = [buffer computeCommandEncoder];
		[compute setComputePipelineState:_histogram];
		[compute setTexture:small atIndex:0];
		[compute setBuffer:_bins offset:(NSUInteger)_current * 160 * sizeof(uint32_t) atIndex:0];
		[compute dispatchThreadgroups:groups(small, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		// A region needs more of its histogram to move than the whole frame: a fast pan shifts a
		// region's tones more than the frame's. Both histograms are complete here, so the flag
		// settles once per real frame rather than once per generated one
		float threshold[2] = { 0.35f, 0.5f };
		[compute setComputePipelineState:_cut];
		[compute setBuffer:_bins offset:(NSUInteger)_current * 160 * sizeof(uint32_t) atIndex:0];
		[compute setBuffer:_bins offset:(NSUInteger)(_current ^ 1) * 160 * sizeof(uint32_t) atIndex:1];
		[compute setBuffer:_cutFlag offset:0 atIndex:2];
		[compute setBytes:threshold length:sizeof(threshold) atIndex:3];
		[compute dispatchThreads:MTLSizeMake(10, 1, 1) threadsPerThreadgroup:MTLSizeMake(10, 1, 1)];
		[compute endEncoding];
	}
	_havePrevious = YES;
	return had;
}

// Coarse to fine, from frame "from" to frame "to", into fields
- (void)encodePyramidFrom:(int)from to:(int)to into:(id<MTLTexture> __strong *)fields
                  compute:(id<MTLComputeCommandEncoder>)compute
{
	for (int l = _levels - 1; l >= 0; l--) {
		BOOL top = l == _levels - 1;
		Level level = { top ? 4 : _settings.radius > 2 ? 2 : MAX(1, _settings.radius), top ? 1 : 0, _settings.bias };
		[compute setComputePipelineState:_flow];
		[compute setTexture:_pyramid[from][l] atIndex:0];
		[compute setTexture:_pyramid[to][l] atIndex:1];
		[compute setTexture:top ? fields[l] : fields[l + 1] atIndex:2];
		[compute setTexture:_spare[l] atIndex:3];
		[compute setBytes:&level length:sizeof(level) atIndex:0];
		[compute dispatchThreadgroups:groups(fields[l], 8) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
		[compute setComputePipelineState:_propagate];
		[compute setTexture:_spare[l] atIndex:2];
		[compute setTexture:fields[l] atIndex:3];
		[compute dispatchThreadgroups:groups(fields[l], 8) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
	}
}

- (void)encodeMotion:(id<MTLCommandBuffer>)buffer
{
	if (_settings.estimator == 1) {
		[self encodePyramidMotion:buffer];
		return;
	}
	uint32_t still = _settings.still ? (_settings.hud > 0 ? 2 : 1) : 0;
	Motion motion = { _settings.bias, (float)_factor / (float)_downscale, (uint32_t)_settings.expand, (uint32_t)_settings.zero,
	                  still };
	uint32_t median = (uint32_t)_settings.median, cell = (uint32_t)(_settings.block * _factor / _downscale);
	NSUInteger block = (NSUInteger)_settings.block;

	id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
	[compute setComputePipelineState:_match];
	[compute setTexture:_luma2[_current ^ 1] atIndex:0];
	[compute setTexture:_luma2[_current] atIndex:1];
	[compute setTexture:_vectors atIndex:2];
	[compute setBytes:&motion length:sizeof(motion) atIndex:0];
	[compute dispatchThreadgroups:MTLSizeMake(_vectors.width, _vectors.height, 1)
	        threadsPerThreadgroup:MTLSizeMake(block, block, 1)];

	[compute setComputePipelineState:_median];
	[compute setTexture:_vectors atIndex:0];
	[compute setTexture:_smooth atIndex:1];
	[compute setBytes:&median length:sizeof(median) atIndex:0];
	[compute dispatchThreadgroups:groups(_smooth, 8) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];

	[compute setComputePipelineState:_expand];
	[compute setTexture:_smooth atIndex:0];
	[compute setTexture:_motion atIndex:1];
	[compute setTexture:_small[_current] atIndex:2];
	[compute setTexture:_small[_current ^ 1] atIndex:3];
	[compute setTexture:_still[_current] atIndex:4];
	[compute setBytes:&motion length:sizeof(motion) atIndex:0];
	[compute setBytes:&cell length:sizeof(cell) atIndex:1];
	[compute dispatchThreadgroups:groups(_motion, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[compute endEncoding];
}

- (void)encodePyramidMotion:(id<MTLCommandBuffer>)buffer
{
	uint32_t still = _settings.still ? (_settings.hud > 0 ? 2 : 1) : 0;
	Motion motion = { _settings.bias, (float)_factor / (float)_downscale, (uint32_t)_settings.expand, (uint32_t)_settings.zero,
	                  still };
	uint32_t median = (uint32_t)_settings.median, cell = (uint32_t)(4 * _factor / _downscale);
	int cur = _current, prev = _current ^ 1;
	// The automatic quarter-size analysis takes the short way back, see prepareWidth
	int check = _settings.check == 1 && _settings.factor == 0 && _factor == 4 ? 2 : _settings.check;

	id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
	[self encodePyramidFrom:cur to:prev into:_forward compute:compute];
	id<MTLTexture> field = _forward[0];
	if (check == 1) {
		[self encodePyramidFrom:prev to:cur into:_backward compute:compute];
	} else if (check == 2) {
		// Cheaper way back: the finest level only, a short search around the way there reversed
		Level level = { 1, 2, _settings.bias };
		[compute setComputePipelineState:_flow];
		[compute setTexture:_pyramid[prev][0] atIndex:0];
		[compute setTexture:_pyramid[cur][0] atIndex:1];
		[compute setTexture:_forward[0] atIndex:2];
		[compute setTexture:_spare[0] atIndex:3];
		[compute setBytes:&level length:sizeof(level) atIndex:0];
		[compute dispatchThreadgroups:groups(_backward[0], 8) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
		[compute setComputePipelineState:_propagate];
		[compute setTexture:_spare[0] atIndex:2];
		[compute setTexture:_backward[0] atIndex:3];
		[compute dispatchThreadgroups:groups(_backward[0], 8) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
	}
	if (check) {
		float tolerance = 1.0f;
		[compute setComputePipelineState:_check];
		[compute setTexture:_forward[0] atIndex:0];
		[compute setTexture:_backward[0] atIndex:1];
		[compute setTexture:_checked atIndex:2];
		[compute setBytes:&tolerance length:sizeof(tolerance) atIndex:0];
		[compute dispatchThreadgroups:groups(_checked, 8) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
		field = _checked;
	}
	if (median) {
		[compute setComputePipelineState:_median];
		[compute setTexture:field atIndex:0];
		[compute setTexture:_filtered atIndex:1];
		[compute setBytes:&median length:sizeof(median) atIndex:0];
		[compute dispatchThreadgroups:groups(_filtered, 8) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
		field = _filtered;
	}

	[compute setComputePipelineState:_expand];
	[compute setTexture:field atIndex:0];
	[compute setTexture:_motion atIndex:1];
	[compute setTexture:_small[cur] atIndex:2];
	[compute setTexture:_small[prev] atIndex:3];
	[compute setTexture:_still[cur] atIndex:4];
	[compute setBytes:&motion length:sizeof(motion) atIndex:0];
	[compute setBytes:&cell length:sizeof(cell) atIndex:1];
	[compute dispatchThreadgroups:groups(_motion, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[compute endEncoding];
}

- (void)encodeFrame:(id<MTLCommandBuffer>)buffer deltaTime:(float)deltaTime
{
	float phase = _phase;
	[self encodeFrames:buffer deltaTime:deltaTime phases:&phase count:1];
}

- (void)encodeFrames:(id<MTLCommandBuffer>)buffer deltaTime:(float)deltaTime phases:(const float *)phases count:(int)count
{
	// Without the repair pass only the middle frame exists
	BOOL own = _settings.mode == 4;
	count = (_settings.repair && _settings.mode == 0) || own ? MAX(1, MIN(3, count)) : 1;
	for (int i = 1; i < count; i++)
		if (_extra[i - 1] == nil)
			_extra[i - 1] = [self texture:_format width:_width height:_height
			                        usage:_output.usage];
	if (_settings.mode == 2) {
		id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
		[blit copyFromTexture:_frames[_current ^ 1] toTexture:_output];
		[blit endEncoding];
		return;
	}
	if (_settings.mode == 1) {
		id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
		[compute setComputePipelineState:_blend];
		[compute setTexture:_frames[_current ^ 1] atIndex:0];
		[compute setTexture:_frames[_current] atIndex:1];
		[compute setTexture:_output atIndex:2];
		[compute dispatchThreadgroups:groups(_output, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[compute endEncoding];
		return;
	}
	if (_motionOverride == nil && _neuralFlow != nil) {
		id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
		[compute setComputePipelineState:_aneMotion];
		[compute setTexture:_neuralFlow atIndex:0];
		[compute setTexture:_motion atIndex:1];
		[compute dispatchThreadgroups:groups(_motion, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[compute endEncoding];
	} else if (_motionOverride == nil && _engineMotion != nil && _settings.engine) {
		float scale = _engineMotionScale * (float)_motion.width / (float)_engineMotion.width;
		id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
		[compute setComputePipelineState:_engine];
		[compute setTexture:_engineMotion atIndex:0];
		[compute setTexture:_motion atIndex:1];
		[compute setBytes:&scale length:sizeof(scale) atIndex:0];
		[compute dispatchThreadgroups:groups(_motion, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[compute endEncoding];
	} else if (_motionOverride == nil)
		[self encodeMotion:buffer];
	_interpolator.motionTexture = _motionOverride ?: _motion;
	_interpolator.depthTexture = _depthOverride ?: _depth;
	if (_settings.mode == 3) {
		id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
		[compute setComputePipelineState:_show];
		[compute setTexture:_motion atIndex:0];
		[compute setTexture:_frames[_current] atIndex:1];
		[compute setTexture:_output atIndex:2];
		[compute dispatchThreadgroups:groups(_output, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[compute endEncoding];
		return;
	}
	// With the repair pass, MetalFX's frame lands in _raw and the repair writes the output
	BOOL repair = _settings.repair != 0 || own;
	// Mode 4: no MetalFX, the repair pass alone makes the frame
	if (!own) {
		_interpolator.colorTexture = _small[_current];
		_interpolator.prevColorTexture = _noPrevColor ? nil : _small[_current ^ 1];
		if (_uiToMetalFX && [self hasUI] && _downscale == 1 && _uiTexture.pixelFormat == _interpolator.uiTextureFormat) {
			_interpolator.uiTexture = _uiTexture;
			_interpolator.uiTextureComposited = _uiComposited;
		} else
			_interpolator.uiTexture = nil;
		_interpolator.motionVectorScaleX = _settings.motionScale;
		_interpolator.motionVectorScaleY = _settings.motionScale;
		_interpolator.depthReversed = _settings.depthReversed != 0;
		_interpolator.deltaTime = _settings.realDeltaTime ? deltaTime : 0;
		if (_settings.resetEvery)
			_interpolator.shouldResetHistory = YES;
		// The flag the GPU left for the last finished frame: history from before a cut is useless
		uint32_t *cut = _cutFlag.contents;
		if (_settings.cuts && cut[0] != 0)
			_interpolator.shouldResetHistory = YES;
		id<MTLTexture> full = repair ? _raw : _output;
		_interpolator.outputTexture = _downscale > 1 ? _smallOutput : full;
		[_interpolator encodeToCommandBuffer:buffer];
		_interpolator.shouldResetHistory = NO;
		// With the repair pass its frame is sampled at MetalFX's size, no grown copy needed
		if (_downscale > 1 && !repair) {
			id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
			[compute setComputePipelineState:_grow];
			[compute setTexture:_smallOutput atIndex:0];
			[compute setTexture:full atIndex:1];
			[compute dispatchThreadgroups:groups(full, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
			[compute endEncoding];
		}
	}
	if (!repair) {
		[self finishOutput:_output buffer:buffer stillAndCuts:YES];
		return;
	}
	_passes = count;
	for (int i = 0; i < count; i++) {
		id<MTLTexture> out = [self outputAt:i];
		[self encodeRepair:buffer phase:phases[i] into:out];
		[self finishOutput:out buffer:buffer stillAndCuts:NO];
	}
}

// One repair pass at phase over MetalFX's frame: the softmax weights, then the mix
- (void)encodeRepair:(id<MTLCommandBuffer>)buffer phase:(float)phase into:(id<MTLTexture>)out
{
	id<MTLTexture> motion = _interpolator.motionTexture;
	BOOL neural = _neuralFlow != nil && _neuralMask != nil && _motionOverride == nil;
	id<MTLTexture> flow = neural ? _neuralFlow : _none, mask = neural ? _neuralMask : _none;
	Repair r = { _repairTuning.sigma, _repairTuning.farLo, _repairTuning.farHi, _repairTuning.sureLo,
	             _repairTuning.sureHi, _repairTuning.reach, (float)_width / (float)motion.width,
	             (float)_width / (float)_luma2[0].width, phase, neural ? _repairTuning.occlusion : 0,
	             neural ? _repairTuning.flows : 0, _settings.mode == 4 ? 1.0f : 0.0f,
	             (float)_settings.hud, (float)_settings.cuts };
	float output[2] = { (float)_width, (float)_height };
	id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
	[compute setComputePipelineState:_repairWeights];
	[compute setTexture:_luma2[_current ^ 1] atIndex:0];
	[compute setTexture:_luma2[_current] atIndex:1];
	[compute setTexture:motion atIndex:2];
	[compute setTexture:_weights[0] atIndex:3];
	[compute setTexture:_weights[1] atIndex:4];
	[compute setTexture:flow atIndex:5];
	[compute setBytes:&r length:sizeof(r) atIndex:0];
	[compute setBytes:output length:sizeof(output) atIndex:1];
	[compute setBuffer:_repairCounts offset:0 atIndex:2];
	[compute dispatchThreadgroups:groups(_weights[0], 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[compute setComputePipelineState:_repair];
	[compute setTexture:_downscale > 1 ? _smallOutput : _raw atIndex:0];
	[compute setTexture:_frames[_current ^ 1] atIndex:1];
	[compute setTexture:_frames[_current] atIndex:2];
	[compute setTexture:motion atIndex:3];
	[compute setTexture:out atIndex:4];
	[compute setTexture:_weights[0] atIndex:5];
	[compute setTexture:_weights[1] atIndex:6];
	[compute setTexture:flow atIndex:7];
	[compute setTexture:mask atIndex:8];
	[compute setTexture:_still[_current] atIndex:9];
	[compute setBytes:&r length:sizeof(r) atIndex:0];
	[compute setBuffer:_repairCounts offset:0 atIndex:1];
	[compute setBuffer:_cutFlag offset:0 atIndex:2];
	[compute dispatchThreadgroups:groups(out, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[compute endEncoding];
}

// The UI is usable: macOS 27, the frame's size
- (BOOL)hasUI
{
	if (@available(macOS 27.0, *))
		return _uiTexture != nil && _uiTexture.width == _width && _uiTexture.height == _height;
	return NO;
}

// Still pixels from the last real frame, the frame before in place of a cut, the UI on top, and the
// overlay. The repair pass folds the first two in; they run apart only when it did not.
- (void)finishOutput:(id<MTLTexture>)out buffer:(id<MTLCommandBuffer>)buffer stillAndCuts:(BOOL)stillAndCuts
{
	BOOL ui = _haveUI && _ui != nil;
	if (stillAndCuts && _settings.hud > 0) {
		uint32_t frames = (uint32_t)_settings.hud;
		id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
		[compute setComputePipelineState:_keepStill];
		[compute setTexture:_still[_current] atIndex:0];
		[compute setTexture:_frames[_current] atIndex:1];
		[compute setTexture:out atIndex:2];
		[compute setBytes:&frames length:sizeof(frames) atIndex:0];
		[compute dispatchThreadgroups:groups(out, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[compute endEncoding];
	}
	if (stillAndCuts && _settings.cuts) {
		id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
		[compute setComputePipelineState:_fallback];
		[compute setTexture:_frames[_current ^ 1] atIndex:0];
		[compute setTexture:out atIndex:1];
		[compute setBuffer:_cutFlag offset:0 atIndex:0];
		[compute dispatchThreadgroups:groups(out, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[compute endEncoding];
	}
	if (ui) {
		uint32_t composited = _uiComposited ? 1 : 0;
		id<MTLTexture> under = _frames[_current];
		if (!composited) {
			if (_bare == nil)
				_bare = [self texture:_format width:_width height:_height usage:MTLTextureUsageShaderRead];
			id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
			[blit copyFromTexture:out toTexture:_bare];
			[blit endEncoding];
			under = _bare;
		}
		id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
		[compute setComputePipelineState:_uiOver];
		[compute setTexture:_ui atIndex:0];
		[compute setTexture:under atIndex:1];
		[compute setTexture:out atIndex:2];
		[compute setBytes:&composited length:sizeof(composited) atIndex:0];
		[compute dispatchThreadgroups:groups(out, 16) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[compute endEncoding];
	}
	if (_settings.overlay) {
		id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
		[compute setComputePipelineState:_mark];
		[compute setTexture:out atIndex:0];
		[compute dispatchThreadgroups:MTLSizeMake(3, 3, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
		[compute endEncoding];
	}
}

@end
