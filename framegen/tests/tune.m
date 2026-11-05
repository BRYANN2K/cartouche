// Searches the frame generation settings on the test window's scenes: the Cartouche logo crossing
// the dark track, or the 3D flight between cubes. Each generated frame is compared with the true
// half-way frame, drawn here, so the ghosting is a number.
// Usage: tune <logo.svg> [px per frame ...] | tune --3d <logo.svg> [game fps ...]

#import "../fg_ane.h"
#import "../fg_pipeline.h"

#import <AppKit/AppKit.h>
#import <MetalFX/MetalFX.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>

#import "scene.h"
#import <stdio.h>
#import <stdlib.h>

// TUNE_W and TUNE_H change the 3D scene's size, for exports
static int width = 1280, height = 300;
static const int logoSide = 210;
static CGImageRef logo;
static BOOL flight;
static Scene3DPipes pipes;
static id<MTLTexture> hudLogo, flightColor, flightDepth, trueMotion, trueDepth;
static void dump(const uint8_t *pixels, const char *name)
{
	const char *dir = getenv("TUNE_DUMP");
	if (dir == NULL)
		return;
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGContextRef context = CGBitmapContextCreate((void *)pixels, width, height, 8, width * 4, space,
	                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGImageRef image = CGBitmapContextCreateImage(context);
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
	[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
		writeToFile:[NSString stringWithFormat:@"%s/%s.png", dir, name] atomically:YES];
	CGImageRelease(image);
	CGContextRelease(context);
	CGColorSpaceRelease(space);
}

// TUNE_ANE=1: the Neural Engine helper's flow and mask for every pair, as in a game
static FGNeural *neural;

static int trueKind; // 1: the scene's true motion, 2: its true depth as well
// Depth bench (TUNE_DEPTH=1): where the depth comes from, which camera MetalFX is told about,
// and whether the motion is the scene's own
enum { depthConstant, depthTrue, depthRamp, depthNoise };
static int depthKind = depthTrue, cameraKind, benchMotion = 1;
static id<MTLTexture> benchDepth;
static id<MTLRenderPipelineState> rampPipe, noisePipe;
static id<MTLDepthStencilState> alwaysWrite;
static NSString *fillShaders = @
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct F { float4 p [[position]]; };\n"
	"struct D { float d [[depth(any)]]; };\n"
	"vertex F fill(uint i [[vertex_id]]) { float2 c = float2((i << 1) & 2, i & 2); F o; o.p = float4(c * 2 - 1, 0, 1); return o; }\n"
	"fragment D ramp_f(F in [[stage_in]], constant float2 &size [[buffer(0)]]) { D o; o.d = mix(0.98, 0.9, in.p.y / size.y); return o; }\n"
	"fragment D noise_f(F in [[stage_in]]) { D o; o.d = 0.9 + 0.09 * fract(sin(dot(floor(in.p.xy), float2(12.9898, 78.233))) * 43758.5453); return o; }\n";

// The scene's camera at frame f, as scene.h builds it: 60 degrees vertical, near 0.1, far 200
static simd_float4x4 sceneView(double t)
{
	float yaw = sinf((float)t * 0.6f) * 0.35f, c = cosf(yaw), si = sinf(yaw);
	return simd_matrix(simd_make_float4(c, 0, -si, 0), simd_make_float4(0, 1, 0, 0), simd_make_float4(si, 0, c, 0),
	                   simd_make_float4(-sinf((float)t * 0.9f) * 1.5f, -0.4f, 0, 1));
}

static simd_float4x4 sceneProjection(void)
{
	float f = 1.0f / tanf(0.5236f), n = 0.1f, r = 200.0f, aspect = (float)1280 / 300;
	return simd_matrix(simd_make_float4(f / aspect, 0, 0, 0), simd_make_float4(0, f, 0, 0),
	                   simd_make_float4(0, 0, r / (n - r), -1), simd_make_float4(0, 0, n * r / (n - r), 0));
}

API_AVAILABLE(macos(26.0))
static void tellCamera(FGPipeline *fg, double t)
{
	id<MTLFXFrameInterpolator> fx = fg.interpolator;
	if (cameraKind == 0) {
		fx.nearPlane = 0.1f;
		fx.farPlane = 1000.0f;
		fx.fieldOfView = 60.0f;
		return;
	}
	fx.nearPlane = 0.1f;
	fx.farPlane = 200.0f;
	fx.fieldOfView = 2 * 0.5236f * 180 / (float)M_PI;
	if (@available(macOS 27.0, *)) {
		fx.worldToViewMatrix = cameraKind == 2 ? sceneView(t) : matrix_identity_float4x4;
		fx.viewToClipMatrix = cameraKind == 2 ? sceneProjection() : matrix_identity_float4x4;
	}
}

// The scene's own motion from frame "from" to frame f, and the depth of frame f
static void fly_motion_from(id<MTLCommandQueue> queue, double f, double from, double step)
{
	double t = 10 + f * step, before = 10 + from * step;
	Scene3D s = { (float)t, (float)(960 * t / 60), (float)width / height, (float)before, (float)(960 * before / 60) };
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = trueMotion;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.depthAttachment.texture = trueDepth;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = 1;
	pass.depthAttachment.storeAction = MTLStoreActionStore;
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	scene3d_motion(encoder, &pipes, s, width, height);
	[encoder endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
}

static void fly_motion(id<MTLCommandQueue> queue, double f, double step)
{
	fly_motion_from(queue, f, f - 1, step);
}

// MetalFX bench (TUNE_MFX): where the generated frame sits between the two real ones, and the
// real frames drawn without the HUD, for a UI texture MetalFX composites itself
static double phase = 0.5;
static id<MTLTexture> blankLogo;
static BOOL hudlessInput;
// Set: each real frame with its HUD goes here too, for a UI texture composited in the colour
static id<MTLTexture> uiFinal;
// The HUD's own pixels (alpha above 0), from hud_only; NULL until then
static uint8_t *hudMask;

static void fly_hud(id<MTLCommandQueue> queue, uint8_t *pixels, double f, double step, BOOL hud);

// The 3D flight f frames in, at one frame every step seconds, read back into pixels
static void fly(id<MTLCommandQueue> queue, uint8_t *pixels, double f, double step)
{
	fly_hud(queue, pixels, f, step, YES);
}

static void fly_hud(id<MTLCommandQueue> queue, uint8_t *pixels, double f, double step, BOOL hud)
{
	double t = 10 + f * step;
	Scene3D s = { (float)t, (float)(960 * t / 60), (float)width / height, (float)t, (float)(960 * t / 60) };
	Uniforms u = { { width, height }, 0, height * 0.22f, 1 };
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = flightColor;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0.11, 0.115, 0.14, 1);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.depthAttachment.texture = flightDepth;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = 1;
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	scene3d_draw(encoder, &pipes, s, u, hud ? hudLogo : blankLogo);
	[encoder endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	[flightColor getBytes:pixels bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
}

// The track shader of the test window, at scale 1
static void draw(uint8_t *pixels, double x)
{
	for (int y = 0; y < height; y++)
		for (int i = 0; i < width; i++) {
			float px = i + 0.5f, py = y + 0.5f;
			float v = (fmodf(px, 80) <= 1.5f ? 0.06f : 0) + (fmodf(floorf(py / 40), 2) <= 0.5f ? 0.015f : 0);
			uint8_t *p = pixels + ((size_t)y * width + i) * 4;
			p[0] = (uint8_t)lrintf((0.14f + v) * 255);
			p[1] = (uint8_t)lrintf((0.115f + v) * 255);
			p[2] = (uint8_t)lrintf((0.11f + v) * 255);
			p[3] = 255;
		}
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
	                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
	CGContextDrawImage(context, CGRectMake(x, (height - logoSide) / 2.0, logoSide, logoSide), logo);
	CGContextRelease(context);
	CGColorSpaceRelease(space);
}

static id<MTLTexture> texture(id<MTLDevice> device, const uint8_t *pixels)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                             width:width height:height mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> t = [device newTextureWithDescriptor:d];
	[t replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];
	return t;
}

typedef struct {
	double error, ghost, gpu, coarse, hud, outside, mask;
} Score;

// Adds one generated frame's errors against the truth
static void measure(const uint8_t *out, const uint8_t *truth, Score *score)
{
	Score s = *score;
	const int top = flight ? 0 : (height - logoSide) / 2 - 8, bottom = flight ? height : top + logoSide + 16;
	double sum = 0;
	long bad = 0, n = 0;
	for (int y = top; y < bottom; y++)
		for (int i = 0; i < width; i++) {
			const uint8_t *a = out + ((size_t)y * width + i) * 4, *b = truth + ((size_t)y * width + i) * 4;
			int e = MAX(MAX(abs(a[0] - b[0]), abs(a[1] - b[1])), abs(a[2] - b[2]));
			sum += e;
			bad += e > 24;
			n++;
		}
	s.error += sum / n;
	s.ghost += 100.0 * bad / n;
	// The same on 2x2 averages, so edge aliasing that differs between two rasterisations
	// counts less than a real ghost
	long coarseBad = 0, cells = 0, outsideBad = 0, outsideCells = 0;
	const int side = (int)(height * 0.22f), hx = 20, hy = height - side - 20;
	// TUNE_HUD_MARGIN=<px>: "out" also leaves out a band this wide around the HUD
	const int margin = getenv("TUNE_HUD_MARGIN") ? atoi(getenv("TUNE_HUD_MARGIN")) : 0;
	for (int y = top; y + 1 < bottom; y += 2)
		for (int i = 0; i + 1 < width; i += 2) {
			int e = 0;
			for (int c = 0; c < 3; c++) {
				int sa = 0, sb = 0;
				for (int k = 0; k < 4; k++) {
					size_t at = ((size_t)(y + k / 2) * width + i + k % 2) * 4 + c;
					sa += out[at];
					sb += truth[at];
				}
				e = MAX(e, abs(sa - sb) / 4);
			}
			coarseBad += e > 24;
			cells++;
			// The same away from the 3D scene's HUD
			if (!flight || i + 1 < hx - margin || i >= hx + side + margin || y + 1 < hy - margin || y >= hy + side + margin) {
				outsideBad += e > 24;
				outsideCells++;
			}
		}
	s.coarse += 100.0 * coarseBad / cells;
	s.outside += 100.0 * outsideBad / outsideCells;
	// The 3D scene's still logo, bottom left, as scene.h draws it
	if (flight) {
		long hudBad = 0, maskBad = 0, masked = 0;
		for (int y = hy; y < hy + side; y++)
			for (int i = hx; i < hx + side; i++) {
				const uint8_t *a = out + ((size_t)y * width + i) * 4, *b = truth + ((size_t)y * width + i) * 4;
				int e = MAX(MAX(abs(a[0] - b[0]), abs(a[1] - b[1])), abs(a[2] - b[2]));
				hudBad += e > 2;
				if (hudMask != NULL && hudMask[(size_t)y * width + i]) {
					maskBad += e > 2;
					masked++;
				}
			}
		s.hud += 100.0 * hudBad / (side * side);
		s.mask += masked ? 100.0 * maskBad / masked : 0;
	}
	*score = s;
}

// Mean error over the logo's rows and the share of pixels off by more than 24 levels, which is
// what reads as a ghost
API_AVAILABLE(macos(26.0))
static Score score(FGPipeline *fg, id<MTLCommandQueue> queue, double step)
{
	id<MTLDevice> device = queue.device;
	uint8_t *pixels = malloc((size_t)width * height * 4), *truth = malloc((size_t)width * height * 4);
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                             width:width height:height mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> copy = [device newTextureWithDescriptor:d];
	uint8_t *out = malloc((size_t)width * height * 4);
	[fg reset];
	Score s = { 0 };
	int measured = 0;
	const int frames = getenv("TUNE_FRAMES") ? atoi(getenv("TUNE_FRAMES")) : 24;
	for (int f = 0; f < frames; f++) {
		double x = 100 + step * f;
		if (flight && uiFinal != nil) {
			fly(queue, pixels, f, step);
			[uiFinal replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels
			           bytesPerRow:width * 4];
		}
		if (flight)
			fly_hud(queue, pixels, f, step, !hudlessInput);
		else
			draw(pixels, x);
		id<MTLTexture> frame = texture(device, pixels);
		fg.neuralFlow = fg.neuralMask = nil;
		if (neural != nil) {
			id<MTLCommandBuffer> input = [queue commandBuffer];
			[fg encodeNeuralInput:frame into:[neural inputForSlot:f & 1] commandBuffer:input];
			[input commit];
			[input waitUntilCompleted];
			if (f > 0) {
				[neural requestEarlier:(f & 1) ^ 1];
				if ([neural waitFor:1.0]) {
					fg.neuralFlow = neural.flow;
					fg.neuralMask = neural.mask;
					if (getenv("TUNE_ANE_MASK") && f == 12) {
						id<MTLTexture> m = neural.mask;
						__fp16 *v = malloc(m.width * m.height * 2);
						[m getBytes:v bytesPerRow:m.width * 2 fromRegion:MTLRegionMake2D(0, 0, m.width, m.height) mipmapLevel:0];
						double sum = 0; long lo = 0, hi = 0, n = (long)(m.width * m.height);
						for (long i = 0; i < n; i++) { sum += v[i]; lo += v[i] < 0.3; hi += v[i] > 0.7; }
						fprintf(stderr, "mask mean %.3f, <0.3 %.1f%%, >0.7 %.1f%%\n", sum / n, 100.0 * lo / n, 100.0 * hi / n);
						free(v);
					}
				}
			}
		}
		if (trueKind > 0)
			fly_motion(queue, f, step);
		fg.motionOverride = trueKind > 0 && benchMotion ? trueMotion : nil;
		// TUNE_MOTION=<dir>: motion computed offline (half floats, x and y per pixel) in place of ours
		const char *motionDir = getenv("TUNE_MOTION");
		if (motionDir != NULL && flight) {
			char path[512];
			snprintf(path, sizeof(path), "%s/%.0ffps_%02d_rifemotion.raw", motionDir, 1 / step, f);
			NSData *data = [NSData dataWithContentsOfFile:@(path)];
			if (data.length == (NSUInteger)width * height * 4) {
				static id<MTLTexture> fileMotion;
				if (fileMotion == nil) {
					MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
					                                                                              width:width height:height
					                                                                          mipmapped:NO];
					md.usage = MTLTextureUsageShaderRead;
					md.storageMode = MTLStorageModeShared;
					fileMotion = [device newTextureWithDescriptor:md];
				}
				[fileMotion replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:data.bytes
				              bytesPerRow:width * 4];
				fg.motionOverride = fileMotion;
			}
		}
		fg.depthOverride = trueKind < 2 ? nil : depthKind == depthConstant ? nil : depthKind == depthTrue ? trueDepth : benchDepth;
		if (trueKind > 1)
			tellCamera(fg, 10 + f * step);
		id<MTLCommandBuffer> buffer = [queue commandBuffer];
		BOOL had = [fg encodeCapture:frame commandBuffer:buffer];
		if (had) {
			[fg encodeFrame:buffer deltaTime:flight ? (float)step : 1.0f / 72];
			id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
			[blit copyFromTexture:fg.output toTexture:copy];
			[blit endEncoding];
		}
		[buffer commit];
		[buffer waitUntilCompleted];
		if (!had || f < 4)
			continue;
		s.gpu += (buffer.GPUEndTime - buffer.GPUStartTime) * 1000;
		if (flight)
			fly(queue, truth, f - 1 + phase, step);
		else
			draw(truth, x - step * (1 - phase));
		[copy getBytes:out bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
		// TUNE_PAIRS=<dir>: the raw BGRA frames each measured one sits between, the truth and our output,
		// for scoring other interpolators offline
		const char *pairs = getenv("TUNE_PAIRS");
		if (pairs != NULL && flight) {
			char path[512];
			uint8_t *before = malloc((size_t)width * height * 4);
			fly(queue, before, f - 1, step);
			const struct { const char *name; const uint8_t *data; } files[] = {
				{ "prev", before }, { "cur", pixels }, { "truth", truth }, { "ours", out } };
			for (size_t k = 0; k < 4; k++) {
				snprintf(path, sizeof(path), "%s/%.0ffps_%02d_%s.raw", pairs, 1 / step, f, files[k].name);
				FILE *file = fopen(path, "wb");
				if (file) {
					fwrite(files[k].data, 1, (size_t)width * height * 4, file);
					fclose(file);
				}
			}
			free(before);
		}
		if (f == 12 && fabs(step - 1.0 / 72) < 1e-4) {
			char name[64];
			snprintf(name, sizeof(name), "kind%d-out", trueKind);
			dump(out, name);
			snprintf(name, sizeof(name), "kind%d-truth", trueKind);
			dump(truth, name);
		}
		measure(out, truth, &s);
		measured++;
	}
	free(pixels);
	free(truth);
	free(out);
	s.error /= measured;
	s.ghost /= measured;
	s.coarse /= measured;
	s.hud /= measured;
	s.outside /= measured;
	s.mask /= measured;
	s.gpu /= measured;
	return s;
}

// One row of the MetalFX bench: the generated frame scored against the truth at instant t, the
// repair pass told it sits at "repairAt"
API_AVAILABLE(macos(26.0))
static void mfx_row(FGPipeline *fg, id<MTLCommandQueue> queue, const char *name, FGSettings settings, double t,
                    double repairAt, int kind, const double *steps, int speeds)
{
	// TUNE_ROW=n runs the nth row only
	static int rows;
	if (getenv("TUNE_ROW") && atoi(getenv("TUNE_ROW")) != rows++)
		return;
	NSString *refused = nil;
	if (![fg useSettings:settings error:&refused] ||
	    ![fg prepareWidth:width height:height format:MTLPixelFormatBGRA8Unorm error:&refused]) {
		printf("%-56s | refused: %s\n", name, refused.UTF8String);
		return;
	}
	phase = t;
	fg.phase = (float)repairAt;
	trueKind = kind;
	printf("%-56s |", name);
	double gpu = 0;
	for (int k = 0; k < speeds; k++) {
		Score s = score(fg, queue, steps[k]);
		printf("  %5.2f %5.2f %5.2f", s.error, s.ghost, s.coarse);
		if (getenv("TUNE_HUD"))
			printf(" hud %5.2f mask %5.2f out %5.2f", s.hud, s.mask, s.outside);
		gpu += s.gpu / speeds;
	}
	printf("  | %5.2f\n", gpu);
	fflush(stdout);
	phase = 0.5;
	fg.phase = 0.5f;
	trueKind = 0;
}

// 4x by recursion with two interpolators: a makes M half way, then b makes (previous, M) and
// (M, current). Scores at 1/4, 1/2 and 3/4. kind 2: the scene's motion and depth for each pair.
API_AVAILABLE(macos(26.0))
static void recursion(FGPipeline *a, FGPipeline *b, id<MTLCommandQueue> queue, double step, int kind, Score out[3])
{
	id<MTLDevice> device = queue.device;
	size_t bytes = (size_t)width * height * 4;
	uint8_t *pixels = malloc(bytes), *truth = malloc(bytes), *got = malloc(bytes);
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                             width:width height:height mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> copies[3] = { [device newTextureWithDescriptor:d], [device newTextureWithDescriptor:d],
	                             [device newTextureWithDescriptor:d] };
	[a reset];
	[b reset];
	memset(out, 0, 3 * sizeof(Score));
	int measured = 0;
	const int frames = getenv("TUNE_FRAMES") ? atoi(getenv("TUNE_FRAMES")) : 24;
	// pass: the pipeline, the frame it captures, the pair's instants, the copy it fills
	void (^pass)(FGPipeline *, id<MTLTexture>, double, double, id<MTLTexture>) =
		^(FGPipeline *fg, id<MTLTexture> frame, double at, double from, id<MTLTexture> copy) {
			if (kind > 0)
				fly_motion_from(queue, at, from, step);
			fg.motionOverride = kind > 0 ? trueMotion : nil;
			fg.depthOverride = kind > 1 ? trueDepth : nil;
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			if ([fg encodeCapture:frame commandBuffer:buffer] && copy != nil) {
				[fg encodeFrame:buffer deltaTime:(float)(step * (at - from))];
				id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
				[blit copyFromTexture:fg.output toTexture:copy];
				[blit endEncoding];
			}
			[buffer commit];
			[buffer waitUntilCompleted];
		};
	for (int f = 0; f < frames; f++) {
		fly(queue, pixels, f, step);
		id<MTLTexture> frame = texture(device, pixels);
		if (f == 0) {
			pass(a, frame, f, f - 1, nil);
			pass(b, frame, f, f - 1, nil);
			continue;
		}
		pass(a, frame, f, f - 1, copies[1]);
		pass(b, a.output, f - 0.5, f - 1, copies[0]);
		pass(b, frame, f, f - 0.5, copies[2]);
		if (f < 4)
			continue;
		for (int k = 0; k < 3; k++) {
			fly(queue, truth, f - 1 + 0.25 * (k + 1), step);
			[copies[k] getBytes:got bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
			measure(got, truth, &out[k]);
		}
		measured++;
	}
	for (int k = 0; k < 3; k++) {
		out[k].error /= measured;
		out[k].ghost /= measured;
		out[k].coarse /= measured;
		out[k].hud /= measured;
	}
	free(pixels);
	free(truth);
	free(got);
}

// The presenter's 4x and auto: one MetalFX pass at the middle, then a repair pass per phase, each
// output scored against the truth at its own instant
API_AVAILABLE(macos(26.0))
static void multi(FGPipeline *fg, id<MTLCommandQueue> queue, double step, const float *phases, int count, Score *out)
{
	id<MTLDevice> device = queue.device;
	size_t bytes = (size_t)width * height * 4;
	uint8_t *pixels = malloc(bytes), *truth = malloc(bytes), *got = malloc(bytes);
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                             width:width height:height mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> copies[3];
	for (int k = 0; k < count; k++)
		copies[k] = [device newTextureWithDescriptor:d];
	[fg reset];
	memset(out, 0, (size_t)count * sizeof(Score));
	int measured = 0;
	const int frames = getenv("TUNE_FRAMES") ? atoi(getenv("TUNE_FRAMES")) : 24;
	for (int f = 0; f < frames; f++) {
		fly(queue, pixels, f, step);
		id<MTLTexture> frame = texture(device, pixels);
		id<MTLCommandBuffer> buffer = [queue commandBuffer];
		BOOL had = [fg encodeCapture:frame commandBuffer:buffer];
		if (had) {
			[fg encodeFrames:buffer deltaTime:(float)step phases:phases count:count];
			id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
			for (int k = 0; k < count; k++)
				[blit copyFromTexture:[fg outputAt:k] toTexture:copies[k]];
			[blit endEncoding];
		}
		[buffer commit];
		[buffer waitUntilCompleted];
		if (!had || f < 4)
			continue;
		for (int k = 0; k < count; k++) {
			fly(queue, truth, f - 1 + phases[k], step);
			[copies[k] getBytes:got bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
			measure(got, truth, &out[k]);
		}
		out[0].gpu += (buffer.GPUEndTime - buffer.GPUStartTime) * 1000;
		measured++;
	}
	for (int k = 0; k < count; k++) {
		out[k].error /= measured;
		out[k].ghost /= measured;
		out[k].coarse /= measured;
	}
	out[0].gpu /= measured;
	free(pixels);
	free(truth);
	free(got);
}

// The HUD alone on a clear frame, premultiplied, as scene.h draws it
static id<MTLTexture> hud_only(id<MTLCommandQueue> queue)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                             width:width height:height mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> ui = [queue.device newTextureWithDescriptor:d];
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = ui;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.depthAttachment.texture = flightDepth;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = 1;
	Uniforms u = { { width, height }, 0, height * 0.22f, 1 };
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	[encoder setRenderPipelineState:pipes.hud];
	[encoder setVertexBytes:&u length:sizeof(u) atIndex:0];
	[encoder setFragmentTexture:hudLogo atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[encoder endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	uint8_t *pixels = malloc((size_t)width * height * 4);
	[ui getBytes:pixels bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
	free(hudMask);
	hudMask = malloc((size_t)width * height);
	for (size_t i = 0; i < (size_t)width * height; i++)
		hudMask[i] = pixels[i * 4 + 3] > 0;
	free(pixels);
	return ui;
}

static const char *expandName(int e) { return e == 0 ? "bilinear" : e == 1 ? "nearest" : "refined"; }

int main(int argc, char **argv)
{
	@autoreleasepool {
		flight = argc > 1 && strcmp(argv[1], "--3d") == 0;
		if (getenv("TUNE_W") && getenv("TUNE_H")) {
			width = atoi(getenv("TUNE_W"));
			height = atoi(getenv("TUNE_H"));
		}
		if (flight) {
			argv++;
			argc--;
		}
		if (argc < 2) {
			fputs("usage: tune <logo.svg> [px per frame ...] | tune --3d <logo.svg> [game fps ...]\n", stderr);
			return 2;
		}
		if (@available(macOS 26.0, *)) {
			NSImage *image = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
			NSRect rect = NSMakeRect(0, 0, logoSide, logoSide);
			logo = [image CGImageForProposedRect:&rect context:nil hints:nil];
			if (logo == NULL) {
				fprintf(stderr, "tune: cannot read %s\n", argv[1]);
				return 3;
			}
			double steps[8] = { 960.0 / 72 };
			__block int speeds = 1;
			if (flight)
				steps[0] = 1.0 / 72;
			if (argc > 2)
				for (speeds = 0; speeds + 2 < argc && speeds < 8; speeds++)
					steps[speeds] = flight ? 1.0 / atof(argv[speeds + 2]) : atof(argv[speeds + 2]);

			double *list = steps;
			id<MTLDevice> device = MTLCreateSystemDefaultDevice();
			NSString *error = nil;
			FGPipeline *fg = [[FGPipeline alloc] initWithDevice:device error:&error];
			if (fg == nil || ![fg prepareWidth:width height:height format:MTLPixelFormatBGRA8Unorm error:&error]) {
				fprintf(stderr, "tune: %s\n", error.UTF8String);
				return 1;
			}
			id<MTLCommandQueue> queue = [device newCommandQueue];
			if (flight) {
				NSError *failure = nil;
				id<MTLLibrary> library = [device newLibraryWithSource:shaders options:nil error:&failure];
				if (library == nil || !scene3d_build(device, library, &pipes, &failure)) {
					fprintf(stderr, "tune: %s\n", failure.localizedDescription.UTF8String);
					return 1;
				}
				NSRect big = NSMakeRect(0, 0, 512, 512);
				hudLogo = [[[MTKTextureLoader alloc] initWithDevice:device]
					newTextureWithCGImage:[image CGImageForProposedRect:&big context:nil hints:nil]
					              options:@{ MTKTextureLoaderOptionSRGB: @NO } error:&failure];
				MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
				                                                                             width:width height:height
				                                                                         mipmapped:NO];
				d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
				d.storageMode = MTLStorageModeShared;
				flightColor = [device newTextureWithDescriptor:d];
				d.pixelFormat = MTLPixelFormatDepth32Float;
				d.storageMode = MTLStorageModePrivate;
				flightDepth = [device newTextureWithDescriptor:d];
				d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
				trueDepth = [device newTextureWithDescriptor:d];
				d.pixelFormat = MTLPixelFormatRG16Float;
				d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
				trueMotion = [device newTextureWithDescriptor:d];
			}

			if (flight && getenv("TUNE_ANE") != NULL) {
				NSString *bin = [@(argv[-1]) stringByDeletingLastPathComponent];
				NSString *out = [bin stringByDeletingLastPathComponent], *failure = nil;
				neural = [FGNeural startWithDevice:device helper:[out stringByAppendingPathComponent:@"framegen-ane"]
				                             model:[out stringByAppendingPathComponent:@"framegen-flow.mlmodelc"]
				                             error:&failure];
				for (int i = 0; i < 500 && neural != nil && !neural.ready; i++)
					usleep(20000);
				if (neural == nil || !neural.ready) {
					fprintf(stderr, "tune: no Neural Engine helper: %s\n", failure.UTF8String ?: "not ready");
					return 1;
				}
				// The repair pass's Neural Engine priors, one at a time then together
				struct { const char *name; float occlusion, flows; } rows[] = {
					{ "ANE flow, no prior", 0, 0 },
					{ "ANE flow, two flows as a candidate (default)", 0, 1 },
					{ "ANE flow, mask in the mix", 1, 0 },
					{ "ANE flow, mask at half strength + two flows", 0.5f, 1 },
					{ "ANE flow, mask at quarter strength + two flows", 0.25f, 1 },
				};
				[fg useSettings:FGDefaultSettings() error:NULL];
				printf("%-44s |", "Neural Engine prior");
				for (int k = 0; k < speeds; k++)
					printf("  %3.0f fps: err ghost%% 2x2%%", 1 / steps[k]);
				printf("  | gpu ms\n");
				FGNeural *kept = neural;
				for (int r = -1; r < (int)(sizeof(rows) / sizeof(rows[0])); r++) {
					if (getenv("TUNE_ROW") && atoi(getenv("TUNE_ROW")) != r)
						continue;
					FGRepair tuning = FGDefaultRepair();
					tuning.flows = 0;
					if (r >= 0) {
						tuning.occlusion = rows[r].occlusion;
						tuning.flows = rows[r].flows;
					}
					fg.repairTuning = tuning;
					neural = r >= 0 ? kept : nil;
					printf("%-44s |", r >= 0 ? rows[r].name : "GPU estimate, for scale");
					double gpu = 0;
					for (int k = 0; k < speeds; k++) {
						Score s = score(fg, queue, steps[k]);
						printf("          %5.2f %5.2f %5.2f", s.error, s.ghost, s.coarse);
						gpu += s.gpu / speeds;
					}
					printf("  | %5.2f\n", gpu);
					fflush(stdout);
				}
				[kept stop];
				return 0;
			}

			// TUNE_MULTI=1: 2x, 4x and auto as the presenter makes them, 2x2 % per phase
			if (flight && getenv("TUNE_MULTI") != NULL) {
				struct { const char *name; float phases[3]; int count; } rows[] = {
					{ "2x: 1/2", { 0.5f }, 1 },
					{ "4x: 1/4 1/2 3/4", { 0.25f, 0.5f, 0.75f }, 3 },
					{ "auto, 40 fps on 144 Hz, 3 refreshes: 1/3 2/3", { 1 / 3.0f, 2 / 3.0f }, 2 },
				};
				[fg useSettings:FGDefaultSettings() error:NULL];
				printf("%-44s |", "multiplier");
				for (int k = 0; k < speeds; k++)
					printf("  %3.0f fps: 2x2%% per phase   gpu ms", 1 / steps[k]);
				printf("\n");
				for (size_t r = 0; r < sizeof(rows) / sizeof(rows[0]); r++) {
					printf("%-44s |", rows[r].name);
					for (int k = 0; k < speeds; k++) {
						Score out[3];
						multi(fg, queue, steps[k], rows[r].phases, rows[r].count, out);
						printf("  ");
						for (int i = 0; i < 3; i++)
							printf(i < rows[r].count ? " %5.2f" : "      ", out[i].coarse);
						printf("  %5.2f", out[0].gpu);
					}
					printf("\n");
					fflush(stdout);
				}
				return 0;
			}

			// TUNE_MFX: phase 0.4's MetalFX questions on the 3D scene. b: another instant through scaled
			// vectors; c: 4x by recursion; e: MetalFX's UI texture against keep_still (with TUNE_HUD);
			// f: no previous colour, cost and score (run at 1920x1080 through TUNE_W and TUNE_H)
			const char *bench = getenv("TUNE_MFX");
			if (flight && bench != NULL) {
				uint8_t clear[4] = { 0 };
				MTLTextureDescriptor *one = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
				                                                                             width:1 height:1 mipmapped:NO];
				blankLogo = [device newTextureWithDescriptor:one];
				[blankLogo replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:clear bytesPerRow:4];
				FGSettings base = FGDefaultSettings(), row;
				char name[96];
				printf("%-56s |", "TUNE_MFX row");
				for (int k = 0; k < speeds; k++)
					printf("  %3.0f fps: err ghost%% 2x2%%", 1 / steps[k]);
				printf("  | gpu ms\n");
				if (strchr(bench, 'b')) {
					mfx_row(fg, queue, "t=1/2 against t=1/2 (today's 2x, for scale)", base, 0.5, 0.5, 0, steps, speeds);
					mfx_row(fg, queue, "t=1/2 against t=1/2, scene motion", base, 0.5, 0.5, 2, steps, speeds);
					for (int q = 1; q <= 3; q += 2) {
						double t = q / 4.0;
						for (int kind = 0; kind <= 2; kind += 2) {
							const char *motion = kind ? "scene motion" : "estimated";
							row = base;
							row.mode = 2;
							snprintf(name, sizeof(name), "t=%d/4: previous frame again", q);
							if (kind == 0)
								mfx_row(fg, queue, name, row, t, 0.5, kind, steps, speeds);
							snprintf(name, sizeof(name), "t=%d/4: the t=1/2 frame, %s", q, motion);
							mfx_row(fg, queue, name, base, t, 0.5, kind, steps, speeds);
							snprintf(name, sizeof(name), "t=%d/4: k=1, repair at t, %s", q, motion);
							mfx_row(fg, queue, name, base, t, t, kind, steps, speeds);
							const float scales[] = { 0.5f, 1.5f };
							for (int i = 0; i < 2; i++) {
								row = base;
								row.motionScale = scales[i];
								snprintf(name, sizeof(name), "t=%d/4: k=%.1f, repair at t, %s", q, scales[i], motion);
								mfx_row(fg, queue, name, row, t, t, kind, steps, speeds);
								row.repair = 0;
								snprintf(name, sizeof(name), "t=%d/4: k=%.1f, no repair, %s", q, scales[i], motion);
								mfx_row(fg, queue, name, row, t, t, kind, steps, speeds);
							}
						}
					}
				}
				if (strchr(bench, 'c')) {
					NSString *failure = nil;
					FGPipeline *second = [[FGPipeline alloc] initWithDevice:device error:&failure];
					if (second == nil || ![second prepareWidth:width height:height format:MTLPixelFormatBGRA8Unorm error:&failure]) {
						fprintf(stderr, "tune: %s\n", failure.UTF8String);
						return 1;
					}
					[fg useSettings:base error:NULL];
					printf("%-56s |", "4x by recursion");
					for (int k = 0; k < speeds; k++)
						printf("  %3.0f fps: 2x2%% at 1/4 1/2 3/4", 1 / steps[k]);
					printf("\n");
					for (int kind = 0; kind <= 2; kind += 2) {
						printf("%-56s |", kind ? "two interpolators, scene motion" : "two interpolators, estimated");
						for (int k = 0; k < speeds; k++) {
							Score out[3];
							recursion(fg, second, queue, steps[k], kind, out);
							printf("              %5.2f %5.2f %5.2f", out[0].coarse, out[1].coarse, out[2].coarse);
						}
						printf("\n");
						fflush(stdout);
					}
				}
				if (strchr(bench, 'e')) {
					// 1.4: keep_still against the UI kept apart, our composite after the repair pass, MetalFX
					// told or not; "out" is the 2x2 share away from the HUD
					id<MTLTexture> ui = hud_only(queue);
					// TUNE_KIND=2: the scene's own motion and depth in place of the estimate
					const int kind = getenv("TUNE_KIND") ? atoi(getenv("TUNE_KIND")) : 0;
					MTLTextureDescriptor *fd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
					                                                                              width:width height:height
					                                                                          mipmapped:NO];
					fd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
					fd.storageMode = MTLStorageModeShared;
					id<MTLTexture> final = [device newTextureWithDescriptor:fd];
					for (int down = 0; down <= 1; down++) {
						row = base;
						row.downscale = down ? 1 : 0;
						const char *size = down ? "full size" : "half size";
						snprintf(name, sizeof(name), "MetalFX %s, keep_still (hud=4)", size);
						mfx_row(fg, queue, name, row, 0.5, 0.5, kind, steps, speeds);
						row.repair = 0;
						snprintf(name, sizeof(name), "MetalFX %s, keep_still (hud=4), no repair", size);
						mfx_row(fg, queue, name, row, 0.5, 0.5, kind, steps, speeds);
						row.repair = base.repair;
						hudlessInput = YES;
						snprintf(name, sizeof(name), "MetalFX %s, captures without HUD, no UI", size);
						mfx_row(fg, queue, name, row, 0.5, 0.5, kind, steps, speeds);
						for (int composited = 0; composited <= 1; composited++)
							for (int told = 0; told <= down; told++) {
								fg.uiTexture = composited ? final : ui;
								fg.uiComposited = composited;
								fg.uiToMetalFX = told;
								uiFinal = composited ? final : nil;
								snprintf(name, sizeof(name), "MetalFX %s, UI %s%s", size,
								         composited ? "composited" : "apart", told ? ", MetalFX told" : "");
								mfx_row(fg, queue, name, row, 0.5, 0.5, kind, steps, speeds);
								row.repair = 0;
								snprintf(name, sizeof(name), "MetalFX %s, UI %s%s, no repair", size,
								         composited ? "composited" : "apart", told ? ", MetalFX told" : "");
								mfx_row(fg, queue, name, row, 0.5, 0.5, kind, steps, speeds);
								row.repair = base.repair;
							}
						fg.uiTexture = nil;
						fg.uiComposited = fg.uiToMetalFX = NO;
						uiFinal = nil;
						hudlessInput = NO;
					}
				}
				if (strchr(bench, 'f')) {
					for (int round = 0; round < 3; round++)
						for (int down = 0; down <= 1; down++)
							for (int noPrev = 0; noPrev <= 1; noPrev++) {
								fg.noPrevColor = noPrev;
								row = base;
								row.downscale = down ? 1 : 0;
								snprintf(name, sizeof(name), "%dx%d, MetalFX %s, requiresPrevColorTexture %s", width, height,
								         down ? "full size" : "auto size", noPrev ? "NO" : "YES");
								mfx_row(fg, queue, name, row, 0.5, 0.5, 0, steps, speeds);
							}
					fg.noPrevColor = NO;
				}
				return 0;
			}

			if (flight && getenv("TUNE_DEPTH") != NULL) {
				NSError *failure = nil;
				id<MTLLibrary> fills = [device newLibraryWithSource:fillShaders options:nil error:&failure];
				MTLRenderPipelineDescriptor *describe = [MTLRenderPipelineDescriptor new];
				describe.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
				describe.vertexFunction = [fills newFunctionWithName:@"fill"];
				describe.fragmentFunction = [fills newFunctionWithName:@"ramp_f"];
				rampPipe = [device newRenderPipelineStateWithDescriptor:describe error:&failure];
				describe.fragmentFunction = [fills newFunctionWithName:@"noise_f"];
				noisePipe = [device newRenderPipelineStateWithDescriptor:describe error:&failure];
				MTLDepthStencilDescriptor *always = [MTLDepthStencilDescriptor new];
				always.depthCompareFunction = MTLCompareFunctionAlways;
				always.depthWriteEnabled = YES;
				alwaysWrite = [device newDepthStencilStateWithDescriptor:always];
				MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
				                                                                             width:width height:height
				                                                                         mipmapped:NO];
				d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
				d.storageMode = MTLStorageModePrivate;
				benchDepth = [device newTextureWithDescriptor:d];
				if (rampPipe == nil || noisePipe == nil || benchDepth == nil) {
					fprintf(stderr, "tune: %s\n", failure.localizedDescription.UTF8String);
					return 1;
				}
				void (^fill)(id<MTLRenderPipelineState>) = ^(id<MTLRenderPipelineState> pipe) {
					MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
					pass.depthAttachment.texture = benchDepth;
					pass.depthAttachment.loadAction = MTLLoadActionClear;
					pass.depthAttachment.storeAction = MTLStoreActionStore;
					id<MTLCommandBuffer> buffer = [queue commandBuffer];
					id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
					float size[2] = { width, height };
					[encoder setRenderPipelineState:pipe];
					[encoder setDepthStencilState:alwaysWrite];
					[encoder setFragmentBytes:size length:sizeof(size) atIndex:0];
					[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
					[encoder endEncoding];
					[buffer commit];
					[buffer waitUntilCompleted];
				};
				BOOL matrices = NO;
				if (@available(macOS 27.0, *))
					matrices = YES;
				struct { const char *name; int kind, depth, camera, motion, mode; } rows[] = {
					{ "50/50 blend, for scale", 0, depthConstant, 0, 0, 1 },
					{ "previous frame again, for scale", 0, depthConstant, 0, 0, 2 },
					{ "true motion, constant depth 0.5, camera far 1000", 2, depthConstant, 0, 1, 0 },
					{ "true motion, true depth, camera far 1000", 2, depthTrue, 0, 1, 0 },
					{ "true motion, true depth, matching camera", 2, depthTrue, 1, 1, 0 },
					{ "true motion, true depth, matching camera + matrices", 2, depthTrue, 2, 1, 0 },
					{ "true motion, ramp depth, matching camera", 2, depthRamp, 1, 1, 0 },
					{ "true motion, noise depth, matching camera", 2, depthNoise, 1, 1, 0 },
					{ "estimated motion, constant depth (today)", 0, depthConstant, 0, 0, 0 },
					{ "estimated motion, true depth, matching camera + matrices", 2, depthTrue, 2, 0, 0 },
				};
				FGSettings base = FGDefaultSettings();
				if (![fg useSettings:base error:&error]) {
					fprintf(stderr, "tune: %s\n", error.UTF8String);
					return 1;
				}
				printf("%-58s |", "depth bench");
				for (int k = 0; k < speeds; k++)
					printf("  %3.0f fps: err ghost%% 2x2%%", 1 / steps[k]);
				printf("\n");
				for (size_t r = 0; r < sizeof(rows) / sizeof(rows[0]); r++) {
					if ((rows[r].camera == 2 && !matrices) || (getenv("TUNE_ROW") && atoi(getenv("TUNE_ROW")) != (int)r))
						continue;
					trueKind = rows[r].kind;
					depthKind = rows[r].depth;
					cameraKind = rows[r].camera;
					benchMotion = rows[r].motion;
					FGSettings row = base;
					row.mode = rows[r].mode;
					[fg useSettings:row error:NULL];
					if (depthKind == depthRamp)
						fill(rampPipe);
					if (depthKind == depthNoise)
						fill(noisePipe);
					printf("%-58s |", rows[r].name);
					for (int k = 0; k < speeds; k++) {
						Score s = score(fg, queue, steps[k]);
						printf("          %5.2f %5.2f %5.2f", s.error, s.ghost, s.coarse);
						if (getenv("TUNE_HUD"))
							printf(" hud>2: %5.2f%%", s.hud);
					}
					printf("\n");
					fflush(stdout);
				}
				return 0;
			}

			printf("mode       est factor block median expand   bias chk still cut  |");
			for (int k = 0; k < speeds; k++)
				printf(flight ? "  %5.0f fps: err ghost%% 2x2%%" : "  %5.1f px: err ghost%% 2x2%%", flight ? 1 / steps[k] : steps[k]);
			printf("  | gpu ms\n");

			void (^trial)(FGSettings) = ^(FGSettings settings) {
				NSString *refused = nil;
				if (![fg useSettings:settings error:&refused]) {
					printf("refused: %s\n", refused.UTF8String);
					return;
				}
				const char *mode = settings.mode == 1 ? "blend" : trueKind == 1 ? "true-mv" : trueKind == 2 ? "true-mv+z"
				                 : settings.zero ? "no-motion" : "metalfx";
				printf("%-10s %3d %6d %5d %6d %-8s %5.3f %3d %5d %3d  |", mode, settings.estimator, settings.factor,
				       settings.block, settings.median, expandName(settings.expand), settings.bias, settings.check,
				       settings.still, settings.cuts);
				double gpu = 0;
				for (int k = 0; k < speeds; k++) {
					Score s = score(fg, queue, list[k]);
					printf("          %5.2f %5.2f %5.2f", s.error, s.ghost, s.coarse);
					if (flight && getenv("TUNE_HUD"))
						printf(" hud>2: %5.2f%%", s.hud);
					gpu += s.gpu / speeds;
				}
				printf("  | %5.2f\n", gpu);
				fflush(stdout);
			};

			FGSettings base = FGDefaultSettings();
			// TUNE_REPAIR="sigma,farLo,farHi,sureLo,sureHi,reach[,occlusion,flows]" overrides the repair thresholds
			const char *repairing = getenv("TUNE_REPAIR");
			if (repairing != NULL) {
				FGRepair r = FGDefaultRepair();
				sscanf(repairing, "%f,%f,%f,%f,%f,%f,%f,%f", &r.sigma, &r.farLo, &r.farHi, &r.sureLo, &r.sureHi, &r.reach,
				       &r.occlusion, &r.flows);
				fg.repairTuning = r;
			}
			// TUNE_SET="name=value,..." runs that one setting only, for a quick look
			const char *only = getenv("TUNE_SET");
			if (only != NULL) {
				FGSettings s = base;
				char *copy = strdup(only), *save = NULL;
				for (char *pair = strtok_r(copy, ",", &save); pair != NULL; pair = strtok_r(NULL, ",", &save)) {
					char name[32];
					double value;
					if (sscanf(pair, "%31[^=]=%lf", name, &value) != 2)
						continue;
#define FIELD(key, field) if (strcmp(name, key) == 0) s.field = (__typeof__(s.field))value;
					FIELD("estimator", estimator) FIELD("factor", factor) FIELD("block", block) FIELD("radius", radius)
					FIELD("median", median) FIELD("expand", expand) FIELD("bias", bias) FIELD("check", check)
					FIELD("still", still) FIELD("cuts", cuts) FIELD("zero", zero) FIELD("mode", mode) FIELD("downscale", downscale)
					FIELD("repair", repair) FIELD("hud", hud)
#undef FIELD
				}
				free(copy);
				trial(s);
				return 0;
			}
			FGSettings blend = base;
			blend.mode = 1;
			trial(blend);
			FGSettings none = base;
			none.zero = 1;
			trial(none);
			if (flight) {
				trueKind = 2;
				trial(base);
				trueKind = 0;
			}
			// The block matcher as it was, then the pyramid around the defaults
			FGSettings blocks = base;
			blocks.estimator = 0;
			blocks.check = blocks.still = 0;
			trial(blocks);
			blocks.still = 1;
			trial(blocks);
			const float biases[] = { 0, 0.05f, 0.2f };
			for (int f = 1; f <= 2; f++)
				for (int c = 0; c <= 1; c++)
					for (int m = 0; m <= 1; m++)
						for (int e = 0; e <= 2; e++)
							for (int i = 0; i < 3; i++) {
								FGSettings s = base;
								s.factor = f;
								s.check = c;
								s.median = m;
								s.expand = e;
								s.bias = biases[i];
								trial(s);
							}
			FGSettings moving = base;
			moving.still = 0;
			trial(moving);
		} else {
			puts("tune: macOS 26 or later needed");
			return 77;
		}
	}
	return 0;
}
