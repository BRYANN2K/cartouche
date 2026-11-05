// The game's temporal scaler taken over, see fg_temporal.h
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

#import "fg_formats.h"
#import "fg_temporal.h"
#import "fg_upscale.h"

static FGTemporalSettings settings;
static void (*say)(const char *format, ...);
static BOOL timing, metal4;
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
// Weak: the game decides when its scaler goes
static __weak id current_scaler;
static double buffer_ms[120];
static unsigned long buffer_count;
static const char key, own_key;
static _Thread_local BOOL owning;

@interface FGTemporalState : NSObject {
@public
	id<MTLComputePipelineState> reactive;
	id<MTLTexture> outputs[2], mask, previous[2], generated;
	id fx;
	// Metal 4: a residency set for our textures, an argument table, a ring of kernel settings, and
	// textures replaced lately, kept while the GPU may still read them (MTL4 buffers retain nothing)
	id set, table;
	id<MTLBuffer> params;
	NSMutableArray *retired;
	unsigned long retiredAt;
	int turn, at, slot;
	BOOL hdr, refused, stale, unready, warned;
	unsigned long frames;
}
@end

@implementation FGTemporalState
@end

FGTemporalSettings FGTemporalDefaults(void)
{
	return (FGTemporalSettings){ .enabled = YES, .sharpness = 0.25f, .jitter = 1, .exposure = -1 };
}

BOOL FGTemporalParse(const char *text, FGTemporalSettings *out)
{
	if (text == NULL)
		return YES;
	if (strcmp(text, "off") == 0 || strcmp(text, "0") == 0) {
		out->enabled = NO;
		return YES;
	}
	BOOL known = YES;
	char *copy = strdup(text), *save = NULL;
	for (char *pair = strtok_r(copy, ",", &save); pair != NULL; pair = strtok_r(NULL, ",", &save)) {
		char name[32];
		float value;
		if (sscanf(pair, "%31[^=]=%f", name, &value) != 2)
			known = NO;
		else if (strcmp(name, "sharpness") == 0)
			out->sharpness = value;
		else if (strcmp(name, "jitter") == 0)
			out->jitter = value;
		else if (strcmp(name, "exposure") == 0)
			out->exposure = value > 0 ? 1 : value < 0 ? -1 : 0;
		else if (strcmp(name, "mv_jittered") == 0)
			out->mvJittered = value != 0;
		else if (strcmp(name, "reactive") == 0)
			out->reactive = value > 0 ? value : 0;
		// Past int's range, or NaN, the conversion is undefined; such a value is a typo
		else if (strcmp(name, "fx") == 0 && !(value >= -2147483648.0f && value < 2147483648.0f))
			known = NO;
		else if (strcmp(name, "fx") == 0)
			out->fx = (int)value;
		else if (strcmp(name, "bounds") == 0)
			out->bounds = value > 0 ? 1 : value < 0 ? -1 : 0;
		else
			known = NO;
	}
	free(copy);
	return known;
}

void FGTemporalStart(void (*log)(const char *format, ...))
{
	say = log;
	settings = FGTemporalDefaults();
	const char *text = getenv("CARTOUCHE_FRAMEGEN_TEMPORAL");
	if (!FGTemporalParse(text, &settings))
		say("temporal: ignored part of %s", text);
	const char *stats = getenv("CARTOUCHE_FRAMEGEN_STATS");
	timing = stats != NULL && strcmp(stats, "1") == 0;
	const char *temporal4 = getenv("CARTOUCHE_FRAMEGEN_TEMPORAL4");
	metal4 = temporal4 != NULL && strcmp(temporal4, "1") == 0;
}

BOOL FGTemporalMetal4(void)
{
	return metal4;
}

void FGTemporalTune(id descriptor)
{
	// By name: the library keeps MetalFX's classes out of its strong references
	Class kind = objc_getClass("MTLFXTemporalScalerDescriptor");
	if (!settings.enabled || kind == Nil || ![descriptor isKindOfClass:kind])
		return;
	MTLFXTemporalScalerDescriptor *d = descriptor;
	if (settings.exposure >= 0)
		d.autoExposureEnabled = settings.exposure == 1;
	if (settings.bounds > 0 && d.inputWidth > 0) {
		d.inputContentPropertiesEnabled = YES;
		d.inputContentMinScale = d.inputContentMaxScale = (float)d.outputWidth / (float)d.inputWidth;
	} else if (settings.bounds < 0)
		d.inputContentPropertiesEnabled = NO;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 270000
	if (@available(macOS 27.0, *)) {
		if (settings.mvJittered)
			d.jitteredMotionVectorsEnabled = YES;
	}
#endif
	if (settings.reactive > 0 && !d.reactiveMaskTextureEnabled) {
		d.reactiveMaskTextureEnabled = YES;
		d.reactiveMaskTextureFormat = MTLPixelFormatR8Unorm;
	}
	say("temporal: scaler %lux%lu to %lux%lu color=%lu output=%lu motion=%lu auto_exposure=%d reactive=%d "
	    "dynamic=%d %.2f..%.2f sharpness=%.2f jitter=%.2f",
	    (unsigned long)d.inputWidth, (unsigned long)d.inputHeight, (unsigned long)d.outputWidth,
	    (unsigned long)d.outputHeight, (unsigned long)d.colorTextureFormat, (unsigned long)d.outputTextureFormat,
	    (unsigned long)d.motionTextureFormat, d.autoExposureEnabled, d.reactiveMaskTextureEnabled,
	    d.inputContentPropertiesEnabled, d.inputContentMinScale, d.inputContentMaxScale, settings.sharpness,
	    settings.jitter);
}

void FGTemporalAdopt(id scaler, id<MTLDevice> device)
{
	if (scaler == nil)
		return;
	os_unfair_lock_lock(&lock);
	current_scaler = scaler;
	os_unfair_lock_unlock(&lock);
	if (!settings.enabled)
		return;
	FGTemporalState *state = [FGTemporalState new];
	// A Metal 4 scaler is left as made unless CARTOUCHE_FRAMEGEN_TEMPORAL4 opted in: no kernels
	// for it. Otherwise they are made with the scaler, which stalls the game once already (cached
	// per device): a reactive mask is needed from the first encode
	if (metal4 || [scaler conformsToProtocol:@protocol(MTLFXTemporalScaler)]) {
		state->reactive = FGUpscaleKernel(device, @"reactive_temporal");
		if (state->reactive == nil || FGUpscaleKernel(device, @"rcas_k") == nil) {
			say("temporal: kernels failed");
			return;
		}
	}
	state->retired = [NSMutableArray array];
	objc_setAssociatedObject(scaler, &key, state, OBJC_ASSOCIATION_RETAIN);
}

void FGTemporalOwn(BOOL on)
{
	owning = on;
}

BOOL FGTemporalClaim(id scaler)
{
	if (owning && scaler != nil)
		objc_setAssociatedObject(scaler, &own_key, @YES, OBJC_ASSOCIATION_RETAIN);
	return owning;
}

BOOL FGTemporalIsOwn(id scaler)
{
	return objc_getAssociatedObject(scaler, &own_key) != nil;
}

id FGTemporalScaler(void)
{
	os_unfair_lock_lock(&lock);
	id scaler = current_scaler;
	os_unfair_lock_unlock(&lock);
	return scaler;
}

static int ascending(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

double FGTemporalBufferMillis(void)
{
	double sorted[120];
	os_unfair_lock_lock(&lock);
	unsigned long count = buffer_count < 120 ? buffer_count : 120;
	memcpy(sorted, buffer_ms, sizeof(sorted));
	os_unfair_lock_unlock(&lock);
	if (count == 0)
		return 0;
	qsort(sorted, count, sizeof(*sorted), ascending);
	return sorted[count / 2];
}

static void time_buffer(id<MTLCommandBuffer> buffer)
{
	[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
		double ms = (done.GPUEndTime - done.GPUStartTime) * 1000;
		if (ms <= 0)
			return;
		os_unfair_lock_lock(&lock);
		unsigned long count = ++buffer_count;
		buffer_ms[count % 120] = ms;
		os_unfair_lock_unlock(&lock);
		if (count % 120 == 0)
			say("temporal: buffer gpu p50=%.3f ms %s", FGTemporalBufferMillis(), settings.enabled ? "ours" : "dxmt");
	}];
}

static id<MTLTexture> texture(id<MTLDevice> device, MTLPixelFormat format, NSUInteger width, NSUInteger height,
                              MTLTextureUsage usage)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
	                                                                             width:width
	                                                                            height:height
	                                                                         mipmapped:NO];
	d.usage = usage;
	d.storageMode = MTLStorageModePrivate;
	return [device newTextureWithDescriptor:d];
}

// Tests only (fx): an interpolator after the scaler in the game's command buffer, its frame thrown
// away, to time the scaler and an interpolator apart (1) and made on the scaler (2)
extern _Atomic int FGCreatingInterpolator;

API_AVAILABLE(macos(26.0))
static void encode_probe(FGTemporalState *state, id<MTLFXTemporalScaler> s, id<MTLCommandBuffer> b,
                         id<MTLTexture> current, id<MTLTexture> previous)
{
	if (state->fx == nil && !state->refused) {
		MTLFXFrameInterpolatorDescriptor *d = [MTLFXFrameInterpolatorDescriptor new];
		d.colorTextureFormat = d.outputTextureFormat = current.pixelFormat;
		d.depthTextureFormat = s.depthTextureFormat;
		d.motionTextureFormat = s.motionTextureFormat;
		d.inputWidth = s.inputWidth;
		d.inputHeight = s.inputHeight;
		d.outputWidth = s.outputWidth;
		d.outputHeight = s.outputHeight;
		if (settings.fx == 2)
			d.scaler = s;
		atomic_store(&FGCreatingInterpolator, 1);
		id<MTLFXFrameInterpolator> fx = [d newFrameInterpolatorWithDevice:current.device];
		atomic_store(&FGCreatingInterpolator, 0);
		state->refused = fx == nil;
		say("temporal: probe interpolator %s, on the scaler %d", fx != nil ? "made" : "refused", settings.fx == 2);
		if (fx == nil)
			return;
		state->fx = fx;
		state->generated = texture(current.device, current.pixelFormat, current.width, current.height, fx.outputTextureUsage);
		fx.nearPlane = 0.1f;
		fx.farPlane = 200;
		fx.fieldOfView = 60;
		fx.aspectRatio = (float)current.width / (float)current.height;
		fx.shouldResetHistory = YES;
	}
	id<MTLFXFrameInterpolator> fx = state->fx;
	if (fx == nil)
		return;
	fx.colorTexture = current;
	fx.prevColorTexture = previous;
	fx.depthTexture = s.depthTexture;
	fx.motionTexture = s.motionTexture;
	fx.outputTexture = state->generated;
	fx.depthReversed = s.depthReversed;
	fx.motionVectorScaleX = s.motionVectorScaleX;
	fx.motionVectorScaleY = s.motionVectorScaleY;
	fx.jitterOffsetX = s.jitterOffsetX;
	fx.jitterOffsetY = s.jitterOffsetY;
	fx.deltaTime = 1.0f / 40;
	[fx encodeToCommandBuffer:b];
	fx.shouldResetHistory = NO;
}

static void retire(FGTemporalState *state, id<MTLTexture> texture)
{
	if (texture != nil)
		[state->retired addObject:texture];
	state->retiredAt = state->frames;
	state->stale = YES;
}

enum { ring = 16, stride = 256 };

API_AVAILABLE(macos(26.0))
static BOOL metal4_ready(FGTemporalState *state, id<MTLDevice> device)
{
	if (state->set == nil && !state->unready) {
		state->set = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
		MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
		d.maxTextureBindCount = 5;
		d.maxBufferBindCount = 1;
		state->table = [device newArgumentTableWithDescriptor:d error:nil];
		state->params = [device newBufferWithLength:(NSUInteger)(ring * stride) options:MTLResourceStorageModeShared];
		state->unready = state->set == nil || state->table == nil || state->params == nil;
		state->stale = YES;
		if (state->unready)
			say("temporal: Metal 4 resources failed, scaler left as made");
	}
	return !state->unready;
}

API_AVAILABLE(macos(26.0))
static void metal4_resident(FGTemporalState *state, id<MTL4CommandBuffer> buffer)
{
	id<MTLResidencySet> set = state->set;
	if (state->stale) {
		[set removeAllAllocations];
		id<MTLAllocation> all[6] = { state->outputs[0], state->outputs[1], state->mask, state->previous[0], state->previous[1],
			                         state->params };
		for (int i = 0; i < 6; i++)
			if (all[i] != nil)
				[set addAllocation:all[i]];
		for (id<MTLAllocation> old in state->retired)
			[set addAllocation:old];
		[set commit];
		[set requestResidency];
		state->stale = NO;
	}
	[buffer useResidencySet:set];
}

API_AVAILABLE(macos(26.0))
static NSUInteger metal4_slot(FGTemporalState *state)
{
	state->slot = (state->slot + 1) % ring;
	return (NSUInteger)(state->slot * stride);
}

// Our pass in a Metal 4 buffer: after all the queue did before it (the game's passes, the scaler),
// and before all it does next, as the scaler's fence when it has one
API_AVAILABLE(macos(26.0))
static id<MTL4ComputeCommandEncoder> metal4_open(id<MTL4CommandBuffer> buffer, id<MTLFence> fence)
{
	id<MTL4ComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
	if (fence != nil)
		[encoder waitForFence:fence beforeEncoderStages:MTLStageDispatch];
	[encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
	return encoder;
}

API_AVAILABLE(macos(26.0))
static void metal4_close(id<MTL4ComputeCommandEncoder> encoder, id<MTLFence> fence)
{
	[encoder barrierAfterStages:MTLStageDispatch beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
	if (fence != nil)
		[encoder updateFence:fence afterEncoderStages:MTLStageDispatch];
	[encoder endEncoding];
}

// The mask's textures at the colour's size; NO without colour or motion
static BOOL prepare_mask(FGTemporalState *state, id<MTLFXTemporalScaler> scaler)
{
	id<MTLTexture> color = scaler.colorTexture;
	if (color == nil || scaler.motionTexture == nil)
		return NO;
	NSUInteger w = color.width, h = color.height;
	if (state->mask == nil || state->mask.width != w || state->mask.height != h) {
		retire(state, state->mask);
		state->mask = texture(color.device, MTLPixelFormatR8Unorm, w, h, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
		for (int i = 0; i < 2; i++) {
			retire(state, state->previous[i]);
			state->previous[i] = texture(color.device, MTLPixelFormatRGBA16Float, w, h,
			                             MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
		}
	}
	return YES;
}

// The mask for this frame, from the colour and the one kept from the last frame
static void encode_mask(FGTemporalState *state, id<MTLFXTemporalScaler> scaler, id buffer, BOOL mtl4)
{
	id<MTLTexture> color = scaler.colorTexture, motion = scaler.motionTexture;
	id<MTLTexture> before = state->previous[state->turn], keep = state->previous[state->turn ^ 1];
	state->turn ^= 1;
	BOOL fresh = state->frames == 0 || scaler.reset;
	float params[4] = { scaler.motionVectorScaleX, scaler.motionVectorScaleY, fresh ? 0 : settings.reactive * 8, 0.04f };
	id<MTLTexture> textures[5] = { color, before, motion, state->mask, keep };
	MTLSize grid = MTLSizeMake(color.width, color.height, 1), group = MTLSizeMake(16, 16, 1);
	if (mtl4) {
		if (@available(macOS 26.0, *)) {
			NSUInteger offset = metal4_slot(state);
			memcpy((char *)state->params.contents + offset, params, sizeof(params));
			id<MTL4ArgumentTable> table = state->table;
			for (int i = 0; i < 5; i++)
				[table setTexture:textures[i].gpuResourceID atIndex:(NSUInteger)i];
			[table setAddress:state->params.gpuAddress + offset atIndex:0];
			id<MTL4ComputeCommandEncoder> encoder = metal4_open(buffer, nil);
			[encoder setComputePipelineState:state->reactive];
			[encoder setArgumentTable:table];
			[encoder dispatchThreads:grid threadsPerThreadgroup:group];
			metal4_close(encoder, nil);
		}
	} else {
		id<MTLComputeCommandEncoder> encoder = [(id<MTLCommandBuffer>)buffer computeCommandEncoder];
		[encoder setComputePipelineState:state->reactive];
		for (int i = 0; i < 5; i++)
			[encoder setTexture:textures[i] atIndex:(NSUInteger)i];
		[encoder setBytes:params length:sizeof(params) atIndex:0];
		[encoder dispatchThreads:grid threadsPerThreadgroup:group];
		[encoder endEncoding];
	}
	scaler.reactiveMaskTexture = state->mask;
}

// Encodes since the last FGTemporalTakeEncodes: a scaler made and never used is no upscaling
static _Atomic unsigned long encodes;

unsigned long FGTemporalTakeEncodes(void)
{
	return atomic_exchange(&encodes, 0);
}

// Classic (DXMT) and Metal 4 (MTL4FX, as D3DMetal may) scalers alike: the properties are shared,
// only the command buffer and how our passes go into it differ
void FGTemporalEncode(id scaler, SEL selector, id buffer, IMP next)
{
	atomic_fetch_add(&encodes, 1);
	void (*encode)(id, SEL, id) = (void (*)(id, SEL, id))next;
	FGTemporalState *state = settings.enabled ? objc_getAssociatedObject(scaler, &key) : nil;
	BOOL classic = [buffer conformsToProtocol:@protocol(MTLCommandBuffer)], mtl4 = NO;
	if (@available(macOS 26.0, *))
		mtl4 = !classic && metal4 && [buffer conformsToProtocol:@protocol(MTL4CommandBuffer)];
	if (timing && classic)
		time_buffer(buffer);
	id<MTLFXTemporalScaler> s = scaler;
	id<MTLTexture> output = s.outputTexture;
	BOOL ready = state != nil && state->reactive != nil && (classic || mtl4);
	if (ready && mtl4) {
		if (@available(macOS 26.0, *))
			ready = metal4_ready(state, output != nil ? output.device : s.colorTexture.device);
	}
	if (!ready) {
		if (state != nil && !classic && !state->warned) {
			state->warned = YES;
			say("temporal: Metal 4 scaler left as made");
		}
		encode(scaler, selector, buffer);
		return;
	}
	float jx = s.jitterOffsetX, jy = s.jitterOffsetY;
	if (settings.jitter != 1) {
		s.jitterOffsetX = jx * settings.jitter;
		s.jitterOffsetY = jy * settings.jitter;
	}
	if (state->retired.count > 0 && state->frames - state->retiredAt > 8) {
		[state->retired removeAllObjects];
		state->stale = YES;
	}
	BOOL masked = settings.reactive > 0 && prepare_mask(state, s);
	BOOL sharpen = settings.sharpness >= 0 && output != nil && (output.usage & MTLTextureUsageShaderWrite) != 0 &&
		output.textureType == MTLTextureType2D;
	// Two outputs in turn: the last one stays for an interpolator
	state->at ^= 1;
	id<MTLTexture> mine = state->outputs[state->at];
	if (sharpen && (mine == nil || mine.width != output.width || mine.height != output.height ||
	                mine.pixelFormat != output.pixelFormat)) {
		for (int i = 0; i < 2; i++) {
			retire(state, state->outputs[i]);
			state->outputs[i] = texture(output.device, output.pixelFormat, output.width, output.height,
			                            s.outputTextureUsage | MTLTextureUsageShaderRead);
		}
		mine = state->outputs[state->at];
		state->hdr = is_float(output.pixelFormat);
	}
	if (mtl4 && (masked || sharpen)) {
		if (@available(macOS 26.0, *))
			metal4_resident(state, buffer);
	}
	if (masked)
		encode_mask(state, s, buffer, mtl4);
	if (sharpen)
		s.outputTexture = mine;
	encode(scaler, selector, buffer);
	if (state->frames++ == 0)
		say("temporal: in use output=%lux%lu format=%lu sharpen=%d hdr=%d fence=%d mtl4=%d", (unsigned long)output.width,
		    (unsigned long)output.height, (unsigned long)output.pixelFormat, sharpen, state->hdr, s.fence != nil, mtl4);
	if (settings.jitter != 1) {
		s.jitterOffsetX = jx;
		s.jitterOffsetY = jy;
	}
	if (!sharpen)
		return;
	s.outputTexture = output;
	// The runner may wait on the scaler's fence before reading its output: ours comes after
	id<MTLFence> fence = s.fence;
	if (mtl4) {
		if (@available(macOS 26.0, *)) {
			id<MTL4ComputeCommandEncoder> encoder = metal4_open(buffer, fence);
			FGSharpen4(encoder, state->table, mine, output, settings.sharpness, state->hdr, state->params, metal4_slot(state));
			metal4_close(encoder, fence);
		}
		return;
	}
	id<MTLCommandBuffer> b = buffer;
	if (settings.fx > 0 && state->frames > 1) {
		if (@available(macOS 26.0, *))
			encode_probe(state, s, b, mine, state->outputs[state->at ^ 1]);
	}
	id<MTLComputeCommandEncoder> encoder = [b computeCommandEncoder];
	if (fence != nil)
		[encoder waitForFence:fence];
	FGSharpen(encoder, mine, output, settings.sharpness, state->hdr);
	if (fence != nil)
		[encoder updateFence:fence];
	[encoder endEncoding];
}
