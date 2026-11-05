// Upscaling and frame generation together, as for a game whose DLSS goes through MetalFX: the
// game's temporal scaler brings the 3D flight from 960x540 to 1920x1080, and an interpolator
// makes the frame between two of its outputs. Three runs: the scaler alone, the scaler then an
// interpolator on its own (as our library does today), the scaler then an interpolator made with
// MTLFXFrameInterpolatorDescriptor.scaler set to it. Prints the GPU time of each part (median
// over the frames) and the interpolated frames' PSNR against the scene drawn at the half-way
// time at the output size.
// Usage: fxboth <logo.svg>

#import <AppKit/AppKit.h>
#import <MetalFX/MetalFX.h>
#import <MetalKit/MetalKit.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>

#import "scene.h"

enum { inW = 960, inH = 540, outW = 1920, outH = 1080, frames = 70, skip = 10 };
static const double step = 1.0 / 30;

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static Scene3DPipes pipes;
static id<MTLTexture> logo;

static id<MTLTexture> texture(MTLPixelFormat format, NSUInteger w, NSUInteger h, MTLTextureUsage usage, MTLStorageMode mode)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
	d.usage = usage;
	d.storageMode = mode;
	return [device newTextureWithDescriptor:d];
}

// Colour and depth, then motion with a depth of its own, at time t
static void draw(id<MTLCommandBuffer> buffer, double t, id<MTLTexture> color, id<MTLTexture> depth, id<MTLTexture> motion,
                 id<MTLTexture> motionDepth)
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

static double psnr(id<MTLTexture> a, id<MTLTexture> b)
{
	id<MTLTexture> sa = texture(MTLPixelFormatBGRA8Unorm, outW, outH, MTLTextureUsageShaderRead, MTLStorageModeShared);
	id<MTLTexture> sb = texture(MTLPixelFormatBGRA8Unorm, outW, outH, MTLTextureUsageShaderRead, MTLStorageModeShared);
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	[blit copyFromTexture:a toTexture:sa];
	[blit copyFromTexture:b toTexture:sb];
	[blit endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	uint8_t *pa = malloc(outW * outH * 4), *pb = malloc(outW * outH * 4);
	[sa getBytes:pa bytesPerRow:outW * 4 fromRegion:MTLRegionMake2D(0, 0, outW, outH) mipmapLevel:0];
	[sb getBytes:pb bytesPerRow:outW * 4 fromRegion:MTLRegionMake2D(0, 0, outW, outH) mipmapLevel:0];
	double se = 0;
	for (size_t i = 0; i < (size_t)outW * outH * 4; i++)
		if (i % 4 != 3)
			se += (pa[i] - pb[i]) * (pa[i] - pb[i]);
	free(pa);
	free(pb);
	return 10 * log10(255.0 * 255.0 / (se / (outW * outH * 3.0)));
}

static int by_value(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static double median(double *v, int n)
{
	qsort(v, (size_t)n, sizeof(double), by_value);
	return v[n / 2];
}

typedef struct {
	double scaler, interpolator, total, psnr;
	BOOL made;
} Run;

// mode 0: the scaler alone; 1: then an interpolator of its own; 2: then one made with .scaler
API_AVAILABLE(macos(26.0))
static Run run(int mode)
{
	Run r = { 0 };
	MTLFXTemporalScalerDescriptor *sd = [MTLFXTemporalScalerDescriptor new];
	sd.colorTextureFormat = sd.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
	sd.depthTextureFormat = MTLPixelFormatDepth32Float;
	sd.motionTextureFormat = MTLPixelFormatRG16Float;
	sd.inputWidth = inW;
	sd.inputHeight = inH;
	sd.outputWidth = outW;
	sd.outputHeight = outH;
	sd.requiresSynchronousInitialization = YES;
	id<MTLFXTemporalScaler> scaler = [sd newTemporalScalerWithDevice:device];
	if (scaler == nil)
		return r;
	id<MTLFXFrameInterpolator> fx = nil;
	if (mode > 0) {
		MTLFXFrameInterpolatorDescriptor *fd = [MTLFXFrameInterpolatorDescriptor new];
		fd.colorTextureFormat = fd.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
		fd.depthTextureFormat = MTLPixelFormatDepth32Float;
		fd.motionTextureFormat = MTLPixelFormatRG16Float;
		fd.inputWidth = inW;
		fd.inputHeight = inH;
		fd.outputWidth = outW;
		fd.outputHeight = outH;
		if (mode == 2)
			fd.scaler = scaler;
		fx = [fd newFrameInterpolatorWithDevice:device];
		if (fx == nil)
			return r;
	}
	r.made = YES;
	MTLTextureUsage target = MTLTextureUsageRenderTarget;
	id<MTLTexture> color = texture(MTLPixelFormatBGRA8Unorm, inW, inH, scaler.colorTextureUsage | target, MTLStorageModePrivate);
	id<MTLTexture> depth = texture(MTLPixelFormatDepth32Float, inW, inH,
	                               scaler.depthTextureUsage | (fx ? fx.depthTextureUsage : 0) | target, MTLStorageModePrivate);
	id<MTLTexture> motion = texture(MTLPixelFormatRG16Float, inW, inH,
	                                scaler.motionTextureUsage | (fx ? fx.motionTextureUsage : 0) | target, MTLStorageModePrivate);
	id<MTLTexture> motionDepth = texture(MTLPixelFormatDepth32Float, inW, inH, target, MTLStorageModePrivate);
	id<MTLTexture> outputs[2], generated = nil, truth = nil, truthDepth = nil;
	for (int i = 0; i < 2; i++)
		outputs[i] = texture(MTLPixelFormatBGRA8Unorm, outW, outH,
		                     scaler.outputTextureUsage | (fx ? fx.colorTextureUsage : 0) | MTLTextureUsageShaderRead,
		                     MTLStorageModePrivate);
	if (fx != nil) {
		generated = texture(MTLPixelFormatBGRA8Unorm, outW, outH, fx.outputTextureUsage | MTLTextureUsageShaderRead,
		                    MTLStorageModePrivate);
		truth = texture(MTLPixelFormatBGRA8Unorm, outW, outH, target | MTLTextureUsageShaderRead, MTLStorageModePrivate);
		truthDepth = texture(MTLPixelFormatDepth32Float, outW, outH, target, MTLStorageModePrivate);
		fx.depthTexture = depth;
		fx.motionTexture = motion;
		fx.outputTexture = generated;
		fx.nearPlane = 0.1f;
		fx.farPlane = 200;
		fx.fieldOfView = 60;
		fx.aspectRatio = (float)outW / outH;
		fx.depthReversed = NO;
		fx.deltaTime = (float)step;
		fx.motionVectorScaleX = fx.motionVectorScaleY = 1;
		fx.shouldResetHistory = YES;
	}
	scaler.colorTexture = color;
	scaler.depthTexture = depth;
	scaler.motionTexture = motion;
	scaler.inputContentWidth = inW;
	scaler.inputContentHeight = inH;
	scaler.motionVectorScaleX = scaler.motionVectorScaleY = 1;
	double scalerMs[frames], fxMs[frames], totalMs[frames], quality = 0;
	int n = 0, scored = 0;
	for (int f = 0; f < frames; f++) {
		@autoreleasepool {
			double t = 10 + f * step;
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			draw(buffer, t, color, depth, motion, motionDepth);
			[buffer commit];
			id<MTLCommandBuffer> scale = [queue commandBuffer];
			scaler.outputTexture = outputs[f & 1];
			scaler.reset = f == 0;
			[scaler encodeToCommandBuffer:scale];
			[scale commit];
			id<MTLCommandBuffer> interpolate = nil;
			if (fx != nil && f > 0) {
				interpolate = [queue commandBuffer];
				fx.colorTexture = outputs[f & 1];
				fx.prevColorTexture = outputs[(f & 1) ^ 1];
				[fx encodeToCommandBuffer:interpolate];
				fx.shouldResetHistory = NO;
				[interpolate commit];
				[interpolate waitUntilCompleted];
			} else
				[scale waitUntilCompleted];
			if (f < skip)
				continue;
			scalerMs[n] = (scale.GPUEndTime - scale.GPUStartTime) * 1000;
			fxMs[n] = interpolate ? (interpolate.GPUEndTime - interpolate.GPUStartTime) * 1000 : 0;
			totalMs[n] = scalerMs[n] + fxMs[n];
			n++;
			if (fx != nil && f % 10 == 0) {
				buffer = [queue commandBuffer];
				draw(buffer, t - step / 2, truth, truthDepth, nil, nil);
				[buffer commit];
				[buffer waitUntilCompleted];
				quality += psnr(generated, truth);
				scored++;
			}
		}
	}
	r.scaler = median(scalerMs, n);
	r.interpolator = median(fxMs, n);
	r.total = median(totalMs, n);
	r.psnr = scored ? quality / scored : 0;
	return r;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2) {
			fputs("usage: fxboth <logo.svg>\n", stderr);
			return 2;
		}
		if (@available(macOS 26.0, *)) {
		} else {
			fputs("fxboth: needs macOS 26\n", stderr);
			return 1;
		}
		device = MTLCreateSystemDefaultDevice();
		queue = [device newCommandQueue];
		NSError *failure = nil;
		id<MTLLibrary> library = [device newLibraryWithSource:shaders options:nil error:&failure];
		if (library == nil || !scene3d_build(device, library, &pipes, &failure)) {
			fprintf(stderr, "fxboth: %s\n", failure.localizedDescription.UTF8String);
			return 1;
		}
		NSImage *image = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
		NSRect big = NSMakeRect(0, 0, 512, 512);
		CGImageRef cg = [image CGImageForProposedRect:&big context:nil hints:nil];
		if (cg == NULL) {
			fprintf(stderr, "fxboth: cannot read %s\n", argv[1]);
			return 1;
		}
		logo = [[[MTKTextureLoader alloc] initWithDevice:device] newTextureWithCGImage:cg
		                                                                       options:@{ MTKTextureLoaderOptionSRGB: @NO }
		                                                                         error:&failure];
		if (@available(macOS 26.0, *)) {
			const char *names[3] = { "temporal scaler alone", "scaler, then interpolator", "interpolator with .scaler" };
			Run runs[3];
			printf("%dx%d to %dx%d, %d frames, GPU ms (median) and PSNR of the generated frames\n", inW, inH, outW, outH,
			       frames - skip);
			printf("  %-28s %8s %13s %8s %8s\n", "run", "scaler", "interpolator", "total", "PSNR");
			for (int m = 0; m < 3; m++) {
				runs[m] = run(m);
				if (!runs[m].made)
					printf("  %-28s refused\n", names[m]);
				else
					printf("  %-28s %8.2f %13.2f %8.2f %8.2f\n", names[m], runs[m].scaler, runs[m].interpolator, runs[m].total,
					       runs[m].psnr);
			}
			if (runs[1].made && runs[2].made)
				printf("together %.2f ms against %.2f apart: %s\n", runs[2].total, runs[1].total,
				       runs[2].total < runs[1].total ? "cheaper" : "not cheaper");
		}
	}
	return 0;
}
