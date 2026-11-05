// Scores frame generation on a real D3D12 game's frames: the FSR sample's output and motion as
// the FFX proxy hands them to the library (CARTOUCHE_FFX_COPY=2, CARTOUCHE_FRAMEGEN_FFX_DUMP).
// Frames k-1 and k+1 go in, frame k is the truth: the game runs at half its rate. The game's
// motion over the two frames is its two vectors chained, k+1 to k then k to k-1; "late" chains
// the two before them, k to k-1 then k-1 to k-2, as when the library takes the last vectors that
// arrived instead of waiting for the frame's own. SCORE_SHIFT=<n> takes the game's vectors n frames
// later for the "game" column, to check how its numbers line up with the frames. Errors as tune
// counts them: the share of 2x2 blocks off by more than 24 levels on any channel. SCORE_MOTION_SCALE
// multiplies the game's motion (-1 turns it around: a check that it is read the right way).
// Vectors the library would refuse (NaN or longer than the frame is wide, on more than 0.2 % of pixels) leave
// the pair to our estimate, as in a game.
// SCORE_UI=1 scores the UI instead, on real frames without and with it (CARTOUCHE_FFX_UI=1): our
// frame generation fed the final frames, as from any game, against the frames without UI with
// the final frame as MetalFX's composited uiTexture, the game's motion for both. "ui" counts the
// pixels where the truth's UI is, off by more than 2 levels, as phase1-hud.md does.
// Usage: score <dump dir>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "../../fg_pipeline.h"

typedef struct {
	uint64_t frame;
	uint32_t width, height, format;
} Entry;

static Entry colors[4096], motions[4096];
static int ncolors, nmotions;

static NSData *load_motion(const char *dir, Entry e)
{
	char path[1024];
	snprintf(path, sizeof(path), "%s/motion-%llu-%ux%u.f32", dir, (unsigned long long)e.frame, e.width, e.height);
	return [NSData dataWithContentsOfFile:@(path)];
}

static float unpack(uint32_t bits, int mantissa)
{
	uint32_t e = bits >> mantissa, m = bits & ((1u << mantissa) - 1);
	if (e == 0)
		return ldexpf((float)m, -14 - mantissa);
	return e == 31 ? 65504 : ldexpf(1.0f + (float)m / (float)(1u << mantissa), (int)e - 15);
}

static uint8_t tone(float v)
{
	v = v > 0 ? v / (1 + v) : 0;
	return (uint8_t)lrintf(powf(v, 1 / 2.2f) * 255);
}

// The upscaler's output as copied (HDR in the sample) through x / (1 + x) and a 2.2 gamma, to BGRA8
static NSData *load_color(const char *dir, Entry e)
{
	char path[1024];
	snprintf(path, sizeof(path), "%s/color-%llu-%ux%u-f%u.raw", dir, (unsigned long long)e.frame, e.width, e.height,
	         e.format);
	NSData *raw = [NSData dataWithContentsOfFile:@(path)];
	NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)e.width * e.height * 4];
	uint8_t *o = out.mutableBytes;
	for (size_t i = 0; raw != nil && i < (size_t)e.width * e.height; i++) {
		float r, g, b;
		if (e.format == 26) {
			uint32_t v = ((const uint32_t *)raw.bytes)[i];
			r = unpack(v & 0x7ff, 6), g = unpack(v >> 11 & 0x7ff, 6), b = unpack(v >> 22, 5);
		} else if (e.format == 10) {
			const _Float16 *p = (const _Float16 *)raw.bytes + 4 * i;
			r = p[0], g = p[1], b = p[2];
		} else {
			const uint8_t *p = (const uint8_t *)raw.bytes + 4 * i;
			r = p[0] / 255.0f, g = p[1] / 255.0f, b = p[2] / 255.0f;
		}
		o[4 * i] = tone(b), o[4 * i + 1] = tone(g), o[4 * i + 2] = tone(r), o[4 * i + 3] = 255;
	}
	return out;
}

static const Entry *find(const Entry *list, int n, uint64_t frame)
{
	for (int i = 0; i < n; i++)
		if (list[i].frame == frame)
			return &list[i];
	return NULL;
}

static double blocks(const uint8_t *out, const uint8_t *truth, uint32_t w, uint32_t h)
{
	long bad = 0, cells = 0;
	for (uint32_t y = 0; y + 1 < h; y += 2)
		for (uint32_t i = 0; i + 1 < w; i += 2) {
			int e = 0;
			for (int c = 0; c < 3; c++) {
				int sa = 0, sb = 0;
				for (int k = 0; k < 4; k++) {
					size_t at = ((size_t)(y + k / 2) * w + i + k % 2) * 4 + c;
					sa += out[at];
					sb += truth[at];
				}
				e = MAX(e, abs(sa - sb) / 4);
			}
			bad += e > 24;
			cells++;
		}
	return 100.0 * bad / cells;
}

static void sample(const float *m, uint32_t w, uint32_t h, float x, float y, float out[2])
{
	x = fminf(fmaxf(x, 0), w - 1.001f), y = fminf(fmaxf(y, 0), h - 1.001f);
	uint32_t x0 = (uint32_t)x, y0 = (uint32_t)y;
	float fx = x - x0, fy = y - y0;
	for (int c = 0; c < 2; c++) {
		float a = m[(y0 * w + x0) * 2 + c], b = m[(y0 * w + x0 + 1) * 2 + c];
		float d = m[((y0 + 1) * w + x0) * 2 + c], e = m[((y0 + 1) * w + x0 + 1) * 2 + c];
		out[c] = (a * (1 - fx) + b * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy;
	}
}

static BOOL refused(const float *m, uint32_t w, uint32_t h)
{
	uint64_t bad = 0;
	float limit = (float)MAX(w, h);
	for (size_t i = 0; i < (size_t)w * h; i++) {
		float x = m[2 * i], y = m[2 * i + 1];
		bad += isnan(x) || isnan(y) || sqrtf(x * x + y * y) > limit;
	}
	return bad * 500 > (uint64_t)w * h;
}

static id<MTLTexture> texture(id<MTLDevice> device, MTLPixelFormat format, uint32_t w, uint32_t h, const void *bytes,
                              NSUInteger row)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	d.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> t = [device newTextureWithDescriptor:d];
	if (bytes != NULL)
		[t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:bytes bytesPerRow:row];
	return t;
}

API_AVAILABLE(macos(26.0))
static double generate(FGPipeline *fg, id<MTLCommandQueue> queue, id<MTLTexture> prev, id<MTLTexture> cur,
                       id<MTLTexture> motion, id<MTLTexture> copy, const uint8_t *truth, uint8_t *out)
{
	[fg reset];
	fg.engineMotion = nil;
	id<MTLCommandBuffer> first = [queue commandBuffer];
	[fg encodeCapture:prev commandBuffer:first];
	[first commit];
	fg.engineMotion = motion;
	fg.engineMotionScale = getenv("SCORE_MOTION_SCALE") ? (float)atof(getenv("SCORE_MOTION_SCALE")) : 1;
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	if (![fg encodeCapture:cur commandBuffer:buffer])
		return -1;
	[fg encodeFrame:buffer deltaTime:1.0f / 30];
	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	[blit copyFromTexture:fg.output toTexture:copy];
	[blit endEncoding];
	[buffer commit];
	[buffer waitUntilCompleted];
	[copy getBytes:out bytesPerRow:copy.width * 4 fromRegion:MTLRegionMake2D(0, 0, copy.width, copy.height) mipmapLevel:0];
	return blocks(out, truth, (uint32_t)copy.width, (uint32_t)copy.height);
}

static NSData *load_ldr(const char *dir, const char *kind, uint64_t frame, uint32_t *w, uint32_t *h)
{
	NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(dir) error:nil];
	NSString *prefix = [NSString stringWithFormat:@"%s-%llu-", kind, (unsigned long long)frame];
	for (NSString *name in names) {
		uint32_t format;
		if (![name hasPrefix:prefix] ||
		    sscanf(name.UTF8String + prefix.length, "%ux%u-f%u.raw", w, h, &format) != 3)
			continue;
		NSMutableData *data = [NSMutableData dataWithContentsOfFile:[@(dir) stringByAppendingPathComponent:name]];
		uint8_t *p = data.mutableBytes;
		for (size_t i = 0; format == 28 && i + 3 < data.length; i += 4) {
			uint8_t r = p[i];
			p[i] = p[i + 2], p[i + 2] = r;
		}
		return data;
	}
	return nil;
}

API_AVAILABLE(macos(26.0))
static void ui_errors(const uint8_t *out, const uint8_t *truth, const uint8_t *bare, uint32_t w, uint32_t h, double *ui,
                      double *all)
{
	long in = 0, bad = 0;
	for (size_t i = 0; i < (size_t)w * h; i++) {
		const uint8_t *a = out + i * 4, *b = truth + i * 4, *c = bare + i * 4;
		int mask = MAX(MAX(abs(b[0] - c[0]), abs(b[1] - c[1])), abs(b[2] - c[2])) > 2;
		if (!mask)
			continue;
		in++;
		bad += MAX(MAX(abs(a[0] - b[0]), abs(a[1] - b[1])), abs(a[2] - b[2])) > 2;
	}
	*ui = in ? 100.0 * bad / in : 0;
	*all = blocks(out, truth, w, h);
}

API_AVAILABLE(macos(26.0))
static int run_ui(const char *dir)
{
	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	id<MTLCommandQueue> queue = [device newCommandQueue];
	uint64_t first = UINT64_MAX, last = 0;
	for (int i = 0; i < nmotions; i++)
		first = MIN(first, motions[i].frame), last = MAX(last, motions[i].frame);
	FGPipeline *fg = nil;
	id<MTLTexture> copy = nil;
	uint8_t *out = NULL;
	double sum[4] = { 0 };
	int n = 0;
	printf("frame  captured ui%%  2x2%%   ui source ui%%  2x2%%   ui pixels%%\n");
	for (uint64_t k = first + 1; k + 1 <= last; k += 2) {
		uint32_t w, h;
		NSData *fa = load_ldr(dir, "final", k - 1, &w, &h), *ft = load_ldr(dir, "final", k, &w, &h);
		NSData *fb = load_ldr(dir, "final", k + 1, &w, &h);
		NSData *ha = load_ldr(dir, "hudless", k - 1, &w, &h), *ht = load_ldr(dir, "hudless", k, &w, &h);
		NSData *hb = load_ldr(dir, "hudless", k + 1, &w, &h);
		const Entry *m0 = find(motions, nmotions, k), *m1 = find(motions, nmotions, k + 1);
		if (!fa || !ft || !fb || !ha || !ht || !hb || !m0 || !m1)
			continue;
		if (fg == nil) {
			NSString *error = nil;
			fg = [[FGPipeline alloc] initWithDevice:device error:&error];
			copy = texture(device, MTLPixelFormatBGRA8Unorm, w, h, NULL, 0);
			out = malloc((size_t)w * h * 4);
		}
		NSData *d0 = load_motion(dir, *m0), *d1 = load_motion(dir, *m1);
		uint32_t mw = m1->width, mh = m1->height;
		const float *v0 = d0.bytes, *v1 = d1.bytes;
		_Float16 *chained = malloc((size_t)mw * mh * 4);
		for (uint32_t y = 0; y < mh; y++)
			for (uint32_t x = 0; x < mw; x++) {
				const float *s = v1 + (y * mw + x) * 2;
				float back[2];
				sample(v0, mw, mh, x + s[0], y + s[1], back);
				chained[(y * mw + x) * 2] = (_Float16)(s[0] + back[0]);
				chained[(y * mw + x) * 2 + 1] = (_Float16)(s[1] + back[1]);
			}
		id<MTLTexture> motion = texture(device, MTLPixelFormatRG16Float, mw, mh, chained, mw * 4);
		free(chained);
		double r[4];
		for (int mode = 0; mode < 2; mode++) {
			NSData *a = mode ? ha : fa, *b = mode ? hb : fb;
			fg.uiTexture = mode ? texture(device, MTLPixelFormatBGRA8Unorm, w, h, fb.bytes, w * 4) : nil;
			fg.uiComposited = mode == 1;
			[fg prepareWidth:w height:h format:MTLPixelFormatBGRA8Unorm error:NULL];
			generate(fg, queue, texture(device, MTLPixelFormatBGRA8Unorm, w, h, a.bytes, w * 4),
			         texture(device, MTLPixelFormatBGRA8Unorm, w, h, b.bytes, w * 4), motion, copy, ft.bytes, out);
			ui_errors(out, ft.bytes, ht.bytes, w, h, &r[2 * mode], &r[2 * mode + 1]);
		}
		long in = 0;
		for (size_t i = 0; i < (size_t)w * h; i++) {
			const uint8_t *b = (const uint8_t *)ft.bytes + i * 4, *c = (const uint8_t *)ht.bytes + i * 4;
			in += MAX(MAX(abs(b[0] - c[0]), abs(b[1] - c[1])), abs(b[2] - c[2])) > 2;
		}
		printf("%5llu  %12.2f  %5.2f   %12.2f  %5.2f   %9.2f\n", (unsigned long long)k, r[0], r[1], r[2], r[3],
		       100.0 * in / ((double)w * h));
		for (int i = 0; i < 4; i++)
			sum[i] += r[i];
		n++;
	}
	if (n == 0) {
		fprintf(stderr, "score: no frames with and without UI in %s\n", dir);
		return 1;
	}
	printf("mean   %12.2f  %5.2f   %12.2f  %5.2f   (%d pairs)\n", sum[0] / n, sum[1] / n, sum[2] / n, sum[3] / n, n);
	free(out);
	return 0;
}

static int scan(const char *dir)
{
	NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(dir) error:nil];
	for (NSString *name in names) {
		Entry e;
		if (sscanf(name.UTF8String, "color-%llu-%ux%u-f%u.raw", &e.frame, &e.width, &e.height, &e.format) == 4 &&
		    ncolors < 4096)
			colors[ncolors++] = e;
		else if (sscanf(name.UTF8String, "motion-%llu-%ux%u.f32", &e.frame, &e.width, &e.height) == 3 && nmotions < 4096)
			motions[nmotions++] = e;
	}
	return ncolors;
}

API_AVAILABLE(macos(26.0))
static int run(const char *dir)
{
	if (scan(dir) < 3) {
		fprintf(stderr, "score: fewer than 3 colour frames in %s\n", dir);
		return 1;
	}
	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	id<MTLCommandQueue> queue = [device newCommandQueue];
	NSString *error = nil;
	FGPipeline *fg = [[FGPipeline alloc] initWithDevice:device error:&error];
	uint32_t W = colors[0].width, H = colors[0].height;
	if (fg == nil || ![fg prepareWidth:W height:H format:MTLPixelFormatBGRA8Unorm error:&error]) {
		fprintf(stderr, "score: %s\n", error.UTF8String);
		return 1;
	}
	id<MTLTexture> copy = texture(device, MTLPixelFormatBGRA8Unorm, W, H, NULL, 0);
	uint8_t *out = malloc((size_t)W * H * 4);
	uint64_t first = UINT64_MAX, last = 0;
	for (int i = 0; i < ncolors; i++)
		first = MIN(first, colors[i].frame), last = MAX(last, colors[i].frame);
	double sum[4] = { 0 }, moved = 0;
	int n = 0, refusals = 0;
	printf("frame  repeat%%  estimate%%  game%%  late%%  game motion px\n");
	for (uint64_t k = first + 1; k + 1 <= last; k += 2) {
		const Entry *a = find(colors, ncolors, k - 1), *t = find(colors, ncolors, k), *b = find(colors, ncolors, k + 1);
		long shift = getenv("SCORE_SHIFT") ? atol(getenv("SCORE_SHIFT")) : 0;
		const Entry *m0 = find(motions, nmotions, k + shift), *m1 = find(motions, nmotions, k + 1 + shift);
		const Entry *mm = find(motions, nmotions, k - 1);
		if (!a || !t || !b || !m0 || !m1)
			continue;
		NSData *pa = load_color(dir, *a), *pt = load_color(dir, *t), *pb = load_color(dir, *b);
		NSData *d0 = load_motion(dir, *m0), *d1 = load_motion(dir, *m1);
		uint32_t w = m1->width, h = m1->height;
		const float *v0 = d0.bytes, *v1 = d1.bytes;
		BOOL refuse = refused(v0, w, h) || refused(v1, w, h);
		refusals += refuse;
		_Float16 *chained = malloc((size_t)w * h * 4);
		double length = 0;
		for (uint32_t y = 0; y < h; y++)
			for (uint32_t x = 0; x < w; x++) {
				const float *s = v1 + (y * w + x) * 2;
				float back[2];
				sample(v0, w, h, x + s[0], y + s[1], back);
				float mx = s[0] + back[0], my = s[1] + back[1];
				chained[(y * w + x) * 2] = (_Float16)mx;
				chained[(y * w + x) * 2 + 1] = (_Float16)my;
				length += sqrtf(mx * mx + my * my);
			}
		id<MTLTexture> motion = texture(device, MTLPixelFormatRG16Float, w, h, chained, w * 4);
		id<MTLTexture> late = nil;
		NSData *dm = mm != NULL ? load_motion(dir, *mm) : nil;
		if (dm != nil && !refused(dm.bytes, w, h)) {
			const float *vm = dm.bytes;
			for (uint32_t y = 0; y < h; y++)
				for (uint32_t x = 0; x < w; x++) {
					const float *s = v0 + (y * w + x) * 2;
					float back[2];
					sample(vm, w, h, x + s[0], y + s[1], back);
					chained[(y * w + x) * 2] = (_Float16)(s[0] + back[0]);
					chained[(y * w + x) * 2 + 1] = (_Float16)(s[1] + back[1]);
				}
			late = texture(device, MTLPixelFormatRG16Float, w, h, chained, w * 4);
		}
		free(chained);
		id<MTLTexture> prev = texture(device, MTLPixelFormatBGRA8Unorm, W, H, pa.bytes, W * 4);
		id<MTLTexture> cur = texture(device, MTLPixelFormatBGRA8Unorm, W, H, pb.bytes, W * 4);
		double r = blocks(pa.bytes, pt.bytes, W, H);
		double e = generate(fg, queue, prev, cur, nil, copy, pt.bytes, out);
		double g = refuse ? e : generate(fg, queue, prev, cur, motion, copy, pt.bytes, out);
		double l = late != nil ? generate(fg, queue, prev, cur, late, copy, pt.bytes, out) : e;
		if (getenv("SCORE_KEEP") && n == 4) {
			NSString *keep = [NSString stringWithFormat:@"%s/ours-game-%llu-%ux%u.bgra", dir, (unsigned long long)k, W, H];
			[[NSData dataWithBytes:out length:(size_t)W * H * 4] writeToFile:keep atomically:NO];
			keep = [NSString stringWithFormat:@"%s/truth-%llu-%ux%u.bgra", dir, (unsigned long long)k, W, H];
			[pt writeToFile:keep atomically:NO];
		}
		length /= (double)w * h;
		printf("%5llu  %7.2f  %9.2f  %5.2f  %5.2f  %6.2f%s\n", (unsigned long long)k, r, e, g, l, length,
		       refuse ? "  refused" : "");
		sum[0] += r, sum[1] += e, sum[2] += g, sum[3] += l, moved += length;
		n++;
	}
	if (n == 0)
		return 1;
	printf("mean   %7.2f  %9.2f  %5.2f  %5.2f  %6.2f   (%d pairs, %d refused, %ux%u, motion %ux%u)\n", sum[0] / n,
	       sum[1] / n, sum[2] / n, sum[3] / n, moved / n, n, refusals, W, H, motions[0].width, motions[0].height);
	free(out);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: score <dump dir>\n");
		return 2;
	}
	if (@available(macOS 26.0, *)) {
		if (getenv("SCORE_UI")) {
			scan(argv[1]);
			return run_ui(argv[1]);
		}
		return run(argv[1]);
	}
	return 1;
}
