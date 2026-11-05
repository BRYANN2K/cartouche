// The HUD offscreen: the variables it reads, the panel's pixels in each corner, level and format,
// nothing changed outside it, the morph between levels, the app's control block, the waiting
// state, its GPU cost at 2560x1440, the shared metrics block, and the generated frame left the
// same when the HUD is drawn on the real frames.
// Usage: overlay [folder for the panel images] [folder for the PNG renders]

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <unistd.h>

#import "../fg_control_shm.h"
#import "../fg_metrics.h"
#import "../fg_overlay.h"
#import "../fg_pipeline.h"

static int fails;

static void check(const char *what, int good, const char *detail)
{
	printf("  %s  %s%s%s\n", good ? "ok   " : "FAIL ", what, detail[0] ? ": " : "", detail);
	fails += !good;
}

// Set for the doc renders: two flat bands, the mockup's dusk
static BOOL dusk;

// The stand-in game's checks, 64 pixels a side: orange and blue
static void background(int x, int y, uint8_t rgb[3])
{
	if (dusk) {
		const uint8_t top[3] = { 0x4a, 0x3a, 0x63 }, low[3] = { 0xc0, 0x60, 0x6a };
		memcpy(rgb, y < 360 ? top : low, 3);
		return;
	}
	int check = ((x / 64) + (y / 64)) & 1;
	rgb[0] = check ? 255 : 0;
	rgb[1] = check ? 178 : 77;
	rgb[2] = check ? 0 : 255;
}

static id<MTLTexture> target(id<MTLDevice> device, MTLPixelFormat format, int width, int height, MTLStorageMode storage)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height
	                                                                         mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	d.storageMode = storage;
	return [device newTextureWithDescriptor:d];
}

static void fill(id<MTLTexture> texture)
{
	int width = (int)texture.width, height = (int)texture.height;
	uint8_t *pixels = malloc((size_t)width * height * 4);
	for (int y = 0; y < height; y++)
		for (int x = 0; x < width; x++) {
			uint8_t rgb[3], *p = pixels + ((size_t)y * width + x) * 4;
			background(x, y, rgb);
			BOOL bgra = texture.pixelFormat == MTLPixelFormatBGRA8Unorm || texture.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB;
			p[0] = bgra ? rgb[2] : rgb[0];
			p[1] = rgb[1];
			p[2] = bgra ? rgb[0] : rgb[2];
			p[3] = 255;
		}
	[texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];
	free(pixels);
}

// Live-looking numbers through the metrics core, as the present path feeds it
static void feed(BOOL problems)
{
	for (int i = 0; i < 300; i++) {
		FGMetricsShown(8.4 + 0.3 * sin(i));
		FGMetricsReal(16.9 + (i % 97 == 0 ? 3 : 0));
	}
	if (problems)
		FGMetricsShown(40);
	FGMetricsSecond second = {
		.presentedFps = 118, .realFps = 59, .frameMs = 8.4, .framegenGpuMs = 2.1, .latencyMs = 14.3, .latencyMaxMs = 19.2,
		.refreshMs = 8.33, .generated = 1200, .dropped = problems ? 12 : 0, .droppedSecond = problems ? 3 : 0,
		.framegen = FG_FRAMEGEN_ON, .factor = 2, .ane = 1,
	};
	FGMetricsUpscale(FG_UPSCALE_TEMPORAL, 1280, 720, 2560, 1440);
	FGMetricsPresentGPU(0.4);
	FGMetricsSecondDone(&second);
}

static float half_to_float(uint16_t h)
{
	uint32_t sign = (uint32_t)(h & 0x8000) << 16, exponent = (h >> 10) & 0x1f, mantissa = h & 0x3ff;
	uint32_t bits = exponent == 0 ? sign : exponent == 31 ? sign | 0x7f800000 | (mantissa << 13)
	                                                     : sign | ((exponent + 112) << 23) | (mantissa << 13);
	float f;
	memcpy(&f, &bits, sizeof(f));
	return f;
}

typedef struct {
	uint8_t *rgb; // 8 bits a channel, top row first
	int width, height;
	CGRect panel, bounds;
} Image;

static void read_back(id<MTLTexture> texture, Image *image)
{
	int width = (int)texture.width, height = (int)texture.height;
	image->width = width;
	image->height = height;
	image->rgb = malloc((size_t)width * height * 3);
	MTLPixelFormat format = texture.pixelFormat;
	if (format == MTLPixelFormatRGBA16Float) {
		uint16_t *half = malloc((size_t)width * height * 8);
		[texture getBytes:half bytesPerRow:width * 8 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
		for (size_t i = 0; i < (size_t)width * height; i++)
			for (int c = 0; c < 3; c++) {
				float v = fmaxf(0, fminf(1, half_to_float(half[i * 4 + c])));
				image->rgb[i * 3 + c] = (uint8_t)lroundf((v <= 0.0031308f ? v * 12.92f : 1.055f * powf(v, 1 / 2.4f) - 0.055f) * 255);
			}
		free(half);
		return;
	}
	uint32_t *pixels = malloc((size_t)width * height * 4);
	[texture getBytes:pixels bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
	for (size_t i = 0; i < (size_t)width * height; i++) {
		uint32_t p = pixels[i];
		uint8_t *o = image->rgb + i * 3;
		if (format == MTLPixelFormatRGB10A2Unorm) {
			o[0] = (uint8_t)(((p >> 0) & 1023) * 255 / 1023);
			o[1] = (uint8_t)(((p >> 10) & 1023) * 255 / 1023);
			o[2] = (uint8_t)(((p >> 20) & 1023) * 255 / 1023);
		} else if (format == MTLPixelFormatBGRA8Unorm || format == MTLPixelFormatBGRA8Unorm_sRGB) {
			o[0] = (uint8_t)(p >> 16);
			o[1] = (uint8_t)(p >> 8);
			o[2] = (uint8_t)p;
		} else {
			o[0] = (uint8_t)p;
			o[1] = (uint8_t)(p >> 8);
			o[2] = (uint8_t)(p >> 16);
		}
	}
	free(pixels);
}

static void write_ppm(const Image *image, CGRect crop, const char *path)
{
	FILE *f = fopen(path, "wb");
	if (f == NULL)
		return;
	int x0 = (int)crop.origin.x, y0 = (int)crop.origin.y, w = (int)crop.size.width, h = (int)crop.size.height;
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	for (int y = y0; y < y0 + h; y++)
		fwrite(image->rgb + ((size_t)y * image->width + x0) * 3, 3, (size_t)w, f);
	fclose(f);
}

typedef struct {
	int white, green, red, orange, changedOutside;
	uint8_t pad[3];
} Census;

static BOOL inside(CGRect r, int x, int y)
{
	return x >= r.origin.x && y >= r.origin.y && x < CGRectGetMaxX(r) && y < CGRectGetMaxY(r);
}

// Counts inside panel; outside bounds nothing may change
static Census census_in(const Image *image, CGRect panel, CGRect bounds, double scale)
{
	Census c = { 0 };
	for (int y = 0; y < image->height; y++)
		for (int x = 0; x < image->width; x++) {
			const uint8_t *p = image->rgb + ((size_t)y * image->width + x) * 3;
			if (!inside(bounds, x, y)) {
				uint8_t want[3];
				background(x, y, want);
				c.changedOutside += abs(p[0] - want[0]) > 1 || abs(p[1] - want[1]) > 1 || abs(p[2] - want[2]) > 1;
				continue;
			}
			c.orange += p[0] > 235 && p[1] > 148 && p[1] < 170 && p[2] < 40 && p[1] * 3 < p[0] * 2; // the warning dot, not the checks' orange
			if (!inside(panel, x, y))
				continue;
			c.white += p[0] > 225 && p[1] > 225 && p[2] > 225;
			c.green += p[0] < 110 && p[1] > 150 && p[2] < 150 && p[1] > p[0] + 60;
			c.red += p[0] > 225 && p[1] > 55 && p[1] < 100 && p[2] > 70 && p[2] < 115;
		}
	int px = (int)(panel.origin.x + round(4 * scale)), py = (int)CGRectGetMidY(panel);
	memcpy(c.pad, image->rgb + ((size_t)py * image->width + px) * 3, 3);
	return c;
}

static Census census(const Image *image, CGRect panel, double scale)
{
	return census_in(image, panel, image->bounds, scale);
}

static FGOverlay *overlay_at(id<MTLDevice> device, FGOverlayLevel level, FGOverlayCorner corner)
{
	NSString *error = nil;
	FGOverlay *overlay = [[FGOverlay alloc] initWithDevice:device level:level corner:corner error:&error];
	if (overlay == nil)
		check("overlay made", 0, error.UTF8String);
	return overlay;
}

static Image draw(id<MTLDevice> device, id<MTLCommandQueue> queue, FGOverlay *overlay, MTLPixelFormat format, int width,
                  int height, double scale)
{
	id<MTLTexture> texture;
	if (format == MTLPixelFormatRGBA16Float || format == MTLPixelFormatRGB10A2Unorm) {
		// Filled through an 8-bit texture the GPU converts: linear for float, as is for 10 bits
		MTLPixelFormat eight = format == MTLPixelFormatRGBA16Float ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
		id<MTLTexture> source = target(device, eight, width, height, MTLStorageModeShared);
		fill(source);
		id<MTLLibrary> library = [device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
		                                                       "kernel void copy(texture2d<float> in [[texture(0)]],\n"
		                                                       "  texture2d<float, access::write> out [[texture(1)]], uint2 at [[thread_position_in_grid]])\n"
		                                                       "{ out.write(in.read(at), at); }"
		                                                options:nil
		                                                  error:nil];
		id<MTLComputePipelineState> copy = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"copy"] error:nil];
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
		d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		d.storageMode = MTLStorageModeShared;
		texture = [device newTextureWithDescriptor:d];
		id<MTLCommandBuffer> b = [queue commandBuffer];
		id<MTLComputeCommandEncoder> e = [b computeCommandEncoder];
		[e setComputePipelineState:copy];
		[e setTexture:source atIndex:0];
		[e setTexture:texture atIndex:1];
		[e dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[e endEncoding];
		[b commit];
		[b waitUntilCompleted];
	} else {
		texture = target(device, format, width, height, MTLStorageModeShared);
		fill(texture);
	}
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	[overlay encodeOnto:texture scale:scale commandBuffer:buffer];
	[buffer commit];
	[buffer waitUntilCompleted];
	Image image;
	read_back(texture, &image);
	image.panel = [overlay panelForWidth:width height:height scale:scale];
	image.bounds = [overlay boundsForWidth:width height:height scale:scale];
	return image;
}

static void parse_checks(void)
{
	check("CARTOUCHE_OVERLAY_LANG and the block's language: fr and fr-CA French, en and others English",
	      FGOverlayFrench("fr") && FGOverlayFrench("fr-CA") && !FGOverlayFrench("en") && !FGOverlayFrench("it"), "");
	FGOverlayLevel level;
	FGOverlayCorner corner;
	BOOL ok = FGOverlayParseLevel(NULL, &level) && level == FGOverlayOff;
	ok &= FGOverlayParseLevel("off", &level) && level == FGOverlayOff;
	ok &= FGOverlayParseLevel("mini", &level) && level == FGOverlayMini;
	ok &= FGOverlayParseLevel("std", &level) && level == FGOverlayStandard;
	ok &= FGOverlayParseLevel("full", &level) && level == FGOverlayFull;
	ok &= !FGOverlayParseLevel("loud", &level);
	check("CARTOUCHE_OVERLAY: off by default, off|mini|std|full, unknown refused", ok, "");
	ok = FGOverlayParseCorner(NULL, &corner) && corner == FGOverlayTopRight;
	ok &= FGOverlayParseCorner("tl", &corner) && corner == FGOverlayTopLeft;
	ok &= FGOverlayParseCorner("tr", &corner) && corner == FGOverlayTopRight;
	ok &= FGOverlayParseCorner("bl", &corner) && corner == FGOverlayBottomLeft;
	ok &= FGOverlayParseCorner("br", &corner) && corner == FGOverlayBottomRight;
	ok &= !FGOverlayParseCorner("middle", &corner);
	check("CARTOUCHE_OVERLAY_POS: tr by default, tl|tr|bl|br, unknown refused", ok, "");
}

// Panel pixel near its left edge, half way down: the fill over the background, no text
static BOOL dark_pad(const uint8_t pad[3], int x, int y, BOOL linear)
{
	uint8_t back[3];
	background(x, y, back);
	if (!linear) {
		for (int i = 0; i < 3; i++)
			if (abs(pad[i] - (int)lround((i == 2 ? 26 : 22) * 0.84 + back[i] * 0.16)) > 3)
				return NO;
		return YES;
	}
	for (int i = 0; i < 3; i++)
		if (pad[i] > fmax(70, back[i] * 0.5))
			return NO;
	return YES;
}

static void pixel_checks(id<MTLDevice> device, id<MTLCommandQueue> queue, const char *folder)
{
	char detail[256], path[1024];
	const int width = 2560, height = 1440;
	const double scale = 2;
	const char *names[] = { "off", "mini", "std", "full" };
	CGRect panels[4] = { CGRectZero };
	for (int level = FGOverlayMini; level <= FGOverlayFull; level++) {
		FGOverlay *overlay = overlay_at(device, level, FGOverlayTopRight);
		Image image = draw(device, queue, overlay, MTLPixelFormatBGRA8Unorm, width, height, scale);
		panels[level] = image.panel;
		Census c = census(&image, image.panel, scale);
		int px = (int)(image.panel.origin.x + round(4 * scale)), py = (int)CGRectGetMidY(image.panel);
		snprintf(detail, sizeof(detail), "panel %.0fx%.0f at %.0f,%.0f, pad %d,%d,%d", image.panel.size.width,
		         image.panel.size.height, image.panel.origin.x, image.panel.origin.y, c.pad[0], c.pad[1], c.pad[2]);
		printf("== %s ==\n", names[level]);
		check("the panel is the dark glass fill at 84 %", dark_pad(c.pad, px, py, NO), detail);
		snprintf(detail, sizeof(detail), "%d white, %d green pixels", c.white, c.green);
		check("white text, and the green frame-time line from Standard up",
		      c.white > (level == FGOverlayMini ? 60 : 150) && (level == FGOverlayMini ? c.green == 0 : c.green > 40), detail);
		snprintf(detail, sizeof(detail), "%d red pixels", c.red);
		check("no red", c.red == 0, detail);
		snprintf(detail, sizeof(detail), "%d pixels changed", c.changedOutside);
		check("nothing changes outside the panel and its shadow", c.changedOutside == 0, detail);
		// The rounded corner leaves the very corner pixel to the game
		const uint8_t *corner = image.rgb + ((size_t)image.panel.origin.y * width + (size_t)image.panel.origin.x) * 3;
		uint8_t at[3];
		background((int)image.panel.origin.x, (int)image.panel.origin.y, at);
		snprintf(detail, sizeof(detail), "%d,%d,%d over %d,%d,%d", corner[0], corner[1], corner[2], at[0], at[1], at[2]);
		check("rounded corners", abs(corner[0] - at[0]) + abs(corner[1] - at[1]) + abs(corner[2] - at[2]) < 40, detail);
		BOOL placed = fabs(CGRectGetMaxX(image.panel) - (width - 24 * scale)) < 1 && fabs(image.panel.origin.y - 16 * scale) < 1;
		check("top right, 24 points from the side, 16 from the top", placed, "");
		BOOL sized = level == FGOverlayMini ? fabs(image.panel.size.height - 44 * scale) < 1
		                                    : fabs(image.panel.size.width - 236 * scale) < 1;
		snprintf(detail, sizeof(detail), "%.0fx%.0f", image.panel.size.width, image.panel.size.height);
		check(level == FGOverlayMini ? "Mini is a 44 point capsule" : "236 points wide", sized, detail);
		if (folder != NULL) {
			snprintf(path, sizeof(path), "%s/overlay-%s.ppm", folder, names[level]);
			CGRect crop = CGRectInset(image.panel, -24, -24);
			write_ppm(&image, crop, path);
		}
		free(image.rgb);
	}
	check("mini < std < full", panels[1].size.height < panels[2].size.height && panels[2].size.height < panels[3].size.height &&
	                               panels[1].size.width < panels[2].size.width, "");
	snprintf(detail, sizeof(detail), "std %.0f, full %.0f pixels high", panels[2].size.height, panels[3].size.height);
	check("Standard about 179 points high, Complet about 273", fabs(panels[2].size.height / scale - 178.8) < 2 &&
	                                                            fabs(panels[3].size.height / scale - 272.6) < 2, detail);

	printf("== corners, scale 1 ==\n");
	const char *corners[] = { "tl", "tr", "bl", "br" };
	for (int corner = 0; corner < 4; corner++) {
		FGOverlay *overlay = overlay_at(device, FGOverlayStandard, corner);
		Image image = draw(device, queue, overlay, MTLPixelFormatBGRA8Unorm, 1280, 720, 1);
		CGRect p = image.panel;
		BOOL left = corner == 0 || corner == 2, top = corner < 2;
		BOOL placed = fabs((left ? p.origin.x : 1280 - CGRectGetMaxX(p)) - 24) < 1 &&
		              fabs((top ? p.origin.y - 16 : 720 - CGRectGetMaxY(p) - 24)) < 1;
		Census c = census(&image, p, 1);
		snprintf(detail, sizeof(detail), "%s: panel %.0fx%.0f at %.0f,%.0f, %d white pixels, %d changed outside", corners[corner],
		         p.size.width, p.size.height, p.origin.x, p.origin.y, c.white, c.changedOutside);
		check("in its corner, half the size at 1 pixel per point, text drawn, outside untouched",
		      placed && c.white > 40 && c.changedOutside == 0 && fabs(p.size.width * 2 - panels[2].size.width) <= 2, detail);
		free(image.rgb);
	}

	printf("== formats ==\n");
	const MTLPixelFormat formats[] = { MTLPixelFormatBGRA8Unorm_sRGB, MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float,
		                               MTLPixelFormatRGB10A2Unorm };
	const char *formatNames[] = { "BGRA8 sRGB", "RGBA8", "RGBA16Float (EDR)", "RGB10A2" };
	for (int i = 0; i < 4; i++) {
		FGOverlay *overlay = overlay_at(device, FGOverlayStandard, FGOverlayTopLeft);
		Image image = draw(device, queue, overlay, formats[i], 1280, 720, 1);
		Census c = census(&image, image.panel, 1);
		int px = (int)(image.panel.origin.x + 4), py = (int)CGRectGetMidY(image.panel);
		snprintf(detail, sizeof(detail), "%s: pad %d,%d,%d, %d white, %d green, %d changed outside", formatNames[i], c.pad[0],
		         c.pad[1], c.pad[2], c.white, c.green, c.changedOutside);
		// sRGB and float targets blend in linear light: the same fill lets more of the background through
		BOOL linear = i == 0 || i == 2;
		check("same panel in each format", dark_pad(c.pad, px, py, linear) && c.white > 40 && c.green > 10 && c.changedOutside == 0,
		      detail);
		free(image.rgb);
	}

	printf("== size ==\n");
	FGOverlay *large = overlay_at(device, FGOverlayStandard, FGOverlayTopLeft);
	large.sizePercent = 150;
	Image big = draw(device, queue, large, MTLPixelFormatBGRA8Unorm, width, height, scale);
	snprintf(detail, sizeof(detail), "%.0fx%.0f", big.panel.size.width, big.panel.size.height);
	check("150 % makes the panel 1.5 times larger", fabs(big.panel.size.width - panels[2].size.width * 1.5) <= 2 &&
	                                                    fabs(big.panel.size.height - panels[2].size.height * 1.5) <= 3, detail);
	free(big.rgb);

	printf("== problems ==\n");
	FGOverlay *calm = overlay_at(device, FGOverlayFull, FGOverlayTopRight);
	Image before = draw(device, queue, calm, MTLPixelFormatBGRA8Unorm, width, height, scale);
	feed(YES);
	FGOverlay *overlay = overlay_at(device, FGOverlayFull, FGOverlayTopRight);
	Image image = draw(device, queue, overlay, MTLPixelFormatBGRA8Unorm, width, height, scale);
	// The graph's top band: 34 ms and slower reach it, the usual 8 ms frames stay low
	CGRect band = CGRectMake(image.panel.origin.x + 16 * scale, image.panel.origin.y + 50 * scale, 204 * scale, 4 * scale);
	Census c = census_in(&image, band, image.bounds, scale), c0 = census_in(&before, band, before.bounds, scale);
	snprintf(detail, sizeof(detail), "%d green pixels at the top of the graph, %d without the spike", c.green, c0.green);
	check("a spike shows at the top of the graph", c.green > 3 && c0.green == 0, detail);
	if (folder != NULL) {
		snprintf(path, sizeof(path), "%s/overlay-full-problems.ppm", folder);
		write_ppm(&image, CGRectInset(image.panel, -24, -24), path);
	}
	free(image.rgb);
	free(before.rgb);
	feed(NO);
}

// One frame at clock t on a fresh checked target; the image's panel is the one drawn
static Image frame_at(id<MTLDevice> device, id<MTLCommandQueue> queue, FGOverlay *overlay, double t, int width, int height,
                      double scale)
{
	overlay.testTime = t;
	return draw(device, queue, overlay, MTLPixelFormatBGRA8Unorm, width, height, scale);
}

static void write_png(const Image *image, CGRect crop, const char *path)
{
	CGRect r = CGRectIntersection(CGRectIntegral(crop), CGRectMake(0, 0, image->width, image->height));
	int w = (int)r.size.width, h = (int)r.size.height;
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
	                                                           samplesPerPixel:3 hasAlpha:NO isPlanar:NO
	                                                            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 3
	                                                              bitsPerPixel:24];
	for (int y = 0; y < h; y++)
		memcpy(rep.bitmapData + (size_t)y * w * 3, image->rgb + ((size_t)(y + r.origin.y) * image->width + (size_t)r.origin.x) * 3,
		       (size_t)w * 3);
	[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(path) atomically:YES];
}

// Before any measured second: the waiting text, no graph
static void stale_checks(id<MTLDevice> device, id<MTLCommandQueue> queue)
{
	printf("== waiting for the game ==\n");
	char detail[160];
	FGOverlay *standard = overlay_at(device, FGOverlayStandard, FGOverlayTopLeft);
	Image image = draw(device, queue, standard, MTLPixelFormatBGRA8Unorm, 2560, 1440, 2);
	int text = 0;
	for (int y = (int)image.panel.origin.y; y < (int)CGRectGetMaxY(image.panel); y++)
		for (int x = (int)image.panel.origin.x; x < (int)CGRectGetMaxX(image.panel); x++) {
			const uint8_t *p = image.rgb + ((size_t)y * image.width + x) * 3;
			text += p[0] > 120 && p[1] > 120 && p[2] > 120;
		}
	Census c = census(&image, image.panel, 2);
	snprintf(detail, sizeof(detail), "panel %.0f points high, %d grey text pixels, %d green", image.panel.size.height / 2, text,
	         c.green);
	check("Standard shows a dash and the waiting text, no graph", fabs(image.panel.size.height / 2 - 52) < 1 && text > 100 &&
	                                                                  c.green == 0, detail);
	free(image.rgb);
	FGOverlay *mini = overlay_at(device, FGOverlayMini, FGOverlayTopLeft);
	image = draw(device, queue, mini, MTLPixelFormatBGRA8Unorm, 2560, 1440, 2);
	snprintf(detail, sizeof(detail), "%.0fx%.0f points", image.panel.size.width / 2, image.panel.size.height / 2);
	check("Mini shows the waiting text in its capsule", image.panel.size.height == 88 && image.panel.size.width > 120 * 2, detail);
	free(image.rgb);
}

static void morph_checks(id<MTLDevice> device, id<MTLCommandQueue> queue, const char *pngs)
{
	printf("== morph ==\n");
	char detail[200], path[1024];
	dusk = pngs != NULL;
	const int width = 1600, height = 900;
	FGOverlay *overlay = overlay_at(device, FGOverlayStandard, FGOverlayTopLeft);
	Image image = frame_at(device, queue, overlay, 100, width, height, 2);
	free(image.rgb);
	image = frame_at(device, queue, overlay, 101, width, height, 2);
	CGRect start = image.panel;
	free(image.rgb);
	overlay.level = FGOverlayMini;
	const double at[] = { 0, 0.04, 0.08, 0.12, 0.18, 0.26 };
	CGRect mid = CGRectZero;
	for (int i = 0; i < 6; i++) {
		image = frame_at(device, queue, overlay, 102 + at[i], width, height, 2);
		if (i == 2)
			mid = image.panel;
		if (pngs != NULL) {
			snprintf(path, sizeof(path), "%s/hud-morph-%d.png", pngs, i + 1);
			write_png(&image, CGRectMake(0, 0, 600, 640), path);
		}
		free(image.rgb);
	}
	image = frame_at(device, queue, overlay, 103, width, height, 2);
	CGRect end = image.panel;
	free(image.rgb);
	snprintf(detail, sizeof(detail), "start %.0fx%.0f, 80 ms %.0fx%.0f, end %.0fx%.0f", start.size.width, start.size.height,
	         mid.size.width, mid.size.height, end.size.width, end.size.height);
	check("Standard to Mini: mid-flight size between start and end",
	      mid.size.width < start.size.width && mid.size.width > end.size.width && mid.size.height < start.size.height &&
	          mid.size.height > end.size.height,
	      detail);
	check("and it settles on the Mini capsule", end.size.height == 88, detail);
	// Retargeted mid-flight: back to Standard without a jump
	overlay.level = FGOverlayStandard;
	image = frame_at(device, queue, overlay, 103.04, width, height, 2);
	CGRect back = image.panel;
	free(image.rgb);
	overlay.level = FGOverlayFull;
	image = frame_at(device, queue, overlay, 103.08, width, height, 2);
	CGRect turn = image.panel;
	free(image.rgb);
	image = frame_at(device, queue, overlay, 104, width, height, 2);
	CGRect full = image.panel;
	free(image.rgb);
	snprintf(detail, sizeof(detail), "40 ms %.0fx%.0f, retargeted %.0fx%.0f, end %.0fx%.0f", back.size.width, back.size.height,
	         turn.size.width, turn.size.height, full.size.width, full.size.height);
	check("interrupted, it keeps going and settles on Complet", back.size.height > end.size.height &&
	                                                                 back.size.height < full.size.height &&
	                                                                 fabs(full.size.height - 272.6 * 2) < 3, detail);
	// Hidden, then shown again with a fade
	overlay.level = FGOverlayOff;
	image = frame_at(device, queue, overlay, 105, width, height, 2);
	free(image.rgb);
	image = frame_at(device, queue, overlay, 106, width, height, 2);
	Census gone = census(&image, CGRectZero, 2);
	free(image.rgb);
	check("hidden: nothing drawn", gone.changedOutside == 0, "");
	// Corner change springs from the old place
	overlay.level = FGOverlayStandard;
	image = frame_at(device, queue, overlay, 107, width, height, 2);
	free(image.rgb);
	image = frame_at(device, queue, overlay, 108, width, height, 2);
	free(image.rgb);
	overlay.corner = FGOverlayTopRight;
	image = frame_at(device, queue, overlay, 108.06, width, height, 2);
	CGRect moving = image.panel;
	free(image.rgb);
	image = frame_at(device, queue, overlay, 109, width, height, 2);
	CGRect moved = image.panel;
	free(image.rgb);
	snprintf(detail, sizeof(detail), "60 ms x %.0f, end x %.0f", moving.origin.x, moved.origin.x);
	dusk = NO;
	check("corner change: on its way at 60 ms, in the new corner after", moving.origin.x > 48 && moving.origin.x < moved.origin.x &&
	                                                                        fabs(CGRectGetMaxX(moved) - (width - 48)) < 1, detail);
}

static FGControlBlock *control_block(void)
{
	char name[48];
	snprintf(name, sizeof(name), FG_CONTROL_NAME, getpid());
	shm_unlink(name);
	int fd = shm_open(name, O_CREAT | O_RDWR, 0600);
	if (fd < 0 || ftruncate(fd, FG_CONTROL_SIZE) != 0)
		return NULL;
	FGControlBlock *block = mmap(NULL, FG_CONTROL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	return block == MAP_FAILED ? NULL : block;
}

static void control_write(FGControlBlock *block, void (^change)(FGControlBlock *))
{
	__atomic_fetch_add(&block->sequence, 1, __ATOMIC_ACQ_REL);
	change(block);
	__atomic_fetch_add(&block->sequence, 1, __ATOMIC_ACQ_REL);
}

static void control_checks(id<MTLDevice> device, id<MTLCommandQueue> queue)
{
	printf("== control block ==\n");
	char detail[200], name[48];
	FGControlBlock *block = control_block();
	if (block == NULL) {
		check("control block made", 0, strerror(errno));
		return;
	}
	control_write(block, ^(FGControlBlock *b) {
		memset((char *)b + offsetof(FGControlBlock, reserved0), 0, sizeof(*b) - offsetof(FGControlBlock, reserved0));
		b->magic = FG_CONTROL_MAGIC;
		b->version = FG_CONTROL_VERSION;
		b->size = FG_CONTROL_SIZE;
		b->pid = getpid();
		b->hud_level = FG_HUD_FULL;
		b->hud_corner = FG_CORNER_BL;
		b->hud_scale = 100;
		b->battery_percent = 82;
		b->gpu_watts = 14.4f;
		snprintf(b->warning, sizeof(b->warning), "Google Chrome utilise 30\u202F%% du CPU");
		snprintf(b->hotkey, sizeof(b->hotkey), "⌥C");
	});
	const int width = 1600, height = 900;
	FGOverlay *overlay = overlay_at(device, FGOverlayMini, FGOverlayTopRight);
	Image image = frame_at(device, queue, overlay, 200, width, height, 2);
	free(image.rgb);
	// The capsule fades in over 240 ms
	image = frame_at(device, queue, overlay, 200.3, width, height, 2);
	Census c = census(&image, image.panel, 2);
	snprintf(detail, sizeof(detail), "controlled %d, panel %.0fx%.0f at %.0f,%.0f, %d orange, bounds %.0f high", overlay.controlled,
	         image.panel.size.width, image.panel.size.height, image.panel.origin.x, image.panel.origin.y, c.orange,
	         image.bounds.size.height);
	check("the block sets Complet, bottom left, and shows the warning capsule above the HUD",
	      overlay.controlled && fabs(image.panel.size.height - 272.6 * 2) < 3 && image.panel.origin.x == 48 &&
	          fabs(CGRectGetMaxY(image.panel) - (height - 48)) < 1 && c.orange > 20 && image.bounds.origin.y < image.panel.origin.y - 60,
	      detail);
	free(image.rgb);
	control_write(block, ^(FGControlBlock *b) { b->menu_open = 1; });
	image = frame_at(device, queue, overlay, 201, width, height, 2);
	c = census(&image, image.panel, 2);
	snprintf(detail, sizeof(detail), "%d orange pixels", c.orange);
	check("menu open: the warning capsule hides", c.orange == 0 && c.changedOutside == 0, detail);
	free(image.rgb);
	control_write(block, ^(FGControlBlock *b) { b->hud_level = FG_HUD_MINI; b->reduce_motion = 1; b->hud_corner = FG_CORNER_TR; });
	image = frame_at(device, queue, overlay, 202, width, height, 2);
	CGRect cut = image.panel;
	free(image.rgb);
	snprintf(detail, sizeof(detail), "%.0fx%.0f at %.0f", cut.size.width, cut.size.height, cut.origin.x);
	check("Reduce Motion: size and corner change at once", cut.size.height == 88 && fabs(CGRectGetMaxX(cut) - (width - 48)) < 1,
	      detail);
	control_write(block, ^(FGControlBlock *b) { b->hud_level = FG_HUD_HIDDEN; });
	image = frame_at(device, queue, overlay, 203, width, height, 2);
	free(image.rgb);
	image = frame_at(device, queue, overlay, 204, width, height, 2);
	c = census(&image, CGRectZero, 2);
	check("hidden by the block: nothing drawn", c.changedOutside == 0 && CGRectIsEmpty(image.panel), "");
	free(image.rgb);
	// The game fills a notched screen: the HUD sits below the notch, 8 pt under the app's safe top
	control_write(block, ^(FGControlBlock *b) {
		b->hud_level = FG_HUD_MINI;
		b->hud_corner = FG_CORNER_TL;
		b->safe_top = 38;
		b->screen_height = height / 2.0f;
		snprintf(b->language, sizeof(b->language), "en");
	});
	image = frame_at(device, queue, overlay, 205, width, height, 2);
	free(image.rgb);
	image = frame_at(device, queue, overlay, 206, width, height, 2);
	snprintf(detail, sizeof(detail), "panel at %.0f,%.0f", image.panel.origin.x, image.panel.origin.y);
	check("safe top: below the notch on a target that fills the screen", fabs(image.panel.origin.y - (38 + 8) * 2) < 1, detail);
	free(image.rgb);
	control_write(block, ^(FGControlBlock *b) { b->screen_height = 1117; });
	image = frame_at(device, queue, overlay, 207, width, height, 2);
	snprintf(detail, sizeof(detail), "panel at %.0f,%.0f", image.panel.origin.x, image.panel.origin.y);
	check("safe top: a window smaller than the screen keeps its margin", fabs(image.panel.origin.y - 16 * 2) < 1, detail);
	free(image.rgb);
	snprintf(name, sizeof(name), FG_CONTROL_NAME, getpid());
	munmap(block, FG_CONTROL_SIZE);
	shm_unlink(name);
}

// The HUD over flat scenes like the mockup's, dusk and a clear sky, for the docs; offscreen only
static void doc_renders(id<MTLDevice> device, id<MTLCommandQueue> queue, const char *pngs)
{
	if (pngs == NULL)
		return;
	const uint8_t scenes[2][2][3] = { { { 0x4a, 0x3a, 0x63 }, { 0xc0, 0x60, 0x6a } }, { { 0x7c, 0xc0, 0xef }, { 0xea, 0xf6, 0xfc } } };
	const char *sceneNames[] = { "dusk", "sky" };
	const char *levelNames[] = { "", "mini", "standard", "complet" };
	char path[1024];
	FGControlBlock *block = control_block();
	if (block != NULL)
		control_write(block, ^(FGControlBlock *b) {
			memset((char *)b + offsetof(FGControlBlock, reserved0), 0, sizeof(*b) - offsetof(FGControlBlock, reserved0));
			b->magic = FG_CONTROL_MAGIC;
			b->version = FG_CONTROL_VERSION;
			b->size = FG_CONTROL_SIZE;
			b->pid = getpid();
			b->hud_level = FG_HUD_FULL;
			b->hud_corner = FG_CORNER_TL;
			b->hud_scale = 100;
			b->battery_percent = 82;
			b->gpu_watts = 14.4f;
		});
	for (int scene = 0; scene < 2; scene++)
		for (int level = FGOverlayMini; level <= FGOverlayFull; level++)
			for (int warn = 0; warn < (level == FGOverlayStandard ? 2 : 1); warn++) {
				if (block != NULL)
					control_write(block, ^(FGControlBlock *b) {
						b->hud_level = level;
						snprintf(b->warning, sizeof(b->warning), "%s", warn ? "Google Chrome utilise 30\u202F% du CPU" : "");
						snprintf(b->hotkey, sizeof(b->hotkey), "⌥C");
					});
				FGOverlay *overlay = overlay_at(device, level, FGOverlayTopLeft);
				const int width = 1200, height = 760;
				id<MTLTexture> texture = target(device, MTLPixelFormatBGRA8Unorm, width, height, MTLStorageModeShared);
				uint8_t *pixels = malloc((size_t)width * height * 4);
				for (int y = 0; y < height; y++)
					for (int x = 0; x < width; x++) {
						const uint8_t *c = scenes[scene][y < height * 0.45 ? 0 : 1];
						uint8_t *p = pixels + ((size_t)y * width + x) * 4;
						p[0] = c[2];
						p[1] = c[1];
						p[2] = c[0];
						p[3] = 255;
					}
				[texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];
				free(pixels);
				// The second frame, once the warning capsule has faded in
				for (int f = 0; f < 2; f++) {
					overlay.testTime = 300 + f;
					id<MTLCommandBuffer> buffer = [queue commandBuffer];
					[overlay encodeOnto:texture scale:2 commandBuffer:buffer];
					[buffer commit];
					[buffer waitUntilCompleted];
				}
				Image image;
				read_back(texture, &image);
				CGRect bounds = [overlay boundsForWidth:width height:height scale:2];
				snprintf(path, sizeof(path), "%s/hud-%s%s-%s.png", pngs, levelNames[level], warn ? "-warning" : "", sceneNames[scene]);
				write_png(&image, CGRectMake(0, 0, CGRectGetMaxX(bounds) + 48, CGRectGetMaxY(bounds) + 48), path);
				free(image.rgb);
			}
	if (block != NULL) {
		char name[48];
		snprintf(name, sizeof(name), FG_CONTROL_NAME, getpid());
		munmap(block, FG_CONTROL_SIZE);
		shm_unlink(name);
	}
}

static int by_value(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static void cost(id<MTLDevice> device, id<MTLCommandQueue> queue)
{
	printf("== cost at 2560x1440 ==\n");
	// Six passes per command buffer (the overlay has eight buffers), levels interleaved: the buffer's
	// own cost and the GPU's clock changes weigh little and alike. Per pass, ms.
	enum { runs = 80, batch = 6 };
	FGOverlay *overlays[4];
	static double gpu[4][runs], cpu[4][runs];
	for (int level = FGOverlayMini; level <= FGOverlayFull; level++)
		overlays[level] = overlay_at(device, level, FGOverlayTopRight);
	id<MTLTexture> texture = target(device, MTLPixelFormatBGRA8Unorm, 2560, 1440, MTLStorageModePrivate);
	for (int i = -30; i < runs; i++)
		for (int level = FGOverlayMini; level <= FGOverlayFull; level++) {
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			double start = CACurrentMediaTime();
			for (int k = 0; k < batch; k++)
				[overlays[level] encodeOnto:texture scale:2 commandBuffer:buffer];
			double encoded = CACurrentMediaTime();
			[buffer commit];
			[buffer waitUntilCompleted];
			if (i >= 0) {
				gpu[level][i] = (buffer.GPUEndTime - buffer.GPUStartTime) * 1000 / batch;
				cpu[level][i] = (encoded - start) * 1000 / batch;
			}
		}
	for (int level = FGOverlayMini; level <= FGOverlayFull; level++) {
		qsort(gpu[level], runs, sizeof(double), by_value);
		qsort(cpu[level], runs, sizeof(double), by_value);
		char detail[160];
		snprintf(detail, sizeof(detail), "level %d: GPU median %.3f ms, min %.3f, p90 %.3f; CPU encode median %.3f ms", level,
		         gpu[level][runs / 2], gpu[level][0], gpu[level][runs * 9 / 10], cpu[level][runs / 2]);
		check("under 0.1 ms of GPU", gpu[level][runs / 2] < 0.1, detail);
	}
}

static void shared_checks(void)
{
	printf("== shared metrics block ==\n");
	char detail[256];
	const char *name = FGMetricsName();
	check("published under /cartouche-metrics.<pid>", name[0] != 0 && strstr(name, "/cartouche-metrics.") == name, name);
	int fd = shm_open(name, O_RDONLY);
	FGMetricsBlock *block = fd >= 0 ? mmap(NULL, FG_METRICS_SIZE, PROT_READ, MAP_SHARED, fd, 0) : MAP_FAILED;
	if (fd >= 0)
		close(fd);
	if (block == MAP_FAILED) {
		check("readable", 0, strerror(errno));
		return;
	}
	int writable = shm_open(name, O_RDWR);
	int refused = writable < 0 ? errno : 0;
	if (writable >= 0)
		close(writable);
	snprintf(detail, sizeof(detail), "O_RDWR %s", writable < 0 ? strerror(refused) : "opened");
	check("read-only for other openers", writable < 0 && refused == EACCES, detail);
	feed(NO);
	FGMetricsBlock copy;
	uint32_t before, after;
	do {
		before = __atomic_load_n(&block->sequence, __ATOMIC_ACQUIRE);
		memcpy(&copy, block, sizeof(copy));
		__atomic_thread_fence(__ATOMIC_ACQUIRE);
		after = __atomic_load_n(&block->sequence, __ATOMIC_RELAXED);
	} while ((before & 1) != 0 || before != after);
	snprintf(detail, sizeof(detail), "magic %08x version %u size %u pid %d, %.0f fps (%.0f real), 1%% low %.1f, upscale %d %ux%u->%ux%u, "
	         "frames %u, ram %.0f MB, cpu %.0f %%, gpu %.0f %%", copy.magic, copy.version, copy.size, copy.pid, copy.presented_fps,
	         copy.real_fps, copy.low1_fps, copy.upscale, copy.upscale_in_width, copy.upscale_in_height, copy.upscale_out_width,
	         copy.upscale_out_height, copy.frame_count, copy.ram_bytes / 1e6, copy.cpu_percent, copy.gpu_percent);
	BOOL good = copy.magic == FG_METRICS_MAGIC && copy.version == FG_METRICS_VERSION && copy.size == FG_METRICS_SIZE &&
	            copy.pid == getpid() && fabsf(copy.presented_fps - 118) < 0.01 && fabsf(copy.real_fps - 59) < 0.01 &&
	            copy.upscale == FG_UPSCALE_TEMPORAL && copy.upscale_out_height == 1440 && copy.frame_count >= 300 &&
	            copy.framegen == FG_FRAMEGEN_ON && copy.framegen_ane == 1 && fabsf(copy.added_latency_ms - 5.97f) < 0.01;
	check("the block holds the fed numbers", good, detail);
	FGMetricsBlock live;
	FGMetricsRead(&live);
	check("and matches the in-process copy", memcmp(&live.presented_fps, &copy.presented_fps,
	                                                offsetof(FGMetricsBlock, frame_ms_ring) - offsetof(FGMetricsBlock, presented_fps)) == 0,
	      "");
	double slow[200];
	for (int i = 0; i < 200; i++)
		slow[i] = i == 7 ? 50 : i == 9 ? 30 : 10;
	snprintf(detail, sizeof(detail), "%.1f fps", FGMetricsLow1(slow, 200));
	check("1 % low: mean of the slowest 1 % of intervals", fabs(FGMetricsLow1(slow, 200) - 25) < 0.01, detail);
	munmap(block, FG_METRICS_SIZE);
}

// The presenter's order: each real frame is copied in by the pipeline, then the overlay is drawn on
// it, then the frame between is generated. The generated frame must not change with the overlay.
API_AVAILABLE(macos(26.0))
static void generation_checks(id<MTLDevice> device, id<MTLCommandQueue> queue)
{
	printf("== generation inputs ==\n");
	if (![FGPipeline supportsDevice:device]) {
		printf("  skip  no frame interpolator on this Mac\n");
		return;
	}
	const int width = 1920, height = 1080;
	Image outputs[2];
	CGRect panel = CGRectZero;
	for (int pass = 0; pass < 2; pass++) {
		NSString *error = nil;
		FGPipeline *pipeline = [[FGPipeline alloc] initWithDevice:device error:&error];
		if (pipeline == nil || ![pipeline prepareWidth:width height:height format:MTLPixelFormatBGRA8Unorm error:&error]) {
			check("pipeline", 0, error.UTF8String);
			return;
		}
		FGOverlay *overlay = pass == 1 ? overlay_at(device, FGOverlayFull, FGOverlayTopLeft) : nil;
		id<MTLTexture> frames[2];
		for (int f = 0; f < 2; f++) {
			frames[f] = target(device, MTLPixelFormatBGRA8Unorm, width, height, MTLStorageModeShared);
			uint8_t *pixels = malloc((size_t)width * height * 4);
			for (int y = 0; y < height; y++)
				for (int x = 0; x < width; x++) {
					uint8_t rgb[3], *p = pixels + ((size_t)y * width + x) * 4;
					background(x + f * 16, y, rgb);
					p[0] = rgb[2];
					p[1] = rgb[1];
					p[2] = rgb[0];
					p[3] = 255;
				}
			[frames[f] replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];
			free(pixels);
		}
		id<MTLCommandBuffer> first = [queue commandBuffer];
		[pipeline encodeCapture:frames[0] commandBuffer:first];
		[overlay encodeOnto:frames[0] scale:1 commandBuffer:first];
		[first commit];
		id<MTLCommandBuffer> second = [queue commandBuffer];
		[pipeline encodeCapture:frames[1] commandBuffer:second];
		[pipeline encodeFrame:second deltaTime:1 / 40.f];
		[second commit];
		id<MTLCommandBuffer> present = [queue commandBuffer];
		[overlay encodeOnto:frames[1] scale:1 commandBuffer:present];
		[present commit];
		[present waitUntilCompleted];
		id<MTLTexture> output = pipeline.output;
		id<MTLTexture> readable = target(device, output.pixelFormat, width, height, MTLStorageModeShared);
		id<MTLCommandBuffer> copy = [queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [copy blitCommandEncoder];
		[blit copyFromTexture:output toTexture:readable];
		[blit endEncoding];
		[copy commit];
		[copy waitUntilCompleted];
		read_back(readable, &outputs[pass]);
		if (overlay != nil) {
			panel = [overlay panelForWidth:width height:height scale:1];
			Image shown;
			read_back(frames[1], &shown);
			shown.bounds = [overlay boundsForWidth:width height:height scale:1];
			Census c = census(&shown, panel, 1);
			char detail[96];
			snprintf(detail, sizeof(detail), "pad %d,%d,%d, %d white pixels", c.pad[0], c.pad[1], c.pad[2], c.white);
			check("the real frames carry the overlay", c.pad[0] < 70 && c.white > 40, detail);
			free(shown.rgb);
		}
	}
	size_t differ = 0, inPanel = 0;
	for (int y = 0; y < height; y++)
		for (int x = 0; x < width; x++) {
			size_t i = ((size_t)y * width + x) * 3;
			if (memcmp(outputs[0].rgb + i, outputs[1].rgb + i, 3) != 0) {
				differ++;
				inPanel += inside(panel, x, y);
			}
		}
	char detail[128];
	snprintf(detail, sizeof(detail), "%zu pixels differ, %zu of them in the panel", differ, inPanel);
	check("the generated frame is the same with the overlay on the real frames", differ == 0, detail);
	free(outputs[0].rgb);
	free(outputs[1].rgb);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		const char *folder = argc > 1 ? argv[1] : NULL, *pngs = argc > 2 ? argv[2] : NULL;
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			printf("no Metal device\n");
			return 1;
		}
		id<MTLCommandQueue> queue = [device newCommandQueue];
		printf("== variables ==\n");
		parse_checks();
		FGMetricsStart(YES);
		stale_checks(device, queue);
		if (pngs != NULL) {
			dusk = YES;
			FGOverlay *waiting = overlay_at(device, FGOverlayStandard, FGOverlayTopLeft);
			Image image = draw(device, queue, waiting, MTLPixelFormatBGRA8Unorm, 1200, 760, 2);
			char path[1024];
			snprintf(path, sizeof(path), "%s/hud-stale.png", pngs);
			write_png(&image, CGRectMake(0, 0, CGRectGetMaxX(image.bounds) + 48, CGRectGetMaxY(image.bounds) + 48), path);
			free(image.rgb);
			dusk = NO;
		}
		feed(NO);
		pixel_checks(device, queue, folder);
		morph_checks(device, queue, pngs);
		control_checks(device, queue);
		doc_renders(device, queue, pngs);
		cost(device, queue);
		shared_checks();
		if (@available(macOS 26.0, *))
			generation_checks(device, queue);
		printf("%s\n", fails ? "overlay: FAIL" : "overlay: all ok");
		return fails ? 1 : 0;
	}
}
