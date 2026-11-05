// The cost of our chain around a temporal scaler made as DXMT makes one for the D3D11 scene's
// DLSS (853x480 to 1280x720): the scaler alone against the scaler through fg_temporal, frames
// interleaved, each in its own command buffer. Prints the median GPU time of each and the gap.
// Usage: temporal [frames] [CARTOUCHE_FRAMEGEN_TEMPORAL settings for ours]
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>

#import "../fg_temporal.h"

// fg_pipeline.m's, which this test does without
_Atomic int FGCreatingInterpolator;

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

static id<MTLTexture> make(id<MTLDevice> device, MTLPixelFormat format, NSUInteger w, NSUInteger h, MTLTextureUsage usage)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
	d.usage = usage | MTLTextureUsageShaderRead;
	d.storageMode = MTLStorageModePrivate;
	return [device newTextureWithDescriptor:d];
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		int frames = argc > 1 ? atoi(argv[1]) : 300;
		if (argc > 2)
			setenv("CARTOUCHE_FRAMEGEN_TEMPORAL", argv[2], 1);
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		id<MTLCommandQueue> queue = [device newCommandQueue];
		const NSUInteger w = 853, h = 480, ow = 1280, oh = 720;
		id<MTLFXTemporalScaler> scalers[2];
		IMP encodes[2];
		for (int i = 0; i < 2; i++) {
			MTLFXTemporalScalerDescriptor *d = [MTLFXTemporalScalerDescriptor new];
			d.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
			d.depthTextureFormat = MTLPixelFormatR32Float;
			d.motionTextureFormat = MTLPixelFormatRG16Float;
			d.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
			d.inputWidth = w;
			d.inputHeight = h;
			d.outputWidth = ow;
			d.outputHeight = oh;
			d.requiresSynchronousInitialization = YES;
			if (i == 1) {
				FGTemporalStart(say);
				FGTemporalTune(d);
			}
			scalers[i] = [d newTemporalScalerWithDevice:device];
			if (scalers[i] == nil) {
				fputs("temporal: no MetalFX temporal scaler\n", stderr);
				return 1;
			}
			if (i == 1)
				FGTemporalAdopt(scalers[i], device);
			encodes[i] = [(id)scalers[i] methodForSelector:@selector(encodeToCommandBuffer:)];
			id<MTLFXTemporalScaler> s = scalers[i];
			s.colorTexture = make(device, d.colorTextureFormat, w, h, s.colorTextureUsage | MTLTextureUsageRenderTarget);
			s.depthTexture = make(device, d.depthTextureFormat, w, h, s.depthTextureUsage);
			s.motionTexture = make(device, d.motionTextureFormat, w, h, s.motionTextureUsage);
			s.outputTexture = make(device, d.outputTextureFormat, ow, oh, s.outputTextureUsage | MTLTextureUsageShaderWrite);
			s.inputContentWidth = w;
			s.inputContentHeight = h;
			s.motionVectorScaleX = 1;
			s.motionVectorScaleY = 1;
		}
		double *ms[2] = { calloc((size_t)frames, sizeof(double)), calloc((size_t)frames, sizeof(double)) };
		for (int f = 0; f < frames; f++)
			for (int i = 0; i < 2; i++) {
				id<MTLCommandBuffer> buffer = [queue commandBuffer];
				scalers[i].jitterOffsetX = (float)(f % 4) / 4 - 0.375f;
				scalers[i].jitterOffsetY = (float)(f % 3) / 3 - 0.333f;
				scalers[i].reset = f == 0;
				if (i == 0)
					((void (*)(id, SEL, id))encodes[0])(scalers[0], @selector(encodeToCommandBuffer:), buffer);
				else
					FGTemporalEncode(scalers[1], @selector(encodeToCommandBuffer:), buffer, encodes[1]);
				[buffer commit];
				[buffer waitUntilCompleted];
				ms[i][f] = (buffer.GPUEndTime - buffer.GPUStartTime) * 1000;
			}
		// The first frames compile and warm up
		int skip = frames / 5;
		double median[2];
		for (int i = 0; i < 2; i++) {
			qsort(ms[i] + skip, (size_t)(frames - skip), sizeof(double), ascending);
			median[i] = ms[i][skip + (frames - skip) / 2];
		}
		printf("temporal dxmt_ms=%.3f ours_ms=%.3f added_ms=%.3f\n", median[0], median[1], median[1] - median[0]);
	}
	return 0;
}
