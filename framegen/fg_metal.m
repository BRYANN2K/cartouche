// The library's end of the zero-copy D3D11 path: Metal textures behind a game's D3D11 resources,
// handed over by DXMT's IMTLD3D11DeviceExt1 (framegen/dxmt) through the Wine bridge. probe hashes
// their texels, for tests; upscale runs our temporal chain in place of the game's upscaler,
// MetalFX's temporal scaler then RCAS, ordered against the game's own work by its D3D11 fence.
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <os/lock.h>
#import <math.h>
#import <objc/runtime.h>
#import <stdatomic.h>

#import "bridge/fg_bridge.h"
#import "fg_formats.h"
#import "fg_temporal.h"
#import "fg_upscale.h"

static os_unfair_lock metal_lock = OS_UNFAIR_LOCK_INIT;
static struct {
	id<MTLDevice> device;
	id<MTLCommandQueue> queue;
	id<MTLFXTemporalScaler> scaler;
	id<MTLTexture> scaled;
	MTLPixelFormat formats[fg_metal_textures];
	NSUInteger sizes[4];
	_Atomic uint64_t gpu_ns;
} up;

static int32_t fail(const char *why)
{
	fprintf(stderr, "framegen: metal %s\n", why);
	return -1;
}

static BOOL setup(id<MTLDevice> device)
{
	if (up.device == device)
		return up.queue != nil;
	up.device = device;
	up.queue = [device newCommandQueue];
	return up.queue != nil;
}

static uint32_t texel_bytes(MTLPixelFormat format)
{
	switch (format) {
	case MTLPixelFormatRGBA8Unorm:
	case MTLPixelFormatRGBA8Unorm_sRGB:
	case MTLPixelFormatBGRA8Unorm:
	case MTLPixelFormatRG16Float:
	case MTLPixelFormatR32Float:
	case MTLPixelFormatDepth32Float:
		return 4;
	case MTLPixelFormatRGBA16Float:
	case MTLPixelFormatRG32Float:
		return 8;
	default:
		return 0;
	}
}

// FNV-1a over the rows, without padding, as the scene hashes its staging copies
static uint64_t hash_rows(const uint8_t *p, size_t row, size_t rows)
{
	uint64_t h = 0xcbf29ce484222325ull;
	for (size_t i = 0; i < row * rows; i++)
		h = (h ^ p[i]) * 0x100000001b3ull;
	return h;
}

static int32_t probe(FGBridgeMetal *m, __strong id<MTLTexture> *textures, id<MTLSharedEvent> event)
{
	id<MTLCommandBuffer> commands = [up.queue commandBuffer];
	[commands encodeWaitForEvent:event value:m->wait];
	id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
	id<MTLBuffer> copies[fg_metal_textures] = { nil };
	for (int i = 0; i < fg_metal_textures; i++) {
		uint32_t bytes = textures[i] ? texel_bytes(textures[i].pixelFormat) : 0;
		if (bytes == 0)
			continue;
		NSUInteger w = textures[i].width, h = textures[i].height;
		copies[i] = [up.device newBufferWithLength:w * h * bytes options:MTLResourceStorageModeShared];
		[blit copyFromTexture:textures[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
		           sourceSize:MTLSizeMake(w, h, 1) toBuffer:copies[i] destinationOffset:0
		  destinationBytesPerRow:w * bytes destinationBytesPerImage:w * h * bytes];
	}
	[blit endEncoding];
	[commands encodeSignalEvent:event value:m->signal];
	[commands commit];
	[commands waitUntilCompleted];
	if (commands.status != MTLCommandBufferStatusCompleted)
		return fail("probe: the copy failed");
	for (int i = 0; i < fg_metal_textures; i++)
		if (copies[i])
			m->hash[i] = hash_rows(copies[i].contents, textures[i].width * texel_bytes(textures[i].pixelFormat),
			                       textures[i].height);
	return 0;
}

static BOOL same_scaler(__strong id<MTLTexture> *t)
{
	if (up.scaler == nil)
		return NO;
	for (int i = 0; i < fg_metal_textures; i++)
		if (up.formats[i] != t[i].pixelFormat)
			return NO;
	return up.sizes[0] == t[fg_metal_color].width && up.sizes[1] == t[fg_metal_color].height &&
	       up.sizes[2] == t[fg_metal_output].width && up.sizes[3] == t[fg_metal_output].height;
}

static int32_t upscale(FGBridgeMetal *m, __strong id<MTLTexture> *t, id<MTLSharedEvent> event)
{
	id<MTLTexture> color = t[fg_metal_color], output = t[fg_metal_output];
	if (!t[fg_metal_depth] || !t[fg_metal_motion] || !color || !output)
		return fail("upscale: a texture is missing");
	if (!(output.usage & MTLTextureUsageShaderWrite))
		return fail("upscale: the output is not writable (no UAV)");
	if (FGUpscaleKernel(up.device, @"rcas_k") == nil)
		return fail("upscale: no rcas kernel");
	if (!same_scaler(t)) {
		// By name, as in fg_temporal.m: no strong reference to MetalFX's classes
		Class kind = objc_getClass("MTLFXTemporalScalerDescriptor");
		if (kind == Nil)
			return fail("upscale: no MetalFX temporal scaler");
		MTLFXTemporalScalerDescriptor *d = [kind new];
		d.colorTextureFormat = color.pixelFormat;
		d.depthTextureFormat = t[fg_metal_depth].pixelFormat;
		d.motionTextureFormat = t[fg_metal_motion].pixelFormat;
		d.outputTextureFormat = output.pixelFormat;
		d.inputWidth = color.width;
		d.inputHeight = color.height;
		d.outputWidth = output.width;
		d.outputHeight = output.height;
		// Ours: the DLSS takeover hooks (fg_temporal.m) leave it alone
		FGTemporalOwn(YES);
		up.scaler = [d newTemporalScalerWithDevice:up.device];
		FGTemporalOwn(NO);
		if (up.scaler == nil)
			return fail("upscale: MetalFX refused the scaler");
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:output.pixelFormat
		                                                                              width:output.width
		                                                                             height:output.height
		                                                                          mipmapped:NO];
		td.storageMode = MTLStorageModePrivate;
		td.usage = up.scaler.outputTextureUsage | MTLTextureUsageShaderRead;
		up.scaled = [up.device newTextureWithDescriptor:td];
		for (int i = 0; i < fg_metal_textures; i++)
			up.formats[i] = t[i].pixelFormat;
		up.sizes[0] = color.width, up.sizes[1] = color.height, up.sizes[2] = output.width, up.sizes[3] = output.height;
		fprintf(stderr, "framegen: metal upscale %lux%lu -> %lux%lu color=%lu depth=%lu motion=%lu output=%lu\n",
		        (unsigned long)color.width, (unsigned long)color.height, (unsigned long)output.width,
		        (unsigned long)output.height, (unsigned long)color.pixelFormat,
		        (unsigned long)t[fg_metal_depth].pixelFormat, (unsigned long)t[fg_metal_motion].pixelFormat,
		        (unsigned long)output.pixelFormat);
	}
	id<MTLFXTemporalScaler> scaler = up.scaler;
	scaler.colorTexture = color;
	scaler.depthTexture = t[fg_metal_depth];
	scaler.motionTexture = t[fg_metal_motion];
	scaler.outputTexture = up.scaled;
	scaler.inputContentWidth = color.width;
	scaler.inputContentHeight = color.height;
	scaler.jitterOffsetX = m->jitter[0];
	scaler.jitterOffsetY = m->jitter[1];
	scaler.motionVectorScaleX = m->motion_scale[0];
	scaler.motionVectorScaleY = m->motion_scale[1];
	scaler.reset = m->reset != 0;
	scaler.depthReversed = NO;

	id<MTLCommandBuffer> commands = [up.queue commandBuffer];
	[commands encodeWaitForEvent:event value:m->wait];
	[scaler encodeToCommandBuffer:commands];
	id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
	// m->sharpness is RCAS's factor, 1 the sharpest: in stops for FGSharpen
	FGSharpen(compute, up.scaled, output, m->sharpness > 0 ? -log2f(m->sharpness) : INFINITY,
	          is_float(output.pixelFormat));
	[compute endEncoding];
	[commands encodeSignalEvent:event value:m->signal];
	[commands addCompletedHandler:^(id<MTLCommandBuffer> done) {
		if (done.status == MTLCommandBufferStatusCompleted)
			atomic_store(&up.gpu_ns, (uint64_t)((done.GPUEndTime - done.GPUStartTime) * 1e9));
	}];
	[commands commit];
	m->gpu_ms = (double)atomic_load(&up.gpu_ns) / 1e6;
	return 0;
}

// Called by the bridge's unix half on the game's thread. Handles are unretained id pointers that
// the game keeps alive for the length of the call.
__attribute__((visibility("default"))) int32_t cartouche_framegen_metal(FGBridgeMetal *m)
{
	@autoreleasepool {
		id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)(void *)(uintptr_t)m->event;
		if (event == nil || ![(id)event conformsToProtocol:@protocol(MTLSharedEvent)])
			return m->status = fail("no shared event");
		id<MTLTexture> textures[fg_metal_textures] = { nil };
		for (int i = 0; i < fg_metal_textures; i++) {
			id object = (__bridge id)(void *)(uintptr_t)m->texture[i];
			if (object == nil)
				continue;
			if (![object conformsToProtocol:@protocol(MTLTexture)])
				return m->status = fail("a handle is not a texture");
			textures[i] = object;
			m->width[i] = (uint32_t)textures[i].width;
			m->height[i] = (uint32_t)textures[i].height;
			m->format[i] = (uint32_t)textures[i].pixelFormat;
		}
		os_unfair_lock_lock(&metal_lock);
		id<MTLDevice> device = nil;
		for (int i = 0; i < fg_metal_textures && device == nil; i++)
			device = textures[i].device;
		int32_t status = device != nil && setup(device) ? 0 : fail("no queue");
		if (status == 0)
			status = m->op == fg_metal_probe ? probe(m, textures, event)
			       : m->op == fg_metal_upscale ? upscale(m, textures, event)
			                                  : fail("unknown op");
		os_unfair_lock_unlock(&metal_lock);
		return m->status = status;
	}
}
