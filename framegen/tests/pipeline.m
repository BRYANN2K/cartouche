// The frame generation GPU path on synthetic frames: a pattern moved by a known shift must
// give that shift back in the block vectors, and the generated frame must sit half way.
// Prints "ok"/"FAIL" lines and the GPU time per stage. Usage: pipeline [width height]

#import "../fg_pipeline.h"

#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static int fails;

static void check(const char *what, int good, const char *detail)
{
	printf("  %s  %s%s%s\n", good ? "ok   " : "FAIL ", what, detail[0] ? ": " : "", detail);
	fails += !good;
}

static float half_to_float(uint16_t h)
{
	uint32_t sign = (uint32_t)(h & 0x8000) << 16, exponent = (h >> 10) & 0x1f, mantissa = h & 0x3ff;
	uint32_t bits;
	if (exponent == 0)
		bits = sign; // zero and subnormals, too small to matter here
	else if (exponent == 31)
		bits = sign | 0x7f800000 | (mantissa << 13);
	else
		bits = sign | ((exponent + 112) << 23) | (mantissa << 13);
	float f;
	memcpy(&f, &bits, sizeof(f));
	return f;
}

// 8x8 squares of random grey, moved by (dx, dy) pixels
static uint8_t pattern(int x, int y, int dx, int dy)
{
	uint32_t cx = (uint32_t)((x - dx) >> 3) & 0xffff, cy = (uint32_t)((y - dy) >> 3) & 0xffff;
	uint32_t h = (cx * 73856093u) ^ (cy * 19349663u);
	h ^= h >> 13;
	h *= 0x5bd1e995u;
	return (uint8_t)(h >> 24);
}

static id<MTLTexture> frame_lit(id<MTLDevice> device, int width, int height, int dx, int dy, int light);

static id<MTLTexture> frame(id<MTLDevice> device, int width, int height, int dx, int dy)
{
	return frame_lit(device, width, height, dx, dy, 1);
}

// light 4: the same pattern four times darker, another scene as far as the histogram goes
static id<MTLTexture> frame_lit(id<MTLDevice> device, int width, int height, int dx, int dy, int light)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                             width:width height:height mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> texture = [device newTextureWithDescriptor:d];
	uint8_t *pixels = malloc((size_t)width * height * 4);
	for (int y = 0; y < height; y++)
		for (int x = 0; x < width; x++) {
			uint8_t v = pattern(x, y, dx, dy) / light;
			uint8_t *p = pixels + ((size_t)y * width + x) * 4;
			p[0] = p[1] = p[2] = v;
			p[3] = 255;
		}
	[texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];
	free(pixels);
	return texture;
}

// The pattern in an HDR or EDR format: half floats up to four times white, or 10 bits a channel
static id<MTLTexture> frame_wide(id<MTLDevice> device, MTLPixelFormat format, int width, int height, int dx, int dy)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height
	                                                                         mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> texture = [device newTextureWithDescriptor:d];
	BOOL half = format == MTLPixelFormatRGBA16Float;
	size_t pixel = half ? 8 : 4;
	uint8_t *pixels = malloc((size_t)width * height * pixel);
	for (int y = 0; y < height; y++)
		for (int x = 0; x < width; x++) {
			uint8_t v = pattern(x, y, dx, dy);
			size_t at = ((size_t)y * width + x) * pixel;
			if (half) {
				__fp16 *h = (__fp16 *)(pixels + at);
				h[0] = h[1] = h[2] = (__fp16)(v / 255.0 * 4);
				h[3] = 1;
			} else {
				uint32_t c = (uint32_t)v * 1023 / 255;
				*(uint32_t *)(pixels + at) = c | c << 10 | c << 20 | 3u << 30;
			}
		}
	[texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels
	           bytesPerRow:width * pixel];
	free(pixels);
	return texture;
}

// The pattern with its top-left third darker: a region that cuts alone
static id<MTLTexture> frame_corner(id<MTLDevice> device, int width, int height, int dx, int dy)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                             width:width height:height mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> texture = [device newTextureWithDescriptor:d];
	uint8_t *pixels = malloc((size_t)width * height * 4);
	for (int y = 0; y < height; y++)
		for (int x = 0; x < width; x++) {
			uint8_t v = pattern(x, y, dx, dy) / (x < width / 3 && y < height / 3 ? 4 : 1);
			uint8_t *p = pixels + ((size_t)y * width + x) * 4;
			p[0] = p[1] = p[2] = v;
			p[3] = 255;
		}
	[texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];
	free(pixels);
	return texture;
}

static void *readback(id<MTLCommandQueue> queue, id<MTLTexture> source, size_t pixel)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat
	                                                                             width:source.width
	                                                                            height:source.height mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> copy = [queue.device newTextureWithDescriptor:d];
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	[blit copyFromTexture:source toTexture:copy];
	[blit endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	void *bytes = malloc(source.width * source.height * pixel);
	[copy getBytes:bytes bytesPerRow:source.width * pixel fromRegion:MTLRegionMake2D(0, 0, source.width, source.height)
	   mipmapLevel:0];
	return bytes;
}

static int compare_doubles(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static double run(id<MTLCommandQueue> queue, void (^encode)(id<MTLCommandBuffer>))
{
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	encode(buffer);
	[buffer commit];
	[buffer waitUntilCompleted];
	if (buffer.error != nil)
		printf("  command buffer error: %s\n", buffer.error.localizedDescription.UTF8String);
	return (buffer.GPUEndTime - buffer.GPUStartTime) * 1000.0;
}

// Mean absolute error against the pattern moved by (dx, dy), away from the edges
static double error_against(const uint8_t *pixels, int width, int height, int dx, int dy)
{
	double sum = 0;
	long n = 0;
	for (int y = 64; y < height - 64; y++)
		for (int x = 64; x < width - 64; x++) {
			sum += abs((int)pixels[((size_t)y * width + x) * 4] - (int)pattern(x, y, dx, dy));
			n++;
		}
	return sum / (double)n;
}

// Mean difference to the pattern moved by (dx, dy), over the rectangle x0..x1, y0..y1
static double error_in(const uint8_t *pixels, int width, int x0, int y0, int x1, int y1, int dx, int dy)
{
	double sum = 0;
	long n = 0;
	for (int y = y0; y < y1; y++)
		for (int x = x0; x < x1; x++) {
			sum += abs((int)pixels[((size_t)y * width + x) * 4] - (int)pattern(x, y, dx, dy));
			n++;
		}
	return n ? sum / (double)n : 0;
}

int main(int argc, char **argv)
{
	int width = argc > 2 ? atoi(argv[1]) : 1280, height = argc > 2 ? atoi(argv[2]) : 720;
	char detail[160];
	@autoreleasepool {
		if (@available(macOS 26.0, *)) {
			id<MTLDevice> device = MTLCreateSystemDefaultDevice();
			if (device == nil || ![FGPipeline supportsDevice:device]) {
				puts("  skipped: no device with frame interpolation");
				return 77;
			}
			NSString *error = nil;
			FGPipeline *fg = [[FGPipeline alloc] initWithDevice:device error:&error];
			check("kernels compile", fg != nil, error ? error.UTF8String : "");
			if (fg == nil)
				return 1;
			BOOL ready = [fg prepareWidth:width height:height format:MTLPixelFormatBGRA8Unorm error:&error];
			check("interpolator for BGRA8", ready, error ? error.UTF8String : "");
			if (!ready)
				return 1;
			id<MTLCommandQueue> queue = [device newCommandQueue];
			// The checks below are written for quarter-size analysis in 8 px blocks
			FGSettings quarter = fg.settings;
			quarter.factor = 4;
			quarter.block = 8;
			quarter.radius = 16;
			quarter.estimator = 0;
			quarter.downscale = 1;
			[fg useSettings:quarter error:NULL];

			// Content moves 12 px right and 8 px up: each pixel came from 12 left, 8 down
			const int dx = 12, dy = -8;
			id<MTLTexture> previous = frame(device, width, height, 0, 0);
			id<MTLTexture> current = frame(device, width, height, dx, dy);
			__block BOOL had = YES;
			run(queue, ^(id<MTLCommandBuffer> b) { had = [fg encodeCapture:previous commandBuffer:b]; });
			check("the first capture has no earlier frame", !had, "");
			double capture = run(queue, ^(id<MTLCommandBuffer> b) { [fg encodeCapture:current commandBuffer:b]; });
			double motion = run(queue, ^(id<MTLCommandBuffer> b) { [fg encodeMotion:b]; });

			// Luma of the last capture against the average of each 4x4 square, computed here
			id<MTLTexture> l = fg.luma;
			uint16_t *luma = readback(queue, l, 2);
			double worst = 0;
			for (NSUInteger y = 0; y < l.height; y++)
				for (NSUInteger x = 0; x < l.width; x++) {
					double sum = 0;
					for (int j = 0; j < 4; j++)
						for (int i = 0; i < 4; i++)
							sum += pattern((int)x * 4 + i, (int)y * 4 + j, dx, dy);
					worst = fmax(worst, fabs(half_to_float(luma[y * l.width + x]) * 255 - sum / 16));
				}
			free(luma);
			snprintf(detail, sizeof(detail), "worst %.2f of 255", worst);
			check("quarter-size luma matches the CPU reference within 1 level", worst <= 1.0, detail);

			id<MTLTexture> v = fg.blockVectors;
			uint16_t *vectors = readback(queue, v, 4);
			long right = 0, inside = 0;
			for (NSUInteger y = 1; y + 1 < v.height; y++)
				for (NSUInteger x = 1; x + 1 < v.width; x++) {
					float vx = half_to_float(vectors[(y * v.width + x) * 2]);
					float vy = half_to_float(vectors[(y * v.width + x) * 2 + 1]);
					right += vx == -dx / 4 && vy == -dy / 4;
					inside++;
				}
			free(vectors);
			snprintf(detail, sizeof(detail), "%ld of %ld inner blocks", right, inside);
			check("block matching finds the shift on 95 % of blocks", right * 100 >= inside * 95, detail);

			// The vector sign MetalFX expects is not documented: the right one lands half way.
			// A steady motion over a few frames, as the interpolator keeps history.
			double best = 1e9;
			float sign = 0;
			for (int s = 1; s >= -1; s -= 2) {
				[fg reset];
				FGSettings tuned = fg.settings;
				tuned.motionScale = s;
				[fg useSettings:tuned error:NULL];
				const int steps = 4;
				for (int i = 0; i <= steps; i++) {
					id<MTLTexture> next = frame(device, width, height, dx * i, dy * i);
					run(queue, ^(id<MTLCommandBuffer> b) {
						if ([fg encodeCapture:next commandBuffer:b])
							[fg encodeFrame:b deltaTime:1.0f / 40];
					});
				}
				uint8_t *out = readback(queue, fg.output, 4);
				double half = error_against(out, width, height, dx * steps - dx / 2, dy * steps - dy / 2);
				printf("  sign %+d: error to the half-way frame %.1f, to the last %.1f, to the one before %.1f\n", s, half,
				       error_against(out, width, height, dx * steps, dy * steps),
				       error_against(out, width, height, dx * (steps - 1), dy * (steps - 1)));
				free(out);
				if (half < best) {
					best = half;
					sign = s;
				}
			}
			snprintf(detail, sizeof(detail), "error %.1f of 255 with sign %+.0f", best, sign);
			check("the generated frame sits half way (error under 12)", best < 12, detail);

			// A cut: the generated frame between two scenes repeats the last frame of the first one
			FGSettings cuts = fg.settings;
			cuts.motionScale = sign;
			cuts.cuts = 1;
			[fg useSettings:cuts error:NULL];
			[fg reset];
			for (int i = 0; i < 4; i++) {
				id<MTLTexture> next = i < 3 ? frame(device, width, height, dx * i, dy * i)
				                            : frame_lit(device, width, height, 0, 0, 4);
				run(queue, ^(id<MTLCommandBuffer> b) {
					if ([fg encodeCapture:next commandBuffer:b])
						[fg encodeFrame:b deltaTime:1.0f / 40];
				});
			}
			uint8_t *cut = readback(queue, fg.output, 4);
			double repeat = error_against(cut, width, height, dx * 2, dy * 2);
			free(cut);
			snprintf(detail, sizeof(detail), "error %.1f to the last frame before it", repeat);
			check("a scene cut repeats the frame before it", repeat < 1, detail);

			// A region that cuts alone repeats the frame before it there; the rest is interpolated
			[fg reset];
			for (int i = 0; i < 4; i++) {
				id<MTLTexture> next = i < 3 ? frame(device, width, height, dx * i, dy * i)
				                            : frame_corner(device, width, height, dx * 3, dy * 3);
				run(queue, ^(id<MTLCommandBuffer> b) {
					if ([fg encodeCapture:next commandBuffer:b])
						[fg encodeFrame:b deltaTime:1.0f / 40];
				});
			}
			uint8_t *part = readback(queue, fg.output, 4);
			double corner = error_in(part, width, 64, 64, width / 3 - 32, height / 3 - 32, dx * 2, dy * 2);
			double middle = error_in(part, width, width / 3 + 32, height / 3 + 32, 2 * width / 3 - 32, 2 * height / 3 - 32,
			                         dx * 2 + dx / 2, dy * 2 + dy / 2);
			free(part);
			snprintf(detail, sizeof(detail), "error %.1f to the frame before in the corner, %.1f to half way in the middle",
			         corner, middle);
			check("a region that cuts alone repeats the frame before it there", corner < 1, detail);
			check("and the rest is still interpolated (error under 12)", middle < 12, detail);

			// HDR and EDR: the whole pass on half floats past white and on 10-bit frames; a format
			// MetalFX refuses must fail cleanly, as the library then turns itself off
			const MTLPixelFormat wide[] = { MTLPixelFormatRGBA16Float, MTLPixelFormatRGB10A2Unorm, MTLPixelFormatBGR10A2Unorm };
			const char *wideNames[] = { "RGBA16Float", "RGB10A2Unorm", "BGR10A2Unorm" };
			for (int f = 0; f < 3; f++) {
				FGPipeline *hdr = [[FGPipeline alloc] initWithDevice:device error:&error];
				NSString *refused = nil;
				if (hdr == nil || ![hdr prepareWidth:width height:height format:wide[f] error:&refused]) {
					snprintf(detail, sizeof(detail), "%s refused: %s", wideNames[f], refused.UTF8String ?: "no pipeline");
					check("a wide format MetalFX refuses fails cleanly", refused != nil, detail);
					continue;
				}
				for (int i = 0; i < 3; i++) {
					id<MTLTexture> next = frame_wide(device, wide[f], width, height, dx * i, dy * i);
					run(queue, ^(id<MTLCommandBuffer> b) {
						if ([hdr encodeCapture:next commandBuffer:b])
							[hdr encodeFrame:b deltaTime:1.0f / 40];
					});
				}
				BOOL half = wide[f] == MTLPixelFormatRGBA16Float;
				void *out = readback(queue, hdr.output, half ? 8 : 4);
				double top = 0, sum = 0;
				long bad = 0, n = (long)width * height;
				for (long i = 0; i < n; i++) {
					double v = half ? (double)((__fp16 *)out)[i * 4] : (double)(((uint32_t *)out)[i] & 1023) / 1023;
					bad += !isfinite(v);
					top = fmax(top, v);
					sum += v;
				}
				free(out);
				snprintf(detail, sizeof(detail), "%s: brightest %.2f, mean %.3f, %ld not finite", wideNames[f], top, sum / n, bad);
				check(half ? "an EDR frame keeps its values past white" : "a 10-bit frame goes through",
				      bad == 0 && (half ? top > 3 : sum / n > 0.1), detail);
			}

			// The overlay marks a generated frame with a green square in its top-left corner
			FGSettings marked = fg.settings;
			marked.overlay = 1;
			marked.cuts = 0;
			[fg useSettings:marked error:NULL];
			for (int i = 0; i < 2; i++) {
				id<MTLTexture> next = frame(device, width, height, dx * i, dy * i);
				run(queue, ^(id<MTLCommandBuffer> b) {
					if ([fg encodeCapture:next commandBuffer:b])
						[fg encodeFrame:b deltaTime:1.0f / 40];
				});
			}
			uint8_t *mark = readback(queue, fg.output, 4);
			const uint8_t *in = mark + ((size_t)20 * width + 20) * 4, *off = mark + ((size_t)60 * width + 60) * 4;
			snprintf(detail, sizeof(detail), "BGRA %u %u %u inside, %u %u %u outside", in[0], in[1], in[2], off[0], off[1], off[2]);
			check("the overlay marks a generated frame", in[1] == 255 && in[0] == 0 && in[2] == 0 && off[0] == off[1], detail);
			free(mark);
			marked.overlay = 0;
			[fg useSettings:marked error:NULL];

			// A UI kept apart goes on top of the generated frame (macOS 27): an opaque red square and a
			// half-transparent blue one, premultiplied; composited, the final frame where it differs
			MTLTextureDescriptor *ud = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
			                                                                              width:width height:height
			                                                                          mipmapped:NO];
			ud.storageMode = MTLStorageModeShared;
			ud.usage = MTLTextureUsageShaderRead;
			id<MTLTexture> ui = [device newTextureWithDescriptor:ud];
			uint8_t *layer = calloc((size_t)width * height, 4);
			for (int y = 100; y < 132; y++)
				for (int x = 100; x < 132; x++) {
					uint8_t *red = layer + ((size_t)y * width + x) * 4, *blue = layer + ((size_t)y * width + x + 100) * 4;
					red[2] = red[3] = 255;
					blue[0] = blue[3] = 128;
				}
			[ui replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:layer bytesPerRow:width * 4];
			id<MTLTexture> final = frame(device, width, height, dx, dy);
			uint8_t *pixels = malloc((size_t)width * height * 4);
			[final getBytes:pixels bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
			for (int y = 100; y < 132; y++)
				memcpy(pixels + ((size_t)y * width + 100) * 4, layer + ((size_t)y * width + 100) * 4, 32 * 4);
			[final replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];
			free(pixels);
			free(layer);
			BOOL ours = NO;
			if (@available(macOS 27.0, *))
				ours = YES;
			for (int composited = 0; composited <= 1; composited++) {
				fg.uiTexture = composited ? final : ui;
				fg.uiComposited = composited;
				[fg prepareWidth:width height:height format:MTLPixelFormatBGRA8Unorm error:NULL];
				for (int i = 0; i < 2; i++) {
					id<MTLTexture> next = frame(device, width, height, dx * i, dy * i);
					run(queue, ^(id<MTLCommandBuffer> b) {
						if ([fg encodeCapture:next commandBuffer:b])
							[fg encodeFrame:b deltaTime:1.0f / 40];
					});
				}
				uint8_t *got = readback(queue, fg.output, 4);
				const uint8_t *red = got + ((size_t)116 * width + 116) * 4, *blue = got + ((size_t)116 * width + 216) * 4;
				BOOL redTop = red[0] == 0 && red[1] == 0 && red[2] == 255;
				BOOL blueTop = blue[0] >= 127 && blue[0] - blue[1] >= 100;
				snprintf(detail, sizeof(detail), "red BGRA %u %u %u, blue %u %u %u", red[0], red[1], red[2], blue[0], blue[1],
				         blue[2]);
				if (composited)
					check(ours ? "a composited UI goes on top of the generated frame" : "macOS 26 leaves the UI to keep_still",
					      redTop == ours, detail);
				else
					check(ours ? "a UI apart goes on top, alpha included" : "macOS 26 leaves the UI to keep_still",
					      redTop == ours && blueTop == ours, detail);
				free(got);
			}
			// A UI at another size is left out
			ud.width = width / 2;
			fg.uiTexture = [device newTextureWithDescriptor:ud];
			fg.uiComposited = NO;
			for (int i = 0; i < 2; i++) {
				id<MTLTexture> next = frame(device, width, height, dx * i, dy * i);
				run(queue, ^(id<MTLCommandBuffer> b) {
					if ([fg encodeCapture:next commandBuffer:b])
						[fg encodeFrame:b deltaTime:1.0f / 40];
				});
			}
			uint8_t *left = readback(queue, fg.output, 4);
			const uint8_t *at = left + ((size_t)116 * width + 116) * 4;
			snprintf(detail, sizeof(detail), "BGRA %u %u %u", at[0], at[1], at[2]);
			check("a UI at another size is left out", at[0] == at[1] && at[1] == at[2], detail);
			free(left);
			fg.uiTexture = nil;
			[fg prepareWidth:width height:height format:MTLPixelFormatBGRA8Unorm error:NULL];

			FGSettings tuned = fg.settings;
			tuned.motionScale = sign;
			[fg useSettings:tuned error:NULL];
			double total = 0;
			for (int i = 0; i < 10; i++) {
				id<MTLTexture> next = frame(device, width, height, dx * (i % 2), dy * (i % 2));
				total += run(queue, ^(id<MTLCommandBuffer> b) {
					[fg encodeCapture:next commandBuffer:b];
					[fg encodeFrame:b deltaTime:1.0f / 40];
				});
			}
			printf("  GPU at %dx%d: capture %.2f ms, motion %.2f ms, capture+motion+interpolation %.2f ms\n",
			       width, height, capture, motion, total / 10);
			// PIPELINE_SET="name=value,..." times other settings than the defaults
			FGSettings timed = FGDefaultSettings();
			const char *set = getenv("PIPELINE_SET");
			if (set != NULL) {
				char *copy = strdup(set), *save = NULL;
				for (char *pair = strtok_r(copy, ",", &save); pair != NULL; pair = strtok_r(NULL, ",", &save)) {
					char name[32];
					double value;
					if (sscanf(pair, "%31[^=]=%lf", name, &value) != 2)
						continue;
#define FIELD(key, field) if (strcmp(name, key) == 0) timed.field = (__typeof__(timed.field))value;
					FIELD("estimator", estimator) FIELD("factor", factor) FIELD("block", block) FIELD("median", median)
					FIELD("expand", expand) FIELD("check", check) FIELD("still", still) FIELD("cuts", cuts)
					FIELD("zero", zero) FIELD("mode", mode) FIELD("downscale", downscale) FIELD("repair", repair) FIELD("hud", hud)
#undef FIELD
				}
				free(copy);
			}
			[fg useSettings:timed error:NULL];
			// PIPELINE_REPAIR="sigma,farLo,farHi,sureLo,sureHi,reach" times other repair thresholds
			const char *repairing = getenv("PIPELINE_REPAIR");
			if (repairing != NULL) {
				FGRepair r = FGDefaultRepair();
				sscanf(repairing, "%f,%f,%f,%f,%f,%f", &r.sigma, &r.farLo, &r.farHi, &r.sureLo, &r.sureHi, &r.reach);
				fg.repairTuning = r;
			}
			// Other work on the GPU stretches some frames: min, median and p95 of 30, and the
			// same for the capture and motion passes alone (motion measured between two
			// captures of the same frame: its kernels do the same work either way)
			id<MTLTexture> pair[2] = { frame(device, width, height, 0, 0), frame(device, width, height, dx, dy) };
			double times[30], caps[30], mots[30];
			for (int i = 0; i < 30; i++) {
				id<MTLTexture> next = pair[i % 2];
				times[i] = run(queue, ^(id<MTLCommandBuffer> b) {
					[fg encodeCapture:next commandBuffer:b];
					[fg encodeFrame:b deltaTime:1.0f / 40];
				});
				caps[i] = run(queue, ^(id<MTLCommandBuffer> b) { [fg encodeCapture:next commandBuffer:b]; });
				mots[i] = run(queue, ^(id<MTLCommandBuffer> b) { [fg encodeMotion:b]; });
			}
			qsort(times, 30, sizeof(double), compare_doubles);
			qsort(caps, 30, sizeof(double), compare_doubles);
			qsort(mots, 30, sizeof(double), compare_doubles);
			printf("  GPU at %dx%d with %s: %.2f ms per generated frame, median %.2f, p95 %.2f\n", width, height,
			       set ? set : "the default settings", times[0], times[15], times[28]);
			printf("    of which capture median %.2f p95 %.2f, motion median %.2f p95 %.2f, rest %.2f\n",
			       caps[15], caps[28], mots[15], mots[28], times[15] - caps[15] - mots[15]);
		} else {
			puts("  skipped: macOS 26 or later needed");
			return 77;
		}
	}
	printf("==> framegen pipeline: %s\n", fails ? "FAILED" : "all assertions hold");
	return fails ? 1 : 0;
}
