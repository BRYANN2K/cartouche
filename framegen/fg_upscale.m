#import "fg_upscale.h"

#import <AppKit/AppKit.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#import "fg_formats.h"
#import "framegen_upscale.h"

typedef struct {
	uint32_t size[2];
	uint32_t headsWidth;
	uint32_t gamma;
	uint32_t hdr;
	uint32_t candidatesMax, locationsMax, itemsMax;
} CMAAInfo;

static void note(const char *format, ...)
{
	char line[512];
	va_list args;
	va_start(args, format);
	int len = vsnprintf(line, sizeof(line) - 1, format, args);
	va_end(args);
	if (len < 0)
		return;
	if ((size_t)len > sizeof(line) - 2)
		len = (int)sizeof(line) - 2;
	line[len++] = '\n';
	(void)!write(STDERR_FILENO, "framegen: ", 10);
	(void)!write(STDERR_FILENO, line, (size_t)len);
}

BOOL FGUpscaleParse(const char *text, FGUpscaleSettings *settings)
{
	FGUpscaleSettings s = { .cmaa = 0, .metalfx = 0, .sharpness = -1 };
	if (text == NULL || text[0] == 0)
		return NO;
	char *copy = strdup(text), *save = NULL;
	BOOL known = YES;
	for (char *part = strtok_r(copy, "+", &save); part != NULL; part = strtok_r(NULL, "+", &save)) {
		// RCAS after MetalFX scores worse on every measure (upbench), so the chain leaves it out
		if (strcmp(part, "chain") == 0 || strcmp(part, "1") == 0) {
			s.cmaa = 1;
			s.metalfx = 1;
		} else if (strcmp(part, "cmaa2") == 0)
			s.cmaa = 1;
		else if (strcmp(part, "metalfx") == 0)
			s.metalfx = 1;
		else if (strcmp(part, "bilinear") == 0)
			s.metalfx = 0;
		else if (strcmp(part, "rcas") == 0)
			s.sharpness = 2;
		else if (strncmp(part, "rcas=", 5) == 0)
			s.sharpness = (float)fmax(0, atof(part + 5));
		else
			known = NO;
	}
	free(copy);
	if (known)
		*settings = s;
	return known;
}

static BOOL is_srgb(MTLPixelFormat format)
{
	return format == MTLPixelFormatBGRA8Unorm_sRGB || format == MTLPixelFormatRGBA8Unorm_sRGB ||
	       format == MTLPixelFormatBGR10_XR_sRGB || format == MTLPixelFormatBGRA10_XR_sRGB;
}


// Built once per device and process: a new placement or scaler reuses it
id<MTLLibrary> FGUpscaleLibrary(id<MTLDevice> device, NSError **error)
{
	static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
	static NSMutableDictionary<NSNumber *, id<MTLLibrary>> *built;
	NSNumber *key = @(device.registryID);
	os_unfair_lock_lock(&lock);
	id<MTLLibrary> library = built[key];
	os_unfair_lock_unlock(&lock);
	if (library != nil)
		return library;
	NSString *source = [[NSString alloc] initWithBytes:upscale_metal length:upscale_metal_len encoding:NSUTF8StringEncoding];
	library = [device newLibraryWithSource:source options:[MTLCompileOptions new] error:error];
	if (library == nil)
		return nil;
	os_unfair_lock_lock(&lock);
	if (built == nil)
		built = [NSMutableDictionary dictionary];
	built[key] = library;
	os_unfair_lock_unlock(&lock);
	return library;
}

@implementation FGUpscaler {
	id<MTLDevice> _device;
	id<MTLComputePipelineState> _edges, _args, _candidates, _apply, _copy;
	id<MTLFunction> _screen, _bilinear, _rcas;
	NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *_bilinearPipes, *_rcasPipes;
	id<MTLTexture> _work, _edgeBits, _mid;
	id<MTLBuffer> _control, _indirect, _shapes, _heads, _items, _locations;
	CMAAInfo _info;
	id<MTLFXSpatialScaler> _scaler;
	NSUInteger _inW, _inH, _outW, _outH;
	MTLPixelFormat _inF, _outF;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device settings:(FGUpscaleSettings)settings error:(NSString **)error
{
	if ((self = [super init]) == nil)
		return nil;
	_device = device;
	_settings = settings;
	NSError *failure = nil;
	id<MTLLibrary> library = FGUpscaleLibrary(device, &failure);
	if (library == nil) {
		if (error)
			*error = [NSString stringWithFormat:@"upscale kernels: %@", failure.localizedDescription];
		return nil;
	}
	id<MTLComputePipelineState> (^compute)(NSString *) = ^(NSString *name) {
		NSError *e = nil;
		return [device newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:&e];
	};
	_edges = compute(@"cmaa_edges");
	_args = compute(@"cmaa_args");
	_candidates = compute(@"cmaa_candidates");
	_apply = compute(@"cmaa_apply");
	_copy = compute(@"copy_image");
	_screen = [library newFunctionWithName:@"screen_v"];
	_bilinear = [library newFunctionWithName:@"bilinear_f"];
	_rcas = [library newFunctionWithName:@"rcas_f"];
	_bilinearPipes = [NSMutableDictionary new];
	_rcasPipes = [NSMutableDictionary new];
	if (_edges == nil || _args == nil || _candidates == nil || _apply == nil || _copy == nil) {
		if (error)
			*error = @"upscale kernels: a pipeline failed";
		return nil;
	}
	return self;
}

- (id<MTLRenderPipelineState>)pipe:(BOOL)sharpen format:(MTLPixelFormat)format
{
	NSMutableDictionary *cache = sharpen ? _rcasPipes : _bilinearPipes;
	id<MTLRenderPipelineState> pipe = cache[@(format)];
	if (pipe == nil) {
		MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
		d.vertexFunction = _screen;
		d.fragmentFunction = sharpen ? _rcas : _bilinear;
		d.colorAttachments[0].pixelFormat = format;
		pipe = [_device newRenderPipelineStateWithDescriptor:d error:nil];
		if (pipe != nil)
			cache[@(format)] = pipe;
	}
	return pipe;
}

- (id<MTLTexture>)texture:(MTLPixelFormat)format width:(NSUInteger)width height:(NSUInteger)height usage:(MTLTextureUsage)usage
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
	d.usage = usage;
	d.storageMode = MTLStorageModePrivate;
	return [_device newTextureWithDescriptor:d];
}

- (id<MTLBuffer>)buffer:(NSUInteger)length
{
	return [_device newBufferWithLength:MAX(length, 16) options:MTLResourceStorageModePrivate];
}

- (BOOL)prepareInputWidth:(NSUInteger)inputWidth height:(NSUInteger)inputHeight format:(MTLPixelFormat)inputFormat
              outputWidth:(NSUInteger)outputWidth height:(NSUInteger)outputHeight format:(MTLPixelFormat)outputFormat
                    error:(NSString **)error
{
	_inW = inputWidth;
	_inH = inputHeight;
	_inF = inputFormat;
	_outW = outputWidth;
	_outH = outputHeight;
	_outF = outputFormat;
	_work = _edgeBits = _mid = nil;
	_scaler = nil;
	_metalfxInUse = NO;
	// sRGB formats read as linear and cannot always be written: CMAA2 and MetalFX work in half floats
	MTLPixelFormat work = is_srgb(inputFormat) ? MTLPixelFormatRGBA16Float : inputFormat;
	if (_settings.cmaa) {
		_info = (CMAAInfo){ .size = { (uint32_t)inputWidth, (uint32_t)inputHeight },
			                .headsWidth = (uint32_t)(inputWidth + 1) / 2,
			                .gamma = !is_srgb(inputFormat) && !is_float(inputFormat),
			                .hdr = is_float(inputFormat) };
		NSUInteger quads = (NSUInteger)_info.headsWidth * ((inputHeight + 1) / 2);
		_info.candidatesMax = (uint32_t)(inputWidth * inputHeight / 4);
		_info.itemsMax = (uint32_t)(inputWidth * inputHeight / 2);
		_info.locationsMax = (uint32_t)quads;
		_work = [self texture:work width:inputWidth height:inputHeight
		                usage:MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite];
		_edgeBits = [self texture:MTLPixelFormatR8Uint width:inputWidth height:inputHeight
		                    usage:MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite];
		_control = [_device newBufferWithLength:64 options:MTLResourceStorageModeShared];
		memset(_control.contents, 0, 64);
		_indirect = [self buffer:32];
		_shapes = [self buffer:_info.candidatesMax * 4];
		_items = [self buffer:_info.itemsMax * 8];
		_locations = [self buffer:quads * 4];
		_heads = [_device newBufferWithLength:quads * 4 options:MTLResourceStorageModeShared];
		memset(_heads.contents, 0xFF, quads * 4);
		if (_work == nil || _edgeBits == nil || _shapes == nil || _items == nil || _locations == nil || _heads == nil) {
			if (error)
				*error = @"upscale: no memory for CMAA2";
			return NO;
		}
	}
	MTLPixelFormat mid = is_srgb(outputFormat) ? MTLPixelFormatRGBA16Float : outputFormat;
	BOOL larger = outputWidth > inputWidth || outputHeight > inputHeight;
	Class spatial = objc_getClass("MTLFXSpatialScalerDescriptor");
	if (_settings.metalfx && larger && spatial != Nil && [spatial supportsDevice:_device]) {
		MTLFXSpatialScalerDescriptor *d = [spatial new];
		d.colorTextureFormat = _settings.cmaa ? work : inputFormat;
		d.outputTextureFormat = mid;
		d.inputWidth = inputWidth;
		d.inputHeight = inputHeight;
		d.outputWidth = outputWidth;
		d.outputHeight = outputHeight;
		d.colorProcessingMode = is_float(inputFormat) ? MTLFXSpatialScalerColorProcessingModeHDR
		                        : is_srgb(inputFormat) ? MTLFXSpatialScalerColorProcessingModeLinear
		                                               : MTLFXSpatialScalerColorProcessingModePerceptual;
		_scaler = [d newSpatialScalerWithDevice:_device];
		if (_scaler != nil) {
			_mid = [self texture:mid width:outputWidth height:outputHeight
			               usage:_scaler.outputTextureUsage | MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget];
			_metalfxInUse = _mid != nil;
		}
		if (!_metalfxInUse)
			note("upscale: MetalFX refused %lux%lu to %lux%lu, bilinear instead", (unsigned long)inputWidth,
			     (unsigned long)inputHeight, (unsigned long)outputWidth, (unsigned long)outputHeight);
	}
	if (!_metalfxInUse && _settings.sharpness >= 0)
		_mid = [self texture:mid width:outputWidth height:outputHeight
		               usage:MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget];
	if ([self pipe:NO format:outputFormat] == nil || [self pipe:YES format:outputFormat] == nil ||
	    (_mid != nil && [self pipe:NO format:_mid.pixelFormat] == nil)) {
		if (error)
			*error = [NSString stringWithFormat:@"upscale: no pipeline for format %lu", (unsigned long)outputFormat];
		return NO;
	}
	return YES;
}

- (void)encodeCMAA:(id<MTLTexture>)input commandBuffer:(id<MTLCommandBuffer>)buffer
{
	if (input.pixelFormat == _work.pixelFormat) {
		id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
		[blit copyFromTexture:input toTexture:_work];
		[blit endEncoding];
	} else {
		id<MTLComputeCommandEncoder> c = [buffer computeCommandEncoder];
		[c setComputePipelineState:_copy];
		[c setTexture:input atIndex:0];
		[c setTexture:_work atIndex:1];
		[c dispatchThreads:MTLSizeMake(_inW, _inH, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[c endEncoding];
	}
	// One encoder per pass: the next pass's indirect arguments come from the one before
	id<MTLComputeCommandEncoder> c = [buffer computeCommandEncoder];
	[c setComputePipelineState:_edges];
	[c setTexture:input atIndex:0];
	[c setTexture:_edgeBits atIndex:1];
	[c setBuffer:_control offset:0 atIndex:0];
	[c setBuffer:_shapes offset:0 atIndex:1];
	[c setBuffer:_heads offset:0 atIndex:2];
	[c setBytes:&_info length:sizeof(_info) atIndex:3];
	NSUInteger quadsX = (_inW + 1) / 2, quadsY = (_inH + 1) / 2;
	[c dispatchThreadgroups:MTLSizeMake((quadsX + 13) / 14, (quadsY + 13) / 14, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[c endEncoding];
	for (uint32_t which = 0; which < 2; which++) {
		c = [buffer computeCommandEncoder];
		[c setComputePipelineState:_args];
		[c setBuffer:_control offset:0 atIndex:0];
		[c setBuffer:_indirect offset:0 atIndex:1];
		[c setBytes:&which length:sizeof(which) atIndex:2];
		[c setBytes:&_info length:sizeof(_info) atIndex:3];
		[c dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
		[c endEncoding];
		c = [buffer computeCommandEncoder];
		[c setBytes:&_info length:sizeof(_info) atIndex:3];
		[c setBuffer:_control offset:0 atIndex:0];
		[c setBuffer:_heads offset:0 atIndex:2];
		[c setBuffer:_items offset:0 atIndex:4];
		if (which == 0) {
			[c setComputePipelineState:_candidates];
			[c setTexture:input atIndex:0];
			[c setTexture:_edgeBits atIndex:1];
			[c setBuffer:_shapes offset:0 atIndex:1];
			[c setBuffer:_locations offset:0 atIndex:5];
			[c dispatchThreadgroupsWithIndirectBuffer:_indirect indirectBufferOffset:0
			                    threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
		} else {
			[c setComputePipelineState:_apply];
			[c setTexture:input atIndex:0];
			[c setTexture:_work atIndex:1];
			[c setBuffer:_locations offset:0 atIndex:1];
			[c dispatchThreadgroupsWithIndirectBuffer:_indirect indirectBufferOffset:16
			                    threadsPerThreadgroup:MTLSizeMake(4, 32, 1)];
		}
		[c endEncoding];
	}
}

- (void)draw:(id<MTLTexture>)source to:(id<MTLTexture>)target sharpen:(BOOL)sharpen commandBuffer:(id<MTLCommandBuffer>)buffer
{
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = target;
	pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> r = [buffer renderCommandEncoderWithDescriptor:pass];
	[r setRenderPipelineState:[self pipe:sharpen format:target.pixelFormat]];
	[r setFragmentTexture:source atIndex:0];
	if (sharpen) {
		float sharpness = exp2f(-_settings.sharpness);
		[r setFragmentBytes:&sharpness length:sizeof(sharpness) atIndex:0];
	} else {
		float size[2] = { (float)target.width, (float)target.height };
		[r setFragmentBytes:size length:sizeof(size) atIndex:0];
	}
	[r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[r endEncoding];
}

- (void)encode:(id<MTLTexture>)input to:(id<MTLTexture>)output commandBuffer:(id<MTLCommandBuffer>)buffer
{
	id<MTLTexture> source = input;
	if (_settings.cmaa) {
		[self encodeCMAA:input commandBuffer:buffer];
		source = _work;
	}
	BOOL sharpen = _settings.sharpness >= 0;
	if (_metalfxInUse) {
		_scaler.colorTexture = source;
		_scaler.outputTexture = _mid;
		_scaler.inputContentWidth = _inW;
		_scaler.inputContentHeight = _inH;
		[_scaler encodeToCommandBuffer:buffer];
		source = _mid;
	} else if (sharpen) {
		[self draw:source to:_mid sharpen:NO commandBuffer:buffer];
		source = _mid;
	}
	[self draw:source to:output sharpen:sharpen && source == _mid commandBuffer:buffer];
}

@end

id<MTLComputePipelineState> FGUpscaleKernel(id<MTLDevice> device, NSString *name)
{
	static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
	static NSMutableDictionary<NSString *, id<MTLComputePipelineState>> *made;
	NSString *key = [NSString stringWithFormat:@"%llu/%@", device.registryID, name];
	os_unfair_lock_lock(&lock);
	id<MTLComputePipelineState> state = made[key];
	os_unfair_lock_unlock(&lock);
	if (state != nil)
		return state;
	id<MTLFunction> function = [FGUpscaleLibrary(device, NULL) newFunctionWithName:name];
	state = function != nil ? [device newComputePipelineStateWithFunction:function error:nil] : nil;
	if (state == nil)
		return nil;
	os_unfair_lock_lock(&lock);
	if (made == nil)
		made = [NSMutableDictionary dictionary];
	made[key] = state;
	os_unfair_lock_unlock(&lock);
	return state;
}

typedef struct {
	float sharpness;
	uint32_t hdr;
} RcasParams;

BOOL FGSharpen(id<MTLComputeCommandEncoder> encoder, id<MTLTexture> input, id<MTLTexture> output, float stops, BOOL hdr)
{
	id<MTLComputePipelineState> rcas = FGUpscaleKernel(output.device, @"rcas_k");
	if (rcas == nil)
		return NO;
	RcasParams params = { exp2f(-stops), hdr ? 1 : 0 };
	[encoder setComputePipelineState:rcas];
	[encoder setTexture:input atIndex:0];
	[encoder setTexture:output atIndex:1];
	[encoder setBytes:&params length:sizeof(params) atIndex:0];
	[encoder dispatchThreads:MTLSizeMake(output.width, output.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	return YES;
}

BOOL FGSharpen4(id<MTL4ComputeCommandEncoder> encoder, id<MTL4ArgumentTable> table, id<MTLTexture> input,
                id<MTLTexture> output, float stops, BOOL hdr, id<MTLBuffer> params, NSUInteger offset)
{
	id<MTLComputePipelineState> rcas = FGUpscaleKernel(output.device, @"rcas_k");
	if (rcas == nil)
		return NO;
	*(RcasParams *)((char *)params.contents + offset) = (RcasParams){ exp2f(-stops), hdr ? 1 : 0 };
	[table setTexture:input.gpuResourceID atIndex:0];
	[table setTexture:output.gpuResourceID atIndex:1];
	[table setAddress:params.gpuAddress + offset atIndex:0];
	[encoder setComputePipelineState:rcas];
	[encoder setArgumentTable:table];
	[encoder dispatchThreads:MTLSizeMake(output.width, output.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	return YES;
}

static os_unfair_lock current_lock = OS_UNFAIR_LOCK_INIT;
API_AVAILABLE(macos(26.0)) static __weak FGUpscale *current;

static NSView *view_of(CALayer *layer)
{
	for (CALayer *at = layer; at != nil; at = at.superlayer)
		if ([at.delegate isKindOfClass:[NSView class]])
			return (NSView *)at.delegate;
	return nil;
}

// What our layer is set up for: the game's frames and where they show
typedef struct {
	CGSize drawable, native;
	CGRect shown;
	CGFloat scale;
	MTLPixelFormat format;
} Placement;

static BOOL same_placement(Placement a, Placement b)
{
	return CGSizeEqualToSize(a.drawable, b.drawable) && CGSizeEqualToSize(a.native, b.native) &&
	       CGRectEqualToRect(a.shown, b.shown) && a.scale == b.scale && a.format == b.format;
}

@implementation FGUpscale {
	CAMetalLayer *_game, *_layer;
	id<MTLDevice> _device;
	FGUpscaleSettings _settings;
	os_unfair_lock _lock;
	BOOL _stopped, _dump, _preparing;
	// Main thread: the placement in use and the one being prepared
	Placement _placed, _wanted;
	// Behind the lock: what the present thread may use
	FGUpscaler *_ready;
	CAMetalLayer *_readyLayer;
	NSUInteger _inW, _inH;
	MTLPixelFormat _inF;
	// Present thread: the upscaler nextDrawableFor: checked, for encode:
	FGUpscaler *_current;
	dispatch_queue_t _queue;
	dispatch_source_t _timer;
	char _said[200];
}

+ (instancetype)upscaleForLayer:(CAMetalLayer *)layer device:(id<MTLDevice>)device
{
	const char *text = getenv("CARTOUCHE_FRAMEGEN_UPSCALE");
	FGUpscaleSettings settings;
	if (text == NULL || text[0] == 0 || strcmp(text, "0") == 0)
		return nil;
	if (!FGUpscaleParse(text, &settings)) {
		note("upscale: unknown method %s", text);
		return nil;
	}
	FGUpscale *upscale = [self new];
	upscale->_game = layer;
	upscale->_device = device;
	upscale->_settings = settings;
	upscale->_lock = OS_UNFAIR_LOCK_INIT;
	upscale->_dump = getenv("CARTOUCHE_FRAMEGEN_DUMP") != NULL;
	upscale->_queue = dispatch_queue_create("cartouche upscale", DISPATCH_QUEUE_SERIAL);
	os_unfair_lock_lock(&current_lock);
	current = upscale;
	os_unfair_lock_unlock(&current_lock);
	// The layer's place and the screen's density change with the window: asked again twice a second
	__weak FGUpscale *weak = upscale;
	upscale->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	dispatch_source_set_timer(upscale->_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 20);
	dispatch_source_set_event_handler(upscale->_timer, ^{
		[weak watch];
	});
	dispatch_resume(upscale->_timer);
	return upscale;
}

- (void)say:(NSString *)line
{
	if (strcmp(line.UTF8String, _said) != 0) {
		strlcpy(_said, line.UTF8String, sizeof(_said));
		note("%s", _said);
	}
}

// Main thread: where the game's frame shows in its layer, and at how many pixels. A new placement
// is prepared off the game's threads (MetalFX and the kernels take a while to build the first
// time); meanwhile our layer hides and the game's frames go to its own layer.
- (void)watch
{
	os_unfair_lock_lock(&_lock);
	BOOL stopped = _stopped;
	os_unfair_lock_unlock(&_lock);
	NSView *view = view_of(_game);
	NSWindow *window = view.window;
	if (stopped || window == nil)
		return;
	Placement want = { .drawable = _game.drawableSize, .scale = window.backingScaleFactor, .format = _game.pixelFormat };
	CGRect bounds = _game.bounds;
	want.shown = bounds;
	NSString *gravity = _game.contentsGravity;
	if ([gravity isEqualToString:kCAGravityResizeAspect] && want.drawable.width > 0 && want.drawable.height > 0) {
		CGFloat fit = fmin(bounds.size.width / want.drawable.width, bounds.size.height / want.drawable.height);
		want.shown.size = CGSizeMake(want.drawable.width * fit, want.drawable.height * fit);
		want.shown.origin = CGPointMake(CGRectGetMidX(bounds) - want.shown.size.width / 2,
		                                CGRectGetMidY(bounds) - want.shown.size.height / 2);
	} else if (![gravity isEqualToString:kCAGravityResize]) {
		[self take:nil placement:want];
		[self say:[NSString stringWithFormat:@"upscale off: gravity %@", gravity]];
		return;
	}
	want.native = CGSizeMake(round(want.shown.size.width * want.scale), round(want.shown.size.height * want.scale));
	if (want.native.width <= want.drawable.width && want.native.height <= want.drawable.height) {
		[self take:nil placement:want];
		[self say:@"upscale off: the game renders at the screen's size"];
		return;
	}
	if (_layer != nil && same_placement(want, _placed))
		return;
	if (_layer != nil)
		_layer.hidden = YES;
	if (_preparing && same_placement(want, _wanted))
		return;
	_preparing = YES;
	_wanted = want;
	FGUpscaleSettings settings = _settings;
	id<MTLDevice> device = _device;
	__weak FGUpscale *weak = self;
	dispatch_async(_queue, ^{
		NSString *error = nil;
		FGUpscaler *upscaler = [[FGUpscaler alloc] initWithDevice:device settings:settings error:&error];
		if (upscaler != nil &&
		    ![upscaler prepareInputWidth:(NSUInteger)want.drawable.width height:(NSUInteger)want.drawable.height format:want.format
		                     outputWidth:(NSUInteger)want.native.width height:(NSUInteger)want.native.height format:want.format
		                           error:&error])
			upscaler = nil;
		dispatch_async(dispatch_get_main_queue(), ^{
			[weak prepared:upscaler placement:want error:error];
		});
	});
}

- (void)prepared:(FGUpscaler *)upscaler placement:(Placement)placement error:(NSString *)error
{
	if (!same_placement(placement, _wanted))
		return;
	_preparing = NO;
	if (upscaler == nil) {
		note("upscale off: %s", error.UTF8String);
		[self stop];
		return;
	}
	CAMetalLayer *layer = _layer;
	if (layer == nil) {
		layer = [CAMetalLayer layer];
		layer.device = _device;
		layer.opaque = YES;
		layer.maximumDrawableCount = 3;
		layer.framebufferOnly = !_dump;
		layer.name = @"cartouche upscale";
	}
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	layer.pixelFormat = placement.format;
	layer.colorspace = _game.colorspace;
	layer.wantsExtendedDynamicRangeContent = _game.wantsExtendedDynamicRangeContent;
	layer.contentsScale = placement.scale;
	layer.frame = placement.shown;
	layer.drawableSize = placement.native;
	layer.hidden = NO;
	if (layer.superlayer != _game)
		[_game addSublayer:layer];
	[CATransaction commit];
	[self take:layer placement:placement];
	os_unfair_lock_lock(&_lock);
	_ready = upscaler;
	_inW = (NSUInteger)placement.drawable.width;
	_inH = (NSUInteger)placement.drawable.height;
	_inF = placement.format;
	os_unfair_lock_unlock(&_lock);
	FGUpscaleSettings s = upscaler.settings;
	NSString *line = [NSString stringWithFormat:@"upscale %.0fx%.0f -> %.0fx%.0f %s%s%s at %.0fx", placement.drawable.width,
	                                            placement.drawable.height, placement.native.width, placement.native.height,
	                                            s.cmaa ? "cmaa2+" : "", upscaler.metalfxInUse ? "metalfx" : "bilinear",
	                                            s.sharpness >= 0 ? "+rcas" : "", placement.scale];
	if (getenv("CARTOUCHE_FRAMEGEN_CLICKS") != NULL) {
		// Tests only: the game's layer on the screen, in global points from the top left
		NSView *view = view_of(_game);
		NSWindow *window = view.window;
		CGRect inView = view.layer != nil ? [view.layer convertRect:placement.shown fromLayer:_game] : placement.shown;
		if (view.isFlipped)
			inView.origin.y = view.bounds.size.height - CGRectGetMaxY(inView);
		static dispatch_once_t clicked;
		dispatch_once(&clicked, ^{
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
				post_clicks(view, inView);
			});
		});
		NSRect onScreen = [window convertRectToScreen:[view convertRect:inView toView:nil]];
		CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
		line = [line stringByAppendingFormat:@", layer %.1f,%.1f %.1fx%.1f points, window %ld, pid %d", NSMinX(onScreen),
		                                     top - NSMaxY(onScreen), NSWidth(onScreen), NSHeight(onScreen),
		                                     (long)window.windowNumber, getpid()];
	}
	[self say:line];
}

// Tests only (CARTOUCHE_FRAMEGEN_CLICKS="x,y;x,y...", shares of the layer from its top left): left
// clicks posted to the game's window from inside the process, as Wine takes them from the window
// server; the window itself still ignores the real mouse
static void post_clicks(NSView *view, CGRect layer)
{
	const char *text = getenv("CARTOUCHE_FRAMEGEN_CLICKS");
	NSWindow *window = view.window;
	if (text == NULL || window == nil)
		return;
	NSRect inWindow = [view convertRect:layer toView:nil];
	char *copy = strdup(text), *save = NULL;
	for (char *pair = strtok_r(copy, ";", &save); pair != NULL; pair = strtok_r(NULL, ";", &save)) {
		double fx, fy;
		if (sscanf(pair, "%lf,%lf", &fx, &fy) != 2)
			continue;
		double x = floor(fx * layer.size.width) + 0.5, y = floor(fy * layer.size.height) + 0.5;
		NSPoint at = NSMakePoint(NSMinX(inWindow) + x, NSMaxY(inWindow) - y);
		for (int up = 0; up < 2; up++)
			[NSApp postEvent:[NSEvent mouseEventWithType:up ? NSEventTypeLeftMouseUp : NSEventTypeLeftMouseDown location:at
			                               modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
			                                windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1]
			         atStart:NO];
		note("click posted at %.1f %.1f", x, y);
	}
	free(copy);
}

// Main thread: our layer, or none
- (void)take:(CAMetalLayer *)layer placement:(Placement)placement
{
	if (layer == nil && _layer != nil) {
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		[_layer removeFromSuperlayer];
		[CATransaction commit];
	}
	_layer = layer;
	_placed = placement;
	os_unfair_lock_lock(&_lock);
	_readyLayer = layer;
	if (layer == nil)
		_ready = nil;
	os_unfair_lock_unlock(&_lock);
}

- (id<CAMetalDrawable>)nextDrawableFor:(id<MTLTexture>)texture fits:(BOOL *)fitsOut
{
	os_unfair_lock_lock(&_lock);
	BOOL fits = !_stopped && _readyLayer != nil && _ready != nil && texture.width == _inW && texture.height == _inH &&
	            texture.pixelFormat == _inF;
	CAMetalLayer *layer = fits ? _readyLayer : nil;
	_current = fits ? _ready : nil;
	os_unfair_lock_unlock(&_lock);
	if (fitsOut != NULL)
		*fitsOut = fits;
	return [layer nextDrawable];
}

- (void)encode:(id<MTLTexture>)texture into:(id<CAMetalDrawable>)drawable commandBuffer:(id<MTLCommandBuffer>)buffer
{
	[_current encode:texture to:drawable.texture commandBuffer:buffer];
}

- (id<CAMetalDrawable>)drawableFrom:(id<MTLTexture>)texture commandBuffer:(id<MTLCommandBuffer>)buffer
{
	id<CAMetalDrawable> drawable = [self nextDrawableFor:texture fits:NULL];
	if (drawable != nil)
		[self encode:texture into:drawable commandBuffer:buffer];
	return drawable;
}

- (void)stop
{
	os_unfair_lock_lock(&_lock);
	_stopped = YES;
	os_unfair_lock_unlock(&_lock);
	__weak FGUpscale *weak = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		FGUpscale *upscale = weak;
		if (upscale == nil)
			return;
		dispatch_source_cancel(upscale->_timer);
		[upscale take:nil placement:(Placement){ 0 }];
		[upscale say:@"upscale off: stopped"];
	});
}

@end

void FGUpscaleStopAll(void)
{
	if (@available(macOS 26.0, *)) {
		os_unfair_lock_lock(&current_lock);
		FGUpscale *upscale = current;
		os_unfair_lock_unlock(&current_lock);
		[upscale stop];
	}
}

void FGDumpShown(id<MTLTexture> texture, id<MTLCommandBuffer> buffer)
{
	static char path[1024];
	static long first = -1, every, seen;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		const char *text = getenv("CARTOUCHE_FRAMEGEN_DUMP");
		if (text == NULL || text[0] != '/')
			return;
		strlcpy(path, text, sizeof(path));
		char *colon = strchr(path, ':');
		first = 60;
		if (colon != NULL) {
			*colon = 0;
			first = atol(colon + 1);
			char *more = strchr(colon + 1, ':');
			every = more != NULL ? atol(more + 1) : 0;
		}
	});
	if (first < 0)
		return;
	long at = seen++;
	if (at < first || (at > first && (every <= 0 || (at - first) % every != 0)))
		return;
	MTLPixelFormat format = texture.pixelFormat;
	BOOL bgra = format == MTLPixelFormatBGRA8Unorm || format == MTLPixelFormatBGRA8Unorm_sRGB;
	if (!bgra && format != MTLPixelFormatRGBA8Unorm && format != MTLPixelFormatRGBA8Unorm_sRGB) {
		note("dump: format %lu not written", (unsigned long)format);
		return;
	}
	NSUInteger width = texture.width, height = texture.height;
	id<MTLBuffer> pixels = [texture.device newBufferWithLength:width * height * 4 options:MTLResourceStorageModeShared];
	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	[blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
	           sourceSize:MTLSizeMake(width, height, 1) toBuffer:pixels destinationOffset:0
	destinationBytesPerRow:width * 4 destinationBytesPerImage:width * height * 4];
	[blit endEncoding];
	char file[1100];
	if (strstr(path, "%ld") != NULL)
		snprintf(file, sizeof(file), path, at);
	else
		strlcpy(file, path, sizeof(file));
	NSString *name = @(file);
	[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
		(void)done;
		NSMutableData *ppm = [NSMutableData dataWithData:[[NSString stringWithFormat:@"P6\n%lu %lu\n255\n", (unsigned long)width,
		                                                                              (unsigned long)height]
		                                                     dataUsingEncoding:NSASCIIStringEncoding]];
		const uint8_t *p = pixels.contents;
		NSMutableData *rgb = [NSMutableData dataWithLength:width * height * 3];
		uint8_t *o = rgb.mutableBytes;
		for (NSUInteger i = 0; i < width * height; i++) {
			o[i * 3 + 0] = p[i * 4 + (bgra ? 2 : 0)];
			o[i * 3 + 1] = p[i * 4 + 1];
			o[i * 3 + 2] = p[i * 4 + (bgra ? 0 : 2)];
		}
		[ppm appendData:rgb];
		[ppm writeToFile:name atomically:YES];
	}];
}

