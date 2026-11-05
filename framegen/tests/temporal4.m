// DLSS through MTL4FX, as a translator such as D3DMetal may drive it: the test window's 3D flight
// rendered at 853x480 with a Halton jitter, then brought to 1280x720 by an MTL4FX temporal scaler
// in MTL4 command buffers, alone and through fg_temporal, frames interleaved, each lane first in
// turn. Writes frames 60 to 67 of both and of the scene rendered at 1280x720 as PPM files for
// score, prints the median GPU time of each lane's command buffer, the median gap frame by frame,
// and how many of those frames are the same bytes in both lanes (all of them without
// CARTOUCHE_FRAMEGEN_TEMPORAL4=1, or with CARTOUCHE_FRAMEGEN_TEMPORAL=off).
// Usage: temporal4 <logo.svg> <out dir> [settings for ours] [fence] [16f]
//   fence: the scaler gets a fence, which the readback waits on; 16f: RGBA16Float output

#import <AppKit/AppKit.h>
#import <MetalFX/MetalFX.h>
#import <MetalKit/MetalKit.h>
#import <math.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#import "../fg_temporal.h"
#import "scene.h"

// fg_pipeline.m's, which this test does without
_Atomic int FGCreatingInterpolator;

enum { inW = 853, inH = 480, outW = 1280, outH = 720, frames = 300, first = 60, captures = 8 };
static const double step = 1.0 / 40;

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static Scene3DPipes pipes;
static id<MTLTexture> logo;

static void say(const char *format, ...)
{
	va_list args;
	va_start(args, format);
	fputs("framegen: ", stderr);
	vfprintf(stderr, format, args);
	fputc('\n', stderr);
	va_end(args);
}

static int ascending(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static float halton(long index, int base)
{
	float f = 1, r = 0;
	for (long i = index; i > 0; i /= base) {
		f /= (float)base;
		r += f * (float)(i % base);
	}
	return r;
}

static id<MTLTexture> texture(MTLPixelFormat format, NSUInteger w, NSUInteger h, MTLTextureUsage usage)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
	d.usage = usage;
	d.storageMode = MTLStorageModePrivate;
	return [device newTextureWithDescriptor:d];
}

// The scene at time t into color and depth, offset by (jx, jy) pixels; then its motion, unjittered
static void draw(id<MTLCommandBuffer> buffer, double t, float jx, float jy, id<MTLTexture> color, id<MTLTexture> depth,
                 id<MTLTexture> motion, id<MTLTexture> motionDepth)
{
	Scene3D s = { (float)t, (float)(960 * t / 60), (float)outW / outH, (float)(t - step), (float)(960 * (t - step) / 60) };
	Uniforms u = { { (float)outW, (float)outH }, 0, outH * 0.22f, 1 };
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = color;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0.11, 0.115, 0.14, 1);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.depthAttachment.texture = depth;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = 1;
	pass.depthAttachment.storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	[encoder setViewport:(MTLViewport){ jx, jy, (double)color.width, (double)color.height, 0, 1 }];
	scene3d_draw(encoder, &pipes, s, u, logo);
	[encoder endEncoding];
	if (motion == nil)
		return;
	pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = motion;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.depthAttachment.texture = motionDepth;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = 1;
	encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	scene3d_motion(encoder, &pipes, s, inW, inH);
	[encoder endEncoding];
}

static float half_to_float(uint16_t h)
{
	__fp16 v;
	memcpy(&v, &h, 2);
	return (float)v;
}

// RGBA8, BGRA8 or RGBA16Float pixels to a PPM file
static BOOL write_ppm(const char *path, const void *pixels, MTLPixelFormat format, int w, int h)
{
	FILE *f = fopen(path, "wb");
	if (f == NULL)
		return NO;
	fprintf(f, "P6 %d %d 255\n", w, h);
	unsigned char *row = malloc((size_t)w * 3);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			size_t i = (size_t)y * w + x;
			for (int c = 0; c < 3; c++) {
				float v;
				if (format == MTLPixelFormatRGBA16Float)
					v = half_to_float(((const uint16_t *)pixels)[i * 4 + c]);
				else
					v = ((const unsigned char *)pixels)[i * 4 + (format == MTLPixelFormatBGRA8Unorm ? 2 - c : c)] / 255.0f;
				row[x * 3 + c] = (unsigned char)lrintf(fminf(fmaxf(v, 0), 1) * 255);
			}
		}
		fwrite(row, 1, (size_t)w * 3, f);
	}
	free(row);
	fclose(f);
	return YES;
}

API_AVAILABLE(macos(26.0))
static int run(const char *dir, BOOL fenced, MTLPixelFormat format)
{
	id<MTL4CommandQueue> queue4 = [device newMTL4CommandQueue];
	id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:nil];
	id<MTL4CommandAllocator> allocator = [device newCommandAllocator];
	id<MTL4CommandBuffer> buffer4 = [device newCommandBuffer];
	MTLFXTemporalScalerDescriptor *d = [MTLFXTemporalScalerDescriptor new];
	d.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
	d.depthTextureFormat = MTLPixelFormatDepth32Float;
	d.motionTextureFormat = MTLPixelFormatRG16Float;
	d.outputTextureFormat = format;
	d.inputWidth = inW;
	d.inputHeight = inH;
	d.outputWidth = outW;
	d.outputHeight = outH;
	d.requiresSynchronousInitialization = YES;
	id<MTL4FXTemporalScaler> scalers[2];
	IMP encodes[2];
	MTLTextureUsage target = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	id<MTLTexture> outputs[2], color, depth, motion, motionDepth = texture(MTLPixelFormatDepth32Float, inW, inH, target);
	id<MTLResidencySet> set = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
	for (int i = 0; i < 2; i++) {
		if (i == 1) {
			FGTemporalStart(say);
			if (FGTemporalMetal4())
				FGTemporalTune(d);
		}
		scalers[i] = [d newTemporalScalerWithDevice:device compiler:compiler];
		if (scalers[i] == nil) {
			fputs("temporal4: no MTL4FX temporal scaler\n", stderr);
			return 1;
		}
		if (i == 1)
			FGTemporalAdopt(scalers[i], device);
		encodes[i] = [(id)scalers[i] methodForSelector:@selector(encodeToCommandBuffer:)];
		id<MTL4FXTemporalScaler> s = scalers[i];
		if (i == 0) {
			color = texture(d.colorTextureFormat, inW, inH, s.colorTextureUsage | target);
			depth = texture(d.depthTextureFormat, inW, inH, s.depthTextureUsage | target);
			motion = texture(d.motionTextureFormat, inW, inH, s.motionTextureUsage | target);
		}
		// A DLSS output is an unordered access view: shader writable
		outputs[i] = texture(format, outW, outH, s.outputTextureUsage | MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
		s.colorTexture = color;
		s.depthTexture = depth;
		s.motionTexture = motion;
		s.outputTexture = outputs[i];
		s.inputContentWidth = inW;
		s.inputContentHeight = inH;
		s.motionVectorScaleX = 1;
		s.motionVectorScaleY = 1;
		if (fenced)
			s.fence = [device newFence];
		[set addAllocation:outputs[i]];
	}
	NSUInteger bytes = outW * outH * (format == MTLPixelFormatRGBA16Float ? 8 : 4);
	id<MTLBuffer> readback[2];
	for (int i = 0; i < 2; i++) {
		readback[i] = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
		[set addAllocation:readback[i]];
	}
	for (id<MTLTexture> t in @[ color, depth, motion ])
		[set addAllocation:t];
	[set commit];
	[queue4 addResidencySet:set];
	id<MTLTexture> full = texture(MTLPixelFormatBGRA8Unorm, outW, outH, target);
	id<MTLTexture> fullDepth = texture(MTLPixelFormatDepth32Float, outW, outH, target);
	id<MTLBuffer> fullBack = [device newBufferWithLength:outW * outH * 4 options:MTLResourceStorageModeShared];
	double *ms[2] = { calloc(frames, sizeof(double)), calloc(frames, sizeof(double)) };
	// GPU time of a lane's buffer: timestamps at its start and end
	MTL4CounterHeapDescriptor *hd = [MTL4CounterHeapDescriptor new];
	hd.type = MTL4CounterHeapTypeTimestamp;
	hd.count = 2;
	id<MTL4CounterHeap> stamps = [device newCounterHeapWithDescriptor:hd error:nil];
	double tick = 1000.0 / (double)[device queryTimestampFrequency];
	id<MTLSharedEvent> event = [device newSharedEvent];
	uint64_t value = 0;
	int same = 0;
	char path[1024];
	for (int f = 0; f < frames; f++) {
		@autoreleasepool {
			double t = 1 + f * step;
			long phase = f % 16 + 1;
			float jx = halton(phase, 2) - 0.5f, jy = halton(phase, 3) - 0.5f;
			BOOL capture = f >= first && f < first + captures;
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			draw(buffer, t, jx, jy, color, depth, motion, motionDepth);
			if (capture) {
				draw(buffer, t, 0, 0, full, fullDepth, nil, nil);
				id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
				[blit copyFromTexture:full sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
				           sourceSize:MTLSizeMake(outW, outH, 1) toBuffer:fullBack destinationOffset:0
				destinationBytesPerRow:outW * 4 destinationBytesPerImage:outW * outH * 4];
				[blit endEncoding];
			}
			[buffer commit];
			[buffer waitUntilCompleted];
			// Lanes in turn first, so neither gains from going second
			for (int k = 0; k < 2; k++) {
				int i = k ^ (f & 1);
				id<MTL4FXTemporalScaler> s = scalers[i];
				// The viewport's offset, with the sign MetalFX takes (the other one costs 1.3 dB)
				s.jitterOffsetX = jx;
				s.jitterOffsetY = jy;
				s.reset = f == 0;
				[allocator reset];
				[buffer4 beginCommandBufferWithAllocator:allocator];
				[buffer4 writeTimestampIntoHeap:stamps atIndex:0];
				if (i == 0)
					((void (*)(id, SEL, id))encodes[0])(s, @selector(encodeToCommandBuffer:), buffer4);
				else
					FGTemporalEncode(s, @selector(encodeToCommandBuffer:), buffer4, encodes[1]);
				if (capture) {
					id<MTL4ComputeCommandEncoder> copy = [buffer4 computeCommandEncoder];
					if (fenced)
						[copy waitForFence:s.fence beforeEncoderStages:MTLStageBlit];
					else
						[copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
					[copy copyFromTexture:outputs[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
					           sourceSize:MTLSizeMake(outW, outH, 1) toBuffer:readback[i] destinationOffset:0
					destinationBytesPerRow:bytes / outH destinationBytesPerImage:bytes];
					[copy endEncoding];
				}
				[buffer4 writeTimestampIntoHeap:stamps atIndex:1];
				[buffer4 endCommandBuffer];
				id<MTL4CommandBuffer> list[1] = { buffer4 };
				[queue4 commit:list count:1];
				[queue4 signalEvent:event value:++value];
				if (![event waitUntilSignaledValue:value timeoutMS:5000]) {
					fputs("temporal4: the GPU did not finish\n", stderr);
					return 1;
				}
				const MTL4TimestampHeapEntry *at = [stamps resolveCounterRange:NSMakeRange(0, 2)].bytes;
				ms[i][f] = at != NULL ? (double)(at[1].timestamp - at[0].timestamp) * tick : -1;
			}
			if (capture) {
				int n = f - first;
				same += memcmp(readback[0].contents, readback[1].contents, bytes) == 0;
				snprintf(path, sizeof(path), "%s/full-%d.ppm", dir, n);
				write_ppm(path, fullBack.contents, MTLPixelFormatBGRA8Unorm, outW, outH);
				snprintf(path, sizeof(path), "%s/alone-%d.ppm", dir, n);
				write_ppm(path, readback[0].contents, format, outW, outH);
				snprintf(path, sizeof(path), "%s/ours-%d.ppm", dir, n);
				write_ppm(path, readback[1].contents, format, outW, outH);
			}
		}
	}
	// The first frames compile and warm up. The gap is taken frame by frame, between buffers run
	// one after the other, which the GPU's clock changes then slow alike
	int skip = frames / 5;
	double median[3], *gap = calloc(frames, sizeof(double));
	for (int f = 0; f < frames; f++)
		gap[f] = ms[1][f] - ms[0][f];
	double *sorted[3] = { ms[0], ms[1], gap };
	for (int i = 0; i < 3; i++) {
		qsort(sorted[i] + skip, (size_t)(frames - skip), sizeof(double), ascending);
		median[i] = sorted[i][skip + (frames - skip) / 2];
	}
	printf("temporal4 alone_ms=%.3f ours_ms=%.3f added_ms=%.3f identical=%d/%d\n", median[0], median[1], median[2],
	       same, captures);
	return 0;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 3) {
			fputs("usage: temporal4 <logo.svg> <out dir> [settings] [fence] [16f]\n", stderr);
			return 2;
		}
		if (argc > 3 && argv[3][0] != '\0')
			setenv("CARTOUCHE_FRAMEGEN_TEMPORAL", argv[3], 1);
		BOOL fenced = NO;
		MTLPixelFormat format = MTLPixelFormatRGBA8Unorm;
		for (int i = 4; i < argc; i++) {
			fenced |= strcmp(argv[i], "fence") == 0;
			if (strcmp(argv[i], "16f") == 0)
				format = MTLPixelFormatRGBA16Float;
		}
		device = MTLCreateSystemDefaultDevice();
		queue = [device newCommandQueue];
		NSError *failure = nil;
		id<MTLLibrary> library = [device newLibraryWithSource:shaders options:nil error:&failure];
		if (library == nil || !scene3d_build(device, library, &pipes, &failure)) {
			fprintf(stderr, "temporal4: %s\n", failure.localizedDescription.UTF8String);
			return 1;
		}
		NSImage *image = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
		NSRect big = NSMakeRect(0, 0, 512, 512);
		CGImageRef cg = [image CGImageForProposedRect:&big context:nil hints:nil];
		if (cg == NULL) {
			fprintf(stderr, "temporal4: cannot read %s\n", argv[1]);
			return 1;
		}
		logo = [[[MTKTextureLoader alloc] initWithDevice:device] newTextureWithCGImage:cg
		                                                                       options:@{ MTKTextureLoaderOptionSRGB: @NO }
		                                                                         error:&failure];
		if (@available(macOS 26.0, *))
			return run(argv[2], fenced, format);
		fputs("temporal4: needs macOS 26\n", stderr);
		return 1;
	}
}
