// Quality and cost of the upscaling chain on the test window's 3D flight. The truth is the
// scene at the output size, supersampled 3x3 and averaged in linear light. Each method brings
// the scene rendered at 1/2 and 2/3 of that size back up; it is scored against the truth by
// PSNR, SSIM (luma, 8x8 windows every 4 pixels) and the share of pixels off by more than 24
// levels, and by PSNR against the plain render at the output size. Two scenes: as drawn, with no
// anti-aliasing at all (textures alias too), and with filtered textures, as a game with mipmaps
// but no anti-aliasing.
// Usage: upbench <logo.svg> [width height]   (UPBENCH_DUMP=<dir> writes the frames as PPM)
// PPM frames against each other: out/framegen/score (framegen/tests/d3d11/score.c)

#import "../fg_upscale.h"
#import "scene.h"

#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>

static NSString *downSource = @
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"static float3 lin(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c < 0.04045); }\n"
	"static float3 gam(float3 c) { c = max(c, 0.0); return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c < 0.0031308); }\n"
	"kernel void down(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],\n"
	"                 constant uint &k [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {\n"
	"  if (any(id >= uint2(dst.get_width(), dst.get_height()))) return;\n"
	"  float3 sum = 0;\n"
	"  for (uint y = 0; y < k; y++) for (uint x = 0; x < k; x++) sum += lin(src.read(id * k + uint2(x, y)).rgb);\n"
	"  dst.write(float4(gam(sum / float(k * k)), 1), id);\n"
	"}\n";

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static Scene3DPipes pipes, scenes[2];
static id<MTLTexture> logo;
static id<MTLComputePipelineState> downPipe;

static id<MTLTexture> texture(MTLPixelFormat format, NSUInteger w, NSUInteger h, MTLTextureUsage usage, MTLStorageMode mode)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
	d.usage = usage;
	d.storageMode = mode;
	return [device newTextureWithDescriptor:d];
}

// The flight at frame f (60 per second), into a w x h texture; the HUD sits where it does at the
// output size, whatever the render size
static id<MTLTexture> render(double f, NSUInteger w, NSUInteger h, NSUInteger outW, NSUInteger outH)
{
	id<MTLTexture> color = texture(MTLPixelFormatBGRA8Unorm, w, h,
	                               MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
	                               MTLStorageModePrivate);
	id<MTLTexture> depth = texture(MTLPixelFormatDepth32Float, w, h, MTLTextureUsageRenderTarget, MTLStorageModePrivate);
	double t = 10 + f / 60;
	Scene3D s = { (float)t, (float)(960 * t / 60), (float)outW / outH, (float)t, (float)(960 * t / 60) };
	Uniforms u = { { (float)outW, (float)outH }, 0, outH * 0.22f, 1 };
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = color;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0.11, 0.115, 0.14, 1);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.depthAttachment.texture = depth;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = 1;
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	scene3d_draw(encoder, &pipes, s, u, logo);
	[encoder endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	return color;
}

static void read_back(id<MTLTexture> t, uint8_t *pixels)
{
	id<MTLTexture> shared = texture(t.pixelFormat, t.width, t.height, MTLTextureUsageShaderRead, MTLStorageModeShared);
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	[blit copyFromTexture:t toTexture:shared];
	[blit endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	[shared getBytes:pixels bytesPerRow:t.width * 4 fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0];
}

static void dump(const uint8_t *bgra, NSUInteger w, NSUInteger h, NSString *name)
{
	const char *dir = getenv("UPBENCH_DUMP");
	if (dir == NULL)
		return;
	FILE *file = fopen([NSString stringWithFormat:@"%s/%@.ppm", dir, name].UTF8String, "wb");
	if (file == NULL)
		return;
	fprintf(file, "P6\n%lu %lu\n255\n", (unsigned long)w, (unsigned long)h);
	for (NSUInteger i = 0; i < w * h; i++) {
		uint8_t rgb[3] = { bgra[i * 4 + 2], bgra[i * 4 + 1], bgra[i * 4] };
		fwrite(rgb, 1, 3, file);
	}
	fclose(file);
}

typedef struct {
	double psnr, ssim, off, native;
} Score;

static Score score(const uint8_t *a, const uint8_t *b, NSUInteger w, NSUInteger h)
{
	double se = 0;
	long off = 0;
	size_t n = w * h;
	float *la = malloc(n * sizeof(float)), *lb = malloc(n * sizeof(float));
	for (size_t i = 0; i < n; i++) {
		int e = 0;
		for (int c = 0; c < 3; c++) {
			int d = a[i * 4 + c] - b[i * 4 + c];
			se += d * d;
			e = MAX(e, abs(d));
		}
		off += e > 24;
		la[i] = 0.114f * a[i * 4] + 0.587f * a[i * 4 + 1] + 0.299f * a[i * 4 + 2];
		lb[i] = 0.114f * b[i * 4] + 0.587f * b[i * 4 + 1] + 0.299f * b[i * 4 + 2];
	}
	double mse = se / (n * 3.0);
	const double c1 = pow(0.01 * 255, 2), c2 = pow(0.03 * 255, 2);
	double ssim = 0;
	long windows = 0;
	for (NSUInteger y = 0; y + 8 <= h; y += 4)
		for (NSUInteger x = 0; x + 8 <= w; x += 4) {
			double ma = 0, mb = 0, va = 0, vb = 0, cv = 0;
			for (int j = 0; j < 8; j++)
				for (int i = 0; i < 8; i++) {
					size_t at = (y + j) * w + x + i;
					ma += la[at];
					mb += lb[at];
				}
			ma /= 64;
			mb /= 64;
			for (int j = 0; j < 8; j++)
				for (int i = 0; i < 8; i++) {
					size_t at = (y + j) * w + x + i;
					va += (la[at] - ma) * (la[at] - ma);
					vb += (lb[at] - mb) * (lb[at] - mb);
					cv += (la[at] - ma) * (lb[at] - mb);
				}
			va /= 63;
			vb /= 63;
			cv /= 63;
			ssim += ((2 * ma * mb + c1) * (2 * cv + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2));
			windows++;
		}
	free(la);
	free(lb);
	return (Score){ mse > 0 ? 10 * log10(255.0 * 255.0 / mse) : 99, ssim / windows, 100.0 * off / n, 0 };
}

typedef struct {
	const char *name;
	const char *spec; // NULL: no upscaling, the native render itself
} Method;

static const Method methods[] = {
	{ "native, no AA", NULL },
	{ "bilinear", "bilinear" },
	{ "bilinear+rcas", "bilinear+rcas=0.5" },
	{ "metalfx", "metalfx" },
	{ "metalfx+rcas", "metalfx+rcas=0.5" },
	{ "cmaa2+bilinear", "cmaa2+bilinear" },
	{ "cmaa2+metalfx", "cmaa2+metalfx" },
	{ "chain rcas=0", "cmaa2+metalfx+rcas=0" },
	{ "chain rcas=0.5", "cmaa2+metalfx+rcas=0.5" },
	{ "chain rcas=1", "cmaa2+metalfx+rcas=1" },
	{ "chain rcas=2", "cmaa2+metalfx+rcas=2" },
};
enum { method_count = sizeof(methods) / sizeof(*methods) };

static FGUpscaler *upscaler_for(const char *spec, NSUInteger w, NSUInteger h, NSUInteger outW, NSUInteger outH)
{
	FGUpscaleSettings settings;
	NSString *error = nil;
	FGUpscaler *up = FGUpscaleParse(spec, &settings) ? [[FGUpscaler alloc] initWithDevice:device settings:settings error:&error] : nil;
	if (up == nil || ![up prepareInputWidth:w height:h format:MTLPixelFormatBGRA8Unorm outputWidth:outW height:outH
	                                 format:MTLPixelFormatBGRA8Unorm error:&error]) {
		fprintf(stderr, "upbench: %s: %s\n", spec, error.UTF8String ?: "unknown method");
		exit(1);
	}
	return up;
}

static id<MTLTexture> upscale(FGUpscaler *up, id<MTLTexture> low, NSUInteger outW, NSUInteger outH, double *ms)
{
	id<MTLTexture> out = texture(MTLPixelFormatBGRA8Unorm, outW, outH, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead,
	                             MTLStorageModePrivate);
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	[up encode:low to:out commandBuffer:buffer];
	[buffer commit];
	[buffer waitUntilCompleted];
	if (ms)
		*ms = (buffer.GPUEndTime - buffer.GPUStartTime) * 1000;
	return out;
}

static int by_value(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2) {
			fputs("usage: upbench <logo.svg> [width height]\n", stderr);
			return 2;
		}
		NSUInteger W = argc > 3 ? (NSUInteger)atol(argv[2]) : 1920, H = argc > 3 ? (NSUInteger)atol(argv[3]) : 1080;
		device = MTLCreateSystemDefaultDevice();
		queue = [device newCommandQueue];
		NSError *failure = nil;
		// The filtered scene: the checker box-filtered over the pixel's footprint, by its parity per axis
		NSString *raw = @"  float check = fmod(abs(q.x + q.y + q.z), 2.0) < 0.5 ? 1.0 : 0.55;\n";
		NSString *filtered = @"  float3 p = in.local * 2.0, w = fwidth(p);\n"
			"  float3 soft = 2.0 * (abs(fract((p - 0.5 * w) * 0.5) - 0.5) - abs(fract((p + 0.5 * w) * 0.5) - 0.5)) / max(w, 1e-6);\n"
			"  float3 hard = 1.0 - 2.0 * fmod(abs(q), 2.0);\n"
			"  float3 i = select(soft, hard, w < 1e-4);\n"
			"  float check = mix(0.55, 1.0, 0.5 + 0.5 * i.x * i.y * i.z);\n";
		if (![shaders containsString:raw]) {
			fputs("upbench: the scene's checker changed, update the filtered one\n", stderr);
			return 1;
		}
		NSMutableArray *keep = [NSMutableArray new];
		for (int v = 0; v < 2; v++) {
			NSString *source = v == 0 ? shaders : [shaders stringByReplacingOccurrencesOfString:raw withString:filtered];
			id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&failure];
			if (library == nil || !scene3d_build(device, library, &scenes[v], &failure)) {
				fprintf(stderr, "upbench: %s\n", failure.localizedDescription.UTF8String);
				return 1;
			}
			[keep addObjectsFromArray:scene3d_keep];
		}
		pipes = scenes[0];
		id<MTLLibrary> downLibrary = [device newLibraryWithSource:downSource options:nil error:&failure];
		if (downLibrary == nil) {
			fprintf(stderr, "upbench: %s\n", failure.localizedDescription.UTF8String);
			return 1;
		}
		downPipe = [device newComputePipelineStateWithFunction:[downLibrary newFunctionWithName:@"down"] error:&failure];
		NSImage *image = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
		NSRect big = NSMakeRect(0, 0, 512, 512);
		CGImageRef cg = [image CGImageForProposedRect:&big context:nil hints:nil];
		if (cg == NULL) {
			fprintf(stderr, "upbench: cannot read %s\n", argv[1]);
			return 1;
		}
		logo = [[[MTKTextureLoader alloc] initWithDevice:device] newTextureWithCGImage:cg
		                                                                       options:@{ MTKTextureLoaderOptionSRGB: @NO }
		                                                                         error:&failure];

		const double frames[] = { 0, 37, 83, 131, 177, 229 };
		const int frameCount = sizeof(frames) / sizeof(*frames);
		const double factors[] = { 2.0, 1.5 };
		uint8_t *truth = malloc(W * H * 4), *out = malloc(W * H * 4), *plain = malloc(W * H * 4);
		Score sums[2][2][method_count] = { 0 };
		FGUpscaler *ups[2][method_count] = { { nil } };
		for (int k2 = 0; k2 < 2; k2++)
			for (int m = 0; m < method_count; m++)
				if (methods[m].spec != NULL)
					ups[k2][m] = upscaler_for(methods[m].spec, (NSUInteger)lround(W / factors[k2]), (NSUInteger)lround(H / factors[k2]), W, H);
		for (int v = 0; v < 2; v++)
		for (int f = 0; f < frameCount; f++) {
			@autoreleasepool {
				pipes = scenes[v];
				read_back(render(frames[f], W, H, W, H), plain);
				id<MTLTexture> big3 = render(frames[f], W * 3, H * 3, W, H);
				id<MTLTexture> reference = texture(MTLPixelFormatBGRA8Unorm, W, H, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead,
				                                   MTLStorageModePrivate);
				id<MTLCommandBuffer> buffer = [queue commandBuffer];
				id<MTLComputeCommandEncoder> c = [buffer computeCommandEncoder];
				uint32_t k = 3;
				[c setComputePipelineState:downPipe];
				[c setTexture:big3 atIndex:0];
				[c setTexture:reference atIndex:1];
				[c setBytes:&k length:sizeof(k) atIndex:0];
				[c dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
				[c endEncoding];
				[buffer commit];
				[buffer waitUntilCompleted];
				read_back(reference, truth);
				if (f == 0)
					dump(truth, W, H, [NSString stringWithFormat:@"%d truth", v]);
				for (int k2 = 0; k2 < 2; k2++) {
					NSUInteger w = (NSUInteger)lround(W / factors[k2]), h = (NSUInteger)lround(H / factors[k2]);
					id<MTLTexture> low = render(frames[f], w, h, W, H);
					for (int m = 0; m < method_count; m++) {
						id<MTLTexture> result = methods[m].spec == NULL
							? render(frames[f], W, H, W, H)
							: upscale(ups[k2][m], low, W, H, NULL);
						read_back(result, out);
						if (f == 0 && k2 == 0)
							dump(out, W, H, [NSString stringWithFormat:@"%d %s", v, methods[m].name]);
						Score s = score(out, truth, W, H);
						sums[v][k2][m].psnr += s.psnr / frameCount;
						sums[v][k2][m].ssim += s.ssim / frameCount;
						sums[v][k2][m].off += s.off / frameCount;
						sums[v][k2][m].native += score(out, plain, W, H).psnr / frameCount;
					}
				}
			}
		}
		printf("3D flight, %d frames, truth %lux%lu supersampled 3x3\n", frameCount, (unsigned long)W, (unsigned long)H);
		for (int v = 0; v < 2; v++)
			for (int k2 = 0; k2 < 2; k2++) {
				printf("\n%s, from %lux%lu (1/%.1f):\n  %-16s %7s %7s %8s %12s\n", v ? "filtered textures" : "no filtering at all",
				       lround(W / factors[k2]), lround(H / factors[k2]), factors[k2], "method", "PSNR", "SSIM", ">24 %",
				       "PSNR native");
				for (int m = 0; m < method_count; m++)
					printf("  %-16s %7.2f %7.4f %8.2f %12.2f\n", methods[m].name, sums[v][k2][m].psnr, sums[v][k2][m].ssim,
					       sums[v][k2][m].off, sums[v][k2][m].native);
			}
		pipes = scenes[0];
		// Cost: the median of 40 runs, the first 5 left out, from 1/2 of 2560x1440 (a 1280x720
		// game in Retina points) and of W x H
		const NSUInteger sizes[2][2] = { { 2560, 1440 }, { W, H } };
		printf("\nGPU ms, median of 40:\n  %-16s %12s %12s\n", "method", "1280x720>2x", [NSString stringWithFormat:@"%lux%lu>2x", W / 2, H / 2].UTF8String);
		for (int m = 1; m < method_count; m++) {
			double medians[2];
			for (int z = 0; z < 2; z++) {
				@autoreleasepool {
					NSUInteger ow = sizes[z][0], oh = sizes[z][1];
					id<MTLTexture> low = render(100, ow / 2, oh / 2, ow, oh);
					FGUpscaler *up = upscaler_for(methods[m].spec, ow / 2, oh / 2, ow, oh);
					double times[45];
					for (int i = 0; i < 45; i++)
						upscale(up, low, ow, oh, &times[i]);
					qsort(times + 5, 40, sizeof(double), by_value);
					medians[z] = times[5 + 20];
				}
			}
			printf("  %-16s %12.2f %12.2f\n", methods[m].name, medians[0], medians[1]);
		}
		free(truth);
		free(out);
		free(plain);
	}
	return 0;
}
