// MetalFX's frame interpolator alone, on a flat square crossing a still noisy background by a
// known distance per frame, with exact motion vectors. Measures where the generated frame puts
// the square (0 previous frame, 1 current one), how scaled vectors move it, and what the
// descriptor options accept and cost. Usage: mfx [distance px ...]

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <sys/param.h>

static const int width = 1280, height = 720, side = 160, top = 280;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLComputePipelineState> paintPipe, motionPipe;

static NSString *source = @
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"static float hash(float2 p) { return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }\n"
	"static bool inside(float2 p, float4 sq) { return p.x >= sq.x && p.x < sq.x + sq.z && p.y >= sq.y && p.y < sq.y + sq.z; }\n"
	"kernel void paint(texture2d<float, access::write> out [[texture(0)]], constant float4 &sq [[buffer(0)]],\n"
	"                  uint2 g [[thread_position_in_grid]]) {\n"
	"  if (g.x >= out.get_width() || g.y >= out.get_height()) return;\n"
	"  float2 p = float2(g) + 0.5;\n"
	"  float3 c = inside(p, sq) ? float3(0.95, 0.55, 0.1) : float3(0.2, 0.22, 0.26) + 0.15 * hash(floor(p / 6));\n"
	"  out.write(float4(c, 1), g);\n"
	"}\n"
	"kernel void motion(texture2d<float, access::write> out [[texture(0)]], constant float4 &sq [[buffer(0)]],\n"
	"                   constant float2 &v [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
	"  if (g.x >= out.get_width() || g.y >= out.get_height()) return;\n"
	"  out.write(float4(inside(float2(g) + 0.5, sq) ? v : float2(0), 0, 0), g);\n"
	"}\n";

static id<MTLTexture> texture(MTLPixelFormat format, int w, int h, MTLTextureUsage usage, MTLStorageMode storage)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
	d.usage = usage;
	d.storageMode = storage;
	return [device newTextureWithDescriptor:d];
}

static void dispatch(id<MTLCommandBuffer> buffer, id<MTLComputePipelineState> pipe, id<MTLTexture> out, const void *a,
                     size_t alen, const void *b, size_t blen)
{
	id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
	[compute setComputePipelineState:pipe];
	[compute setTexture:out atIndex:0];
	[compute setBytes:a length:alen atIndex:0];
	if (b != NULL)
		[compute setBytes:b length:blen atIndex:1];
	[compute dispatchThreads:MTLSizeMake(out.width, out.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[compute endEncoding];
}

typedef struct {
	BOOL nilScaler, noPrev, vectorsScaled, profile;
	float scale, deltaTime;
	int w, h, frames;
	// UI box: 1 the box alone, told composited (phase 0's black frame); 2 the box alone, not
	// composited; 3 composited as the header says: the colour without UI, the UI texture the colour
	// with the box on top
	int ui;
} Setup;

API_AVAILABLE(macos(26.0))
static id<MTLFXFrameInterpolator> make(Setup s)
{
	MTLFXFrameInterpolatorDescriptor *d = [MTLFXFrameInterpolatorDescriptor new];
	d.colorTextureFormat = d.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
	d.depthTextureFormat = MTLPixelFormatDepth32Float;
	d.motionTextureFormat = MTLPixelFormatRG16Float;
	d.inputWidth = d.outputWidth = (NSUInteger)s.w;
	d.inputHeight = d.outputHeight = (NSUInteger)s.h;
	if (s.ui)
		d.uiTextureFormat = MTLPixelFormatBGRA8Unorm;
	if (s.nilScaler)
		d.scaler = nil;
	if (s.noPrev) {
		if (@available(macOS 27.0, *))
			d.requiresPrevColorTexture = NO;
		else
			return nil;
	}
	return [d newFrameInterpolatorWithDevice:device];
}

static int compare(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

typedef struct {
	double t, mass, inside, gpu, ui;
	int frames;
	BOOL made, boxed;
} Where;

// The square's centroid in the generated frame, as a share of the way from the previous frame's
// square to the current one; mass is how much square there is (1: one square), inside the share
// of it within one square's width around the centroid (1: sharp, about 1 - d/side: a blend)
API_AVAILABLE(macos(26.0))
static Where run(Setup s, int distance)
{
	Where r = { 0 };
	id<MTLFXFrameInterpolator> fx = make(s);
	if (fx == nil)
		return r;
	r.made = YES;
	r.boxed = s.ui != 0;
	int w = s.w, h = s.h;
	id<MTLTexture> frames[2] = {
		texture(MTLPixelFormatBGRA8Unorm, w, h, fx.colorTextureUsage | MTLTextureUsageShaderWrite, MTLStorageModePrivate),
		texture(MTLPixelFormatBGRA8Unorm, w, h, fx.colorTextureUsage | MTLTextureUsageShaderWrite, MTLStorageModePrivate) };
	id<MTLTexture> background = texture(MTLPixelFormatBGRA8Unorm, w, h, MTLTextureUsageShaderWrite, MTLStorageModeShared);
	id<MTLTexture> motion = texture(MTLPixelFormatRG16Float, w, h, fx.motionTextureUsage | MTLTextureUsageShaderWrite,
	                                MTLStorageModePrivate);
	id<MTLTexture> depth = texture(MTLPixelFormatDepth32Float, w, h, fx.depthTextureUsage | MTLTextureUsageRenderTarget,
	                               MTLStorageModePrivate);
	id<MTLTexture> output = texture(MTLPixelFormatBGRA8Unorm, w, h, fx.outputTextureUsage, MTLStorageModePrivate);
	id<MTLTexture> copy = texture(MTLPixelFormatBGRA8Unorm, w, h, MTLTextureUsageShaderRead, MTLStorageModeShared);

	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	float none[4] = { -1e6f, -1e6f, 0, 0 };
	dispatch(buffer, paintPipe, background, none, sizeof(none), NULL, 0);
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.depthAttachment.texture = depth;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = 0.5;
	pass.depthAttachment.storeAction = MTLStoreActionStore;
	[[buffer renderCommandEncoderWithDescriptor:pass] endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	uint8_t *bg = malloc((size_t)w * h * 4), *out = malloc((size_t)w * h * 4);
	[background getBytes:bg bytesPerRow:(NSUInteger)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];

	fx.depthTexture = depth;
	fx.motionTexture = motion;
	fx.outputTexture = output;
	fx.nearPlane = 0.1f;
	fx.farPlane = 1000;
	fx.fieldOfView = 60;
	fx.aspectRatio = (float)w / h;
	fx.depthReversed = NO;
	fx.deltaTime = s.deltaTime;
	fx.motionVectorScaleX = fx.motionVectorScaleY = s.vectorsScaled ? 1 : s.scale;
	fx.shouldResetHistory = YES;
	id<MTLTexture> ui = nil, final = nil;
	if (s.ui) {
		// A clear frame with a grey box in the top left corner, away from the square
		ui = texture(MTLPixelFormatBGRA8Unorm, w, h, fx.uiTextureUsage | MTLTextureUsageRenderTarget, MTLStorageModePrivate);
		final = s.ui == 3 ? texture(MTLPixelFormatBGRA8Unorm, w, h, fx.uiTextureUsage, MTLStorageModePrivate) : ui;
		buffer = [queue commandBuffer];
		MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
		clear.colorAttachments[0].texture = ui;
		clear.colorAttachments[0].loadAction = MTLLoadActionClear;
		clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
		clear.colorAttachments[0].storeAction = MTLStoreActionStore;
		[[buffer renderCommandEncoderWithDescriptor:clear] endEncoding];
		id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
		[blit copyFromTexture:background sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
		           sourceSize:MTLSizeMake(100, 40, 1) toTexture:ui destinationSlice:0 destinationLevel:0
		    destinationOrigin:MTLOriginMake(10, 10, 0)];
		[blit endEncoding];
		[buffer commit];
		fx.uiTexture = final;
		fx.uiTextureComposited = s.ui != 2;
	}
	const int x0 = 40, y0 = top * h / 720, count = MIN(s.frames, (w - side - x0) / distance + 1);
	double *times = calloc((size_t)count, sizeof(double));
	const float q[3] = { 0.95f, 0.55f, 0.1f };
	double *col = calloc((size_t)w, sizeof(double));
	for (int f = 0; f < count; f++) {
		int cur = f & 1;
		float sq[4] = { (float)(x0 + distance * f), (float)y0, (float)side, 0 };
		float v[2] = { -(float)distance * (s.vectorsScaled ? s.scale : 1), 0 };
		buffer = [queue commandBuffer];
		dispatch(buffer, paintPipe, frames[cur], sq, sizeof(sq), NULL, 0);
		dispatch(buffer, motionPipe, motion, sq, sizeof(sq), v, sizeof(v));
		[buffer commit];
		if (f == 0)
			continue;
		buffer = [queue commandBuffer];
		if (s.ui == 3) {
			id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
			[blit copyFromTexture:frames[cur] toTexture:final];
			[blit copyFromTexture:ui sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(10, 10, 0)
			           sourceSize:MTLSizeMake(100, 40, 1) toTexture:final destinationSlice:0 destinationLevel:0
			    destinationOrigin:MTLOriginMake(10, 10, 0)];
			[blit endEncoding];
		}
		fx.colorTexture = frames[cur];
		fx.prevColorTexture = s.noPrev ? nil : frames[cur ^ 1];
		[fx encodeToCommandBuffer:buffer];
		fx.shouldResetHistory = NO;
		id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
		[blit copyFromTexture:output toTexture:copy];
		[blit endEncoding];
		[buffer commit];
		[buffer waitUntilCompleted];
		if (f < 6)
			continue;
		times[r.frames] = (buffer.GPUEndTime - buffer.GPUStartTime) * 1000;
		[copy getBytes:out bytesPerRow:(NSUInteger)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
		double sum = 0, moment = 0;
		for (int i = 0; i < w; i++)
			col[i] = 0;
		for (int y = y0; y < y0 + side; y++)
			for (int i = 0; i < w; i++) {
				const uint8_t *o = out + ((size_t)y * w + i) * 4, *b = bg + ((size_t)y * w + i) * 4;
				// BGRA bytes against the square's RGB
				double dot = 0, norm = 0;
				for (int c = 0; c < 3; c++) {
					double qb = q[2 - c] - b[c] / 255.0;
					dot += (o[c] / 255.0 - b[c] / 255.0) * qb;
					norm += qb * qb;
				}
				col[i] += fmax(0, fmin(1, dot / norm));
			}
		for (int i = 0; i < w; i++) {
			sum += col[i];
			moment += col[i] * (i + 0.5);
		}
		double cx = sum > 0 ? moment / sum : 0, inside = 0;
		for (int i = 0; i < w; i++)
			if (fabs(i + 0.5 - cx) <= side / 2.0)
				inside += col[i];
		double previous = x0 + distance * (f - 1) + side / 2.0;
		r.t += (cx - previous) / distance;
		// One frame's columns from the previous square to past the current one, tenths of a full column
		if (s.profile && f == count - 1) {
			printf("    ");
			for (int i = (int)previous - side / 2 - 8; i < (int)previous + side / 2 + distance + 8 && i < w; i += 4)
				putchar('0' + (int)fmin(9, round(col[i] / side * 9)));
			printf("\n");
		}
		// The box's pixels within 2 levels of the background patch it was copied from
		long boxGood = 0;
		for (int y = 0; s.ui && y < 40; y++)
			for (int i = 0; i < 100; i++) {
				const uint8_t *o = out + ((size_t)(y + 10) * w + i + 10) * 4, *b = bg + ((size_t)y * w + i) * 4;
				boxGood += MAX(MAX(abs(o[0] - b[0]), abs(o[1] - b[1])), abs(o[2] - b[2])) <= 2;
			}
		r.ui += boxGood / 4000.0;
		r.mass += sum / ((double)side * side);
		r.inside += sum > 0 ? inside / sum : 0;
		r.frames++;
	}
	if (r.frames > 0) {
		r.t /= r.frames;
		r.mass /= r.frames;
		r.inside /= r.frames;
		r.ui /= r.frames;
		qsort(times, (size_t)r.frames, sizeof(double), compare);
		r.gpu = times[r.frames / 2];
	}
	free(times);
	free(col);
	free(bg);
	free(out);
	return r;
}

static void row(const char *name, Where r)
{
	if (!r.made)
		printf("%-46s  refused\n", name);
	else
		printf("%-46s  t %6.3f  mass %5.2f  inside %5.1f%%  gpu p50 %5.2f ms%s", name, r.t, r.mass, r.inside * 100, r.gpu,
		       r.boxed ? "" : "\n");
	if (r.made && r.boxed)
		printf("  box %5.1f%%\n", r.ui * 100);
	fflush(stdout);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (@available(macOS 26.0, *)) {
			device = MTLCreateSystemDefaultDevice();
			if (![MTLFXFrameInterpolatorDescriptor supportsDevice:device]) {
				puts("mfx: no frame interpolation on this device");
				return 77;
			}
			queue = [device newCommandQueue];
			NSError *error = nil;
			id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
			paintPipe = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"paint"] error:&error];
			motionPipe = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"motion"] error:&error];
			if (paintPipe == nil || motionPipe == nil) {
				fprintf(stderr, "mfx: %s\n", error.localizedDescription.UTF8String);
				return 1;
			}
			int distances[8] = { 48 }, n = 1;
			if (argc > 1)
				for (n = 0; n + 1 < argc && n < 8; n++)
					distances[n] = atoi(argv[n + 1]);
			Setup base = { .scale = 1, .deltaTime = 1.0f / 60, .w = width, .h = height, .frames = 16,
			               .profile = getenv("MFX_PROFILE") != NULL };
			char name[96];

			puts("== implicit instant: exact vectors ==");
			for (int k = 0; k < n; k++) {
				snprintf(name, sizeof(name), "%d px per frame", distances[k]);
				row(name, run(base, distances[k]));
			}
			const float deltas[] = { 1.0f / 240, 1.0f / 30, 0 };
			for (int k = 0; k < 3; k++) {
				Setup s = base;
				s.deltaTime = deltas[k];
				snprintf(name, sizeof(name), "deltaTime %.4f s", deltas[k]);
				row(name, run(s, distances[0]));
			}

			puts("== scaled vectors: motionVectorScale k ==");
			const float scales[] = { 0, 0.25f, 0.5f, 0.75f, 1, 1.25f, 1.5f, 1.75f, 2, 3 };
			for (int k = 0; k < 10; k++) {
				Setup s = base;
				s.scale = scales[k];
				snprintf(name, sizeof(name), "k %.2f", scales[k]);
				row(name, run(s, distances[0]));
			}
			puts("== scaled vectors: values times k in the texture ==");
			for (int k = 0; k < 10; k++) {
				Setup s = base;
				s.scale = scales[k];
				s.vectorsScaled = YES;
				snprintf(name, sizeof(name), "k %.2f", scales[k]);
				row(name, run(s, distances[0]));
			}

			puts("== descriptor options ==");
			Setup nilScaler = base;
			nilScaler.nilScaler = YES;
			row("scaler = nil", run(nilScaler, distances[0]));
			Setup noPrev = base;
			noPrev.noPrev = YES;
			row("requiresPrevColorTexture = NO", run(noPrev, distances[0]));
			Setup ui = base;
			ui.ui = 1;
			row("uiTexture = UI alone, composited = YES", run(ui, distances[0]));
			ui.ui = 2;
			row("uiTexture, uiTextureComposited = NO", run(ui, distances[0]));
			ui.ui = 3;
			row("uiTexture = colour + UI, composited = YES", run(ui, distances[0]));

			puts("== interpolator cost alone: 8 px per frame, 64 frames, three rounds ==");
			const int sizes[][2] = { { 1920, 1080 }, { 960, 540 } };
			for (int round = 0; round < 3; round++)
				for (int k = 0; k < 2; k++)
					for (int p = 0; p < 2; p++) {
						Setup s = base;
						s.w = sizes[k][0];
						s.h = sizes[k][1];
						s.noPrev = p;
						s.frames = 64;
						s.profile = NO;
						snprintf(name, sizeof(name), "%dx%d%s", s.w, s.h, p ? ", requiresPrevColorTexture = NO" : "");
						row(name, run(s, 8));
					}
		} else {
			puts("mfx: macOS 26 or later needed");
			return 77;
		}
	}
	return 0;
}
