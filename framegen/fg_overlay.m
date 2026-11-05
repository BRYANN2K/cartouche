#import "fg_overlay.h"

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>

#import <fcntl.h>
#import <math.h>
#import <stdio.h>
#import <string.h>
#import <sys/mman.h>
#import <unistd.h>

#import "fg_control_shm.h"
#import "fg_metrics.h"
#import "framegen_overlay.h"

// overlay.metal's quad and graph
typedef struct {
	float rect[4], uv[4], color[4], shape[4], clip[4];
} Quad;

enum { graph_samples = 120 };

typedef struct {
	float y[graph_samples];
	float grid[3];
	float count, unit, width;
	float pad[2];
} GraphData;

// The text layers a panel composites itself, one per block texture, in target pixels
typedef struct {
	float rect[4][4];
	float alpha[4];
} Layers;

enum { quad_panel, quad_graph, quad_shadow };
enum { max_quads = 32, buffer_count = 8 };
enum { block_mini, block_std, block_mac, block_warn, block_count };
enum { state_off, state_on, state_in, state_out };

// Points, as the mockup's HUD; everything grows with the target's pixels per point and the size setting
static const double hud_width = 236, pad_x = 16, pad_y = 12, radius = 22, top_margin = 16, edge_margin = 24;
static const double mini_height = 44, row_height = 28, graph_height = 34, block_gap = 10, cell_gap = 8, col_gap = 10;
static const double value_line = 13 * 1.35, label_line = 11 * 1.35, warn_gap = 8, shadow_blur = 12, shadow_y = 4;
static const double spring_response = 0.24;

static const double fill_rgba[4] = { 22 / 255.0, 22 / 255.0, 26 / 255.0, 0.84 };
static const double label_rgba[4] = { 1, 1, 1, 1 };
static const double label2_rgba[4] = { 235 / 255.0, 235 / 255.0, 245 / 255.0, 0.84 };
static const double label3_rgba[4] = { 235 / 255.0, 235 / 255.0, 245 / 255.0, 0.62 };
static const double fill2_rgba[4] = { 1, 1, 1, 0.14 };
static const double sep_rgba[4] = { 1, 1, 1, 0.10 };
static const double orange_rgba[4] = { 1, 159 / 255.0, 10 / 255.0, 1 };
static const float green[3] = { 48 / 255.f, 209 / 255.f, 88 / 255.f };

#define NB @" "

BOOL FGOverlayParseLevel(const char *text, FGOverlayLevel *level)
{
	static const char *const names[] = { "off", "mini", "std", "full" };
	*level = FGOverlayOff;
	if (text == NULL || text[0] == 0 || strcmp(text, "0") == 0)
		return YES;
	for (int i = 0; i < 4; i++)
		if (strcmp(text, names[i]) == 0) {
			*level = (FGOverlayLevel)i;
			return YES;
		}
	if (strcmp(text, "1") == 0 || strcmp(text, "standard") == 0) {
		*level = FGOverlayStandard;
		return YES;
	}
	return NO;
}

BOOL FGOverlayParseCorner(const char *text, FGOverlayCorner *corner)
{
	static const char *const names[] = { "tl", "tr", "bl", "br" };
	*corner = FGOverlayTopRight;
	if (text == NULL || text[0] == 0)
		return YES;
	for (int i = 0; i < 4; i++)
		if (strcmp(text, names[i]) == 0) {
			*corner = (FGOverlayCorner)i;
			return YES;
		}
	return NO;
}

static BOOL linear_format(MTLPixelFormat format)
{
	switch (format) {
	case MTLPixelFormatBGRA8Unorm_sRGB:
	case MTLPixelFormatRGBA8Unorm_sRGB:
	case MTLPixelFormatBGRA10_XR_sRGB:
	case MTLPixelFormatBGR10_XR_sRGB:
	case MTLPixelFormatRGBA16Float:
	case MTLPixelFormatRGBA32Float:
	case MTLPixelFormatRG11B10Float:
	case MTLPixelFormatRGB9E5Float:
		return YES;
	default:
		return NO;
	}
}

static NSString *number(double value, int decimals, BOOL french)
{
	NSString *text = [NSString stringWithFormat:@"%.*f", decimals, value];
	return french ? [text stringByReplacingOccurrencesOfString:@"." withString:@","] : text;
}

// The HUD's words in the app's language, as Overlay.xcstrings has them
enum { w_waiting, w_real, w_low, w_latency, w_native, w_spatial, w_temporal, w_frame, w_active, w_gpu, w_power, w_memory,
       w_heat, w_battery, w_gb, w_normal, w_fair, w_serious, w_critical, w_count };
static NSString *const words_en[w_count] = { @"Waiting for the game", @"Real", @"1% Low", @"Latency", @"Native", @"Spatial",
	@"Temporal", @"Per Frame", @"Active", @"Mac GPU", @"Power", @"Memory", @"Heat", @"Battery", @"GB", @"Nominal", @"Fair",
	@"Serious", @"Critical" };
static NSString *const words_fr[w_count] = { @"En attente du jeu", @"Réels", @"1" NB @"% low", @"Latence", @"Natif", @"Spatial",
	@"Temporel", @"Frametime", @"Actif", @"GPU Mac", @"Puissance", @"Mémoire", @"Chaleur", @"Batterie", @"Go", @"Normale",
	@"Modérée", @"Élevée", @"Critique" };

BOOL FGOverlayFrench(const char *language)
{
	if (language != NULL && language[0] != 0)
		return strncmp(language, "fr", 2) == 0;
	return [[NSLocale preferredLanguages].firstObject hasPrefix:@"fr"];
}

static double ease_out(double p)
{
	p = fmin(1, fmax(0, p));
	return 1 - (1 - p) * (1 - p) * (1 - p);
}

// Critically damped, as SwiftUI's spring(response:dampingFraction: 1); keeps its velocity when retargeted
static void spring(double *x, double *v, double target, double dt)
{
	double k = pow(2 * M_PI / spring_response, 2), c = 4 * M_PI / spring_response;
	for (double left = dt; left > 1e-9; left -= 1 / 240.0) {
		double h = fmin(left, 1 / 240.0);
		*v += (-k * (*x - target) - c * *v) * h;
		*x += *v * h;
	}
	if (fabs(*x - target) < 0.05 && fabs(*v) < 0.5) {
		*x = target;
		*v = 0;
	}
}

static CGColorRef color_of(const double rgba[4])
{
	return CGColorCreateSRGB(rgba[0], rgba[1], rgba[2], rgba[3]);
}

static double baseline_in(double line, CTFontRef font)
{
	double ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font);
	return (line - (ascent + descent)) / 2 + ascent;
}

static CTLineRef make_line(NSString *text, CTFontRef font, const double rgba[4], double kern)
{
	CGColorRef color = color_of(rgba);
	NSDictionary *attributes = @{
		(__bridge NSString *)kCTFontAttributeName : (__bridge id)font,
		(__bridge NSString *)kCTForegroundColorAttributeName : (__bridge id)color,
		(__bridge NSString *)kCTKernAttributeName : @(kern),
	};
	CTLineRef line = CTLineCreateWithAttributedString(
		(__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:text attributes:attributes]);
	CGColorRelease(color);
	return line;
}

static double width_of(NSString *text, CTFontRef font, double kern)
{
	CTLineRef line = make_line(text, font, label_rgba, kern);
	double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
	CFRelease(line);
	return width;
}

// context NULL only measures; returns the advance. maxWidth > 0 truncates with an ellipsis.
static double draw_text(CGContextRef context, NSString *text, CTFontRef font, const double rgba[4], double kern, double x,
                        double baseline, double maxWidth)
{
	CTLineRef line = make_line(text, font, rgba, kern);
	if (maxWidth > 0 && CTLineGetTypographicBounds(line, NULL, NULL, NULL) > maxWidth) {
		CTLineRef dots = make_line(@"…", font, rgba, kern);
		CTLineRef cut = CTLineCreateTruncatedLine(line, maxWidth, kCTLineTruncationEnd, dots);
		CFRelease(dots);
		if (cut != NULL) {
			CFRelease(line);
			line = cut;
		}
	}
	double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
	if (context != NULL) {
		CGContextSetTextPosition(context, x, baseline);
		CTLineDraw(line, context);
	}
	CFRelease(line);
	return width;
}

static void fill_round(CGContextRef context, CGRect rect, double r, const double rgba[4])
{
	if (context == NULL)
		return;
	CGColorRef color = color_of(rgba);
	CGPathRef path = CGPathCreateWithRoundedRect(rect, r, r, NULL);
	CGContextSetFillColorWithColor(context, color);
	CGContextAddPath(context, path);
	CGContextFillPath(context);
	CGPathRelease(path);
	CGColorRelease(color);
}


@implementation FGOverlay {
	id<MTLDevice> _device;
	id<MTLLibrary> _library;
	NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *_pipelines;
	NSMutableSet<NSNumber *> *_refused;
	id<MTLBuffer> _buffers[buffer_count];
	unsigned _next;
	dispatch_semaphore_t _free;
	id<MTLTexture> _blank;
	NSMutableDictionary<NSString *, id> *_fonts;

	// One text layer per block: Mini, the Standard part, the Complet part, the warning capsule
	id<MTLTexture> _texture[block_count];
	NSString *_key[block_count];
	double _blockWidth[block_count], _blockHeight[block_count], _blockY[block_count];
	int _state[block_count];
	double _from[block_count], _start[block_count];

	FGOverlayLevel _shown;
	FGOverlayCorner _shownCorner;
	BOOL _sized;
	double _w, _h, _vw, _vh, _ox, _oy, _vox, _voy, _x, _y;
	int _appearing;
	double _appearFrom, _appearStart, _last;
	BOOL _warnShown;
	double _warnStart;

	const FGControlBlock *_map;
	FGControlBlock _control;
	double _nextOpen;
	char _language[8];

	NSUInteger _forWidth, _forHeight;
	double _forScale;
	CGRect _panel, _bounds;
	GraphData _graph;
	Layers _layers;
}

+ (instancetype)overlayFromEnvironment:(id<MTLDevice>)device log:(void (*)(const char *, ...))log
{
	const char *levelText = getenv("CARTOUCHE_OVERLAY"), *cornerText = getenv("CARTOUCHE_OVERLAY_POS");
	const char *control = getenv("CARTOUCHE_OVERLAY_CONTROL");
	FGOverlayLevel level;
	FGOverlayCorner corner;
	if (!FGOverlayParseLevel(levelText, &level)) {
		log("overlay: unknown level %s", levelText);
		return nil;
	}
	if (level == FGOverlayOff && (control == NULL || strcmp(control, "1") != 0))
		return nil;
	if (!FGOverlayParseCorner(cornerText, &corner)) {
		log("overlay: unknown position %s", cornerText);
		corner = FGOverlayTopRight;
	}
	NSString *error = nil;
	FGOverlay *overlay = [[self alloc] initWithDevice:device level:level corner:corner error:&error];
	if (overlay == nil)
		log("overlay off: %s", error.UTF8String);
	else
		log("overlay %s at %s", levelText != NULL && levelText[0] ? levelText : "off",
		    cornerText != NULL && cornerText[0] ? cornerText : "tr");
	return overlay;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device level:(FGOverlayLevel)level corner:(FGOverlayCorner)corner
                         error:(NSString **)error
{
	if ((self = [super init]) == nil)
		return nil;
	_device = device;
	_level = level;
	_corner = corner;
	_sizePercent = 100;
	NSString *source = [[NSString alloc] initWithBytes:overlay_metal length:overlay_metal_len encoding:NSUTF8StringEncoding];
	NSError *failure = nil;
	_library = [device newLibraryWithSource:source options:[MTLCompileOptions new] error:&failure];
	if (_library == nil) {
		if (error != NULL)
			*error = failure.localizedDescription ?: @"overlay.metal did not compile";
		return nil;
	}
	for (int i = 0; i < buffer_count; i++)
		_buffers[i] = [device newBufferWithLength:sizeof(Quad) * max_quads options:MTLResourceStorageModeShared];
	_free = dispatch_semaphore_create(buffer_count);
	_pipelines = [NSMutableDictionary new];
	_refused = [NSMutableSet new];
	_fonts = [NSMutableDictionary new];
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1
	                                                                         mipmapped:NO];
	d.storageMode = MTLStorageModeShared;
	_blank = [device newTextureWithDescriptor:d];
	uint32_t clear = 0;
	[_blank replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&clear bytesPerRow:4];
	_shown = FGOverlayOff;
	const char *language = getenv("CARTOUCHE_OVERLAY_LANG");
	if (language != NULL)
		strlcpy(_language, language, sizeof(_language));
	return self;
}

- (void)dealloc
{
	if (_map != NULL)
		munmap((void *)_map, FG_CONTROL_SIZE);
}

- (BOOL)controlled
{
	return _map != NULL;
}

- (id<MTLRenderPipelineState>)pipelineFor:(MTLPixelFormat)format
{
	id<MTLRenderPipelineState> pipeline = _pipelines[@(format)];
	if (pipeline != nil || [_refused containsObject:@(format)])
		return pipeline;
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [_library newFunctionWithName:@"overlay_vertex"];
	d.fragmentFunction = [_library newFunctionWithName:@"overlay_fragment"];
	MTLRenderPipelineColorAttachmentDescriptor *color = d.colorAttachments[0];
	color.pixelFormat = format;
	color.blendingEnabled = YES;
	color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	color.sourceAlphaBlendFactor = MTLBlendFactorOne;
	color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pipeline = [_device newRenderPipelineStateWithDescriptor:d error:nil];
	if (pipeline != nil)
		_pipelines[@(format)] = pipeline;
	else
		[_refused addObject:@(format)];
	return pipeline;
}

// SF Pro with tabular digits, in points
- (CTFontRef)font:(double)size weight:(NSFontWeight)weight
{
	NSString *key = [NSString stringWithFormat:@"%g/%g", size, weight];
	id font = _fonts[key];
	if (font == nil) {
		font = [NSFont monospacedDigitSystemFontOfSize:size weight:weight] ?: [NSFont systemFontOfSize:size];
		_fonts[key] = font;
	}
	return (__bridge CTFontRef)font;
}

// The app's control block for this process, opened at most once a second while missing
- (void)readControl:(double)now
{
	if (_map == NULL) {
		if (now < _nextOpen)
			return;
		_nextOpen = now + 1;
		char name[48];
		snprintf(name, sizeof(name), FG_CONTROL_NAME, getpid());
		int fd = shm_open(name, O_RDONLY);
		if (fd < 0)
			return;
		void *map = mmap(NULL, FG_CONTROL_SIZE, PROT_READ, MAP_SHARED, fd, 0);
		close(fd);
		if (map == MAP_FAILED)
			return;
		_map = map;
	}
	FGControlBlock copy;
	for (int tries = 0; tries < 4; tries++) {
		uint32_t before = __atomic_load_n(&_map->sequence, __ATOMIC_ACQUIRE);
		if ((before & 1) != 0)
			continue;
		memcpy(&copy, (const void *)_map, sizeof(copy));
		__atomic_thread_fence(__ATOMIC_ACQUIRE);
		if (__atomic_load_n(&_map->sequence, __ATOMIC_RELAXED) != before)
			continue;
		if (copy.magic != FG_CONTROL_MAGIC || copy.version != FG_CONTROL_VERSION || copy.size != FG_CONTROL_SIZE)
			return;
		copy.warning[sizeof(copy.warning) - 1] = 0;
		copy.hotkey[sizeof(copy.hotkey) - 1] = 0;
		copy.language[sizeof(copy.language) - 1] = 0;
		_control = copy;
		if (copy.hud_level >= FG_HUD_HIDDEN && copy.hud_level <= FG_HUD_FULL)
			self.level = (FGOverlayLevel)copy.hud_level;
		if (copy.hud_corner >= FG_CORNER_TL && copy.hud_corner <= FG_CORNER_BR)
			self.corner = (FGOverlayCorner)copy.hud_corner;
		if (copy.hud_scale >= 50 && copy.hud_scale <= 200)
			self.sizePercent = copy.hud_scale;
		return;
	}
}

static BOOL has(FGOverlayLevel level, int block)
{
	switch (block) {
	case block_mini: return level == FGOverlayMini;
	case block_std: return level == FGOverlayStandard || level == FGOverlayFull;
	case block_mac: return level == FGOverlayFull;
	default: return NO;
	}
}

// The control block's language first, then the launch's, then the Mac's
- (BOOL)french
{
	return FGOverlayFrench(_map != NULL && _control.language[0] ? _control.language : _language);
}

// The texts of a block, one line per string; the same strings draw the same layer
- (NSArray<NSString *> *)texts:(int)block metrics:(const FGMetricsBlock *)m
{
	BOOL stale = m->seconds == 0, french = [self french];
	NSString *const *w = french ? words_fr : words_en;
	NSString *fps = [NSString stringWithFormat:@"%.0f", m->presented_fps];
	NSString *mult = m->framegen == FG_FRAMEGEN_ON && m->framegen_factor > 1 ? [NSString stringWithFormat:@"×%d", m->framegen_factor] : @"";
	double frame = m->frame_ms > 0 ? m->frame_ms : m->presented_fps > 0 ? 1000 / m->presented_fps : 0;
	switch (block) {
	case block_mini:
		return stale ? @[ @"stale", w[w_waiting] ] : @[ @"live", fps, mult, number(frame, 1, french) ];
	case block_std: {
		if (stale)
			return @[ @"stale", w[w_waiting] ];
		int percent = 100;
		NSString *mode = w[w_native];
		if (m->upscale != FG_UPSCALE_NONE) {
			mode = m->upscale == FG_UPSCALE_TEMPORAL ? w[w_temporal] : w[w_spatial];
			if (m->upscale_out_height > 0)
				percent = (int)lround(100.0 * m->upscale_in_height / m->upscale_out_height);
		}
		return @[
			@"live", fps, mult,
			[NSString stringWithFormat:@"%.0f", m->real_fps], w[w_real],
			[NSString stringWithFormat:@"%.0f", m->low1_fps], w[w_low],
			[NSString stringWithFormat:@"%.0f" NB @"ms", m->added_latency_ms], w[w_latency],
			[NSString stringWithFormat:french ? @"%d" NB @"%%" : @"%d%%", percent], mode,
			[number(frame, 1, french) stringByAppendingString:NB @"ms"], w[w_frame],
			m->framegen_ane ? w[w_active] : @"—", @"Neural E.",
		];
	}
	case block_mac: {
		BOOL control = _map != NULL;
		NSString *percent = french ? @"%.0f" NB @"%%" : @"%.0f%%";
		NSString *watts = control && _control.gpu_watts >= 0 ? [number(_control.gpu_watts, 1, french) stringByAppendingString:NB @"W"] : @"—";
		NSString *battery = control && _control.battery_percent >= 0
			? [NSString stringWithFormat:percent, (double)_control.battery_percent] : @"—";
		int thermal = m->thermal >= 0 && m->thermal < 4 ? m->thermal : 0;
		return @[
			[NSString stringWithFormat:percent, m->cpu_percent], @"CPU",
			m->gpu_percent >= 0 ? [NSString stringWithFormat:percent, m->gpu_percent] : @"—", w[w_gpu],
			watts, w[w_power],
			[number(m->ram_bytes / 1e9, 1, french) stringByAppendingString:[NB stringByAppendingString:w[w_gb]]], w[w_memory],
			w[w_normal + thermal], w[w_heat],
			battery, w[w_battery],
		];
	}
	default:
		return @[ @(_control.warning), _control.hotkey[0] ? @(_control.hotkey) : @"⌥C" ];
	}
}

// Lays out a block in points from its top left; draws when context is set. Returns its size.
- (CGSize)layout:(int)block texts:(NSArray<NSString *> *)t context:(CGContextRef)c
{
	BOOL stale = [t[0] isEqualToString:@"stale"];
	CTFontRef value = [self font:13 weight:NSFontWeightMedium], label = [self font:11 weight:NSFontWeightRegular];
	if (block == block_mini) {
		CTFontRef bold = [self font:13 weight:NSFontWeightSemibold];
		double baseline = (mini_height - value_line) / 2 + baseline_in(value_line, bold), x = pad_x;
		if (stale)
			x += draw_text(c, t[1], label, label3_rgba, 0, x, baseline, 0);
		else {
			x += draw_text(c, t[1], bold, label_rgba, 0, x, baseline, 0) + 3;
			x += draw_text(c, @"FPS", label, label2_rgba, 0, x, baseline, 0);
			if (t[2].length > 0)
				x += 12 + draw_text(c, t[2], bold, label_rgba, 0, x + 12, baseline, 0);
			x += 12;
			x += draw_text(c, t[3], bold, label_rgba, 0, x, baseline, 0) + 3;
			x += draw_text(c, @"ms", label, label2_rgba, 0, x, baseline, 0);
		}
		return CGSizeMake(ceil(x + pad_x), mini_height);
	}
	if (block == block_warn) {
		CTFontRef text = [self font:13 weight:NSFontWeightRegular], key = [self font:11 weight:NSFontWeightMedium];
		double height = 2 * warn_gap + value_line, keyWidth = width_of(t[1], key, 0) + 12;
		double baseline = warn_gap + baseline_in(value_line, text), x = 12;
		fill_round(c, CGRectMake(x, (height - 7) / 2, 7, 7), 3.5, orange_rgba);
		x += 7 + 8;
		double room = 340 - x - 8 - keyWidth - 8;
		x += draw_text(c, t[0], text, label_rgba, 0, x, baseline, room) + 8;
		double keyHeight = label_line + 2;
		fill_round(c, CGRectMake(x, (height - keyHeight) / 2, keyWidth, keyHeight), 5, fill2_rgba);
		draw_text(c, t[1], key, label_rgba, 0, x + 6, (height - keyHeight) / 2 + 1 + baseline_in(label_line, key), 0);
		return CGSizeMake(ceil(x + keyWidth + 8), height);
	}
	double y = block == block_std ? pad_y : 0;
	if (block == block_std) {
		CTFontRef big = [self font:28 weight:NSFontWeightSemibold];
		double baseline = y + baseline_in(row_height, big);
		double x = pad_x + draw_text(c, stale ? @"—" : t[1], big, stale ? label3_rgba : label_rgba, 0.28, pad_x, baseline, 0) + 6;
		draw_text(c, stale ? t[1] : @"FPS", label, stale ? label3_rgba : label2_rgba, 0, x, baseline, 0);
		if (!stale && t[2].length > 0) {
			CTFontRef pill = [self font:11 weight:NSFontWeightSemibold];
			double w = width_of(t[2], pill, 0) + 14, h = label_line + 4;
			double px = hud_width - pad_x - w, py = y + (row_height - h) / 2;
			fill_round(c, CGRectMake(px, py, w, h), h / 2, fill2_rgba);
			draw_text(c, t[2], pill, label_rgba, 0, px + 7, py + 2 + baseline_in(label_line, pill), 0);
		}
		y += row_height;
		if (stale)
			return CGSizeMake(hud_width, y);
		y += block_gap + graph_height + block_gap;
	} else {
		if (c != NULL)
			fill_round(c, CGRectMake(pad_x, block_gap, hud_width - 2 * pad_x, 1), 0, sep_rgba);
		y += block_gap + 1 + block_gap;
	}
	int first = block == block_std ? 3 : 0;
	double column = (hud_width - 2 * pad_x - 2 * col_gap) / 3;
	for (int i = 0; i < 6; i++) {
		double x = pad_x + (i % 3) * (column + col_gap), top = y + (i / 3) * (value_line + label_line + cell_gap);
		draw_text(c, t[first + 2 * i], value, label_rgba, 0, x, top + baseline_in(value_line, value), column + col_gap);
		draw_text(c, t[first + 2 * i + 1], label, label2_rgba, 0, x, top + value_line + baseline_in(label_line, label), column + col_gap);
	}
	y += 2 * (value_line + label_line) + cell_gap;
	return CGSizeMake(hud_width, y);
}

// Draws a block into a texture at s pixels per point, only when its texts or scale changed
- (void)prepare:(int)block texts:(NSArray<NSString *> *)texts scale:(double)s
{
	NSString *key = [NSString stringWithFormat:@"%g|%@", s, [texts componentsJoinedByString:@"|"]];
	if (_texture[block] != nil && [_key[block] isEqualToString:key])
		return;
	CGSize size = [self layout:block texts:texts context:NULL];
	size_t width = (size_t)ceil(size.width * s), height = (size_t)ceil(size.height * s);
	CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef c = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
	                                       (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
	CGColorSpaceRelease(space);
	if (c == NULL)
		return;
	CGContextSetShouldAntialias(c, true);
	CGContextSetShouldSmoothFonts(c, false);
	CGContextTranslateCTM(c, 0, (CGFloat)height);
	CGContextScaleCTM(c, s, -s);
	CGContextSetTextMatrix(c, CGAffineTransformMakeScale(1, -1));
	[self layout:block texts:texts context:c];
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width
	                                                                            height:height
	                                                                         mipmapped:NO];
	d.usage = MTLTextureUsageShaderRead;
	d.storageMode = MTLStorageModeShared;
	id<MTLTexture> texture = [_device newTextureWithDescriptor:d];
	[texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:CGBitmapContextGetData(c)
	           bytesPerRow:CGBitmapContextGetBytesPerRow(c)];
	CGContextRelease(c);
	if (texture == nil)
		return;
	// The texture in flight stays alive with its command buffer; the next frame takes this one
	_texture[block] = texture;
	_key[block] = key;
	_blockWidth[block] = size.width;
	_blockHeight[block] = size.height;
}

// Target panel size for a level, in points, from the prepared blocks
- (CGSize)sizeFor:(FGOverlayLevel)level
{
	if (level == FGOverlayMini)
		return CGSizeMake(_blockWidth[block_mini], mini_height);
	double height = _blockHeight[block_std] + (level == FGOverlayFull ? _blockHeight[block_mac] : 0) + pad_y;
	return CGSizeMake(hud_width, height);
}

static double alpha_of(int state, double from, double start, double now, BOOL reduce)
{
	switch (state) {
	case state_on: return 1;
	case state_in: {
		double delay = reduce ? 0 : 0.11, duration = reduce ? 0.12 : 0.13;
		return from + (1 - from) * ease_out((now - start - delay) / duration);
	}
	case state_out: return from * (1 - ease_out((now - start) / (reduce ? 0.12 : 0.10)));
	default: return 0;
	}
}

- (double)alpha:(int)block now:(double)now reduce:(BOOL)reduce
{
	double a = alpha_of(_state[block], _from[block], _start[block], now, reduce);
	if (_state[block] == state_out && now - _start[block] >= (reduce ? 0.12 : 0.10))
		_state[block] = state_off;
	else if (_state[block] == state_in && now - _start[block] >= (reduce ? 0.12 : 0.24))
		_state[block] = state_on;
	return a;
}

- (double)panelAlpha:(double)now reduce:(BOOL)reduce
{
	if (_appearing == 1)
		return _appearFrom + (1 - _appearFrom) * ease_out((now - _appearStart) / (reduce ? 0.12 : 0.30));
	if (_appearing == -1)
		return _appearFrom * (1 - ease_out((now - _appearStart) / (reduce ? 0.12 : 0.16)));
	return _shown == FGOverlayOff ? 0 : 1;
}

// inset: the notch and the menu bar, the HUD sits below them
static void origin_for(FGOverlayCorner corner, double width, double height, double w, double h, double inset, double *x, double *y)
{
	BOOL left = corner == FGOverlayTopLeft || corner == FGOverlayBottomLeft;
	BOOL top = corner == FGOverlayTopLeft || corner == FGOverlayTopRight;
	*x = left ? edge_margin : width - edge_margin - w;
	*y = top ? fmax(top_margin, inset > 0 ? inset + warn_gap : 0) : height - edge_margin - h;
}

// The app's safe top in HUD units, for a target that fills the game's screen
- (double)topInsetForHeight:(double)height scale:(double)s
{
	if (_map == NULL || _control.safe_top <= 0 || _control.screen_height <= 0)
		return 0;
	int percent = self.sizePercent;
	double size = (percent >= 50 && percent <= 200 ? percent : 100) / 100.0;
	return fabs(height / s * size - _control.screen_height) <= 2 ? _control.safe_top / size : 0;
}

// Moves the HUD one frame towards the requested level, corner and size
- (void)step:(double)now metrics:(const FGMetricsBlock *)m width:(double)width height:(double)height scale:(double)s
      reduce:(BOOL)reduce
{
	double gap = fmax(0, now - _last), dt = gap >= 0.5 ? 0 : fmin(0.064, gap);
	BOOL first = _last <= 0;
	_last = now;
	FGOverlayLevel level = self.level;
	FGOverlayCorner corner = self.corner;
	// After a long stall, what was moving has arrived; a change made now starts from there
	if (!first && gap >= 0.5 && _sized && _shown != FGOverlayOff) {
		CGSize size = [self sizeFor:_shown];
		_w = size.width;
		_h = size.height;
		_vw = _vh = _ox = _oy = _vox = _voy = 0;
	}
	for (int b = block_mini; b <= block_mac; b++)
		if (has(level, b))
			[self prepare:b texts:[self texts:b metrics:m] scale:s];
	if (level != _shown) {
		double panel = [self panelAlpha:now reduce:reduce];
		if (level == FGOverlayOff) {
			_appearing = -1;
			_appearFrom = panel;
			_appearStart = now;
		} else if (_shown == FGOverlayOff || panel <= 0) {
			for (int b = block_mini; b <= block_mac; b++)
				_state[b] = has(level, b) ? state_on : state_off;
			CGSize size = [self sizeFor:level];
			_w = size.width;
			_h = size.height;
			_vw = _vh = 0;
			_appearFrom = panel;
			_appearing = first ? 0 : 1;
			_appearStart = now;
			_shownCorner = corner;
			_ox = _oy = _vox = _voy = 0;
			_sized = YES;
		} else {
			for (int b = block_mini; b <= block_mac; b++) {
				double a = [self alpha:b now:now reduce:reduce];
				BOOL want = has(level, b), there = _state[b] == state_on || _state[b] == state_in;
				if (want && !there) {
					_state[b] = state_in;
					_from[b] = a;
					_start[b] = now;
				} else if (!want && there) {
					_state[b] = state_out;
					_from[b] = a;
					_start[b] = now;
				}
			}
		}
		_shown = level;
	}
	if (_appearing != 0 && now - _appearStart >= (reduce ? 0.12 : _appearing == 1 ? 0.30 : 0.16)) {
		if (_appearing == -1) {
			for (int b = block_mini; b <= block_mac; b++)
				_state[b] = state_off;
			_sized = NO;
		}
		_appearing = 0;
	}
	if (_shown == FGOverlayOff && _appearing == 0)
		return;
	if (_shown != FGOverlayOff) {
		CGSize target = [self sizeFor:_shown];
		BOOL moving = _vw != 0 || _vh != 0;
		BOOL morphing = _state[block_mini] == state_in || _state[block_mini] == state_out || _state[block_std] == state_in ||
		                _state[block_std] == state_out || _state[block_mac] == state_in || _state[block_mac] == state_out;
		if (reduce || !_sized || (!moving && !morphing)) {
			_w = target.width;
			_h = target.height;
			_vw = _vh = 0;
		} else {
			spring(&_w, &_vw, target.width, dt);
			spring(&_h, &_vh, target.height, dt);
		}
		_sized = YES;
	}
	double tx, ty;
	origin_for(corner, width / s, height / s, _w, _h, [self topInsetForHeight:height scale:s], &tx, &ty);
	if (corner != _shownCorner) {
		if (!reduce && _shown != FGOverlayOff) {
			_ox = _x - tx;
			_oy = _y - ty;
			_vox = _voy = 0;
		}
		_shownCorner = corner;
	}
	if (reduce)
		_ox = _oy = _vox = _voy = 0;
	spring(&_ox, &_vox, 0, dt);
	spring(&_oy, &_voy, 0, dt);
	_x = tx + _ox;
	_y = ty + _oy;
	if (has(_shown, block_mac) || _state[block_mac] == state_in)
		_blockY[block_mac] = _blockHeight[block_std];
}

static void rect_of(float out[4], CGRect r)
{
	out[0] = (float)r.origin.x;
	out[1] = (float)r.origin.y;
	out[2] = (float)r.size.width;
	out[3] = (float)r.size.height;
}

static Quad *add(Quad *quads, int *count, int kind, CGRect rect, CGRect clip, double corner)
{
	if (*count >= max_quads)
		return NULL;
	Quad *q = &quads[(*count)++];
	memset(q, 0, sizeof(*q));
	rect_of(q->rect, rect);
	rect_of(q->clip, clip);
	q->shape[0] = kind;
	q->shape[1] = (float)corner;
	return q;
}

static void set_color(float out[4], const double rgba[4], double alpha)
{
	for (int i = 0; i < 3; i++)
		out[i] = (float)rgba[i];
	out[3] = (float)(rgba[3] * alpha);
}

// A glass surface: shadow, then the dark fill with its rim and top highlight
static void surface(Quad *quads, int *count, CGRect r, double corner, double s, double alpha, unsigned layers)
{
	CGRect caster = CGRectOffset(r, 0, shadow_y * s), all = CGRectInset(caster, -shadow_blur * s, -shadow_blur * s);
	// Four strips around the panel: its middle is never shaded twice
	CGRect inner = CGRectInset(r, corner, corner);
	if (CGRectIsEmpty(inner))
		inner = CGRectMake(CGRectGetMidX(r), CGRectGetMidY(r), 0, 0);
	const CGRect strips[4] = {
		CGRectMake(all.origin.x, all.origin.y, all.size.width, inner.origin.y - all.origin.y),
		CGRectMake(all.origin.x, CGRectGetMaxY(inner), all.size.width, CGRectGetMaxY(all) - CGRectGetMaxY(inner)),
		CGRectMake(all.origin.x, inner.origin.y, inner.origin.x - all.origin.x, inner.size.height),
		CGRectMake(CGRectGetMaxX(inner), inner.origin.y, CGRectGetMaxX(all) - CGRectGetMaxX(inner), inner.size.height),
	};
	Quad *q;
	for (int i = 0; i < 4; i++) {
		if (strips[i].size.width <= 0 || strips[i].size.height <= 0)
			continue;
		q = add(quads, count, quad_shadow, strips[i], r, corner);
		if (q != NULL) {
			rect_of(q->uv, caster);
			q->color[3] = (float)(0.24 * alpha);
			q->shape[2] = (float)(shadow_blur * s);
		}
	}
	q = add(quads, count, quad_panel, r, r, corner);
	if (q != NULL) {
		q->clip[0] = (float)layers;
		set_color(q->color, fill_rgba, alpha);
		set_color(q->uv, sep_rgba, alpha);
		q->shape[2] = (float)(0.5 * s);
		q->shape[3] = (float)s;
	}
}

static CGRect shadowed(CGRect r, double s)
{
	CGRect shadow = CGRectInset(CGRectOffset(r, 0, shadow_y * s), -shadow_blur * s, -shadow_blur * s);
	return CGRectUnion(r, shadow);
}

// Builds the quads of this frame; their count, 0 when nothing shows
- (int)quads:(Quad *)quads now:(double)now metrics:(const FGMetricsBlock *)m width:(double)width height:(double)height
       scale:(double)s reduce:(BOOL)reduce
{
	int count = 0;
	_panel = CGRectZero;
	_bounds = CGRectZero;
	double ga = [self panelAlpha:now reduce:reduce];
	if (_shown == FGOverlayOff && _appearing == 0)
		return 0;
	double sc = reduce ? 1 : 1 - 0.04 * (1 - ga);
	CGRect base = CGRectMake(round(_x * s), round(_y * s), round(_w * s), round(_h * s));
	double cx = CGRectGetMidX(base), cy = CGRectGetMidY(base);
	CGRect (^map)(CGRect) = ^CGRect(CGRect r) {
		if (sc == 1)
			return r;
		return CGRectMake(cx + (r.origin.x - cx) * sc, cy + (r.origin.y - cy) * sc, r.size.width * sc, r.size.height * sc);
	};
	CGRect panel = map(base);
	double corner = fmin(radius * s, panel.size.height / 2) * (sc == 1 ? 1 : sc);
	_panel = panel;
	_bounds = shadowed(panel, s);
	// The frame-time graph belongs to the Standard block
	double graphAlpha = [self alpha:block_std now:now reduce:reduce];
	unsigned layers = 0;
	for (int b = block_mini; b <= block_mac; b++) {
		double a = b == block_std ? graphAlpha : [self alpha:b now:now reduce:reduce];
		if (a <= 0 || _texture[b] == nil)
			continue;
		rect_of(_layers.rect[b], map(CGRectMake(base.origin.x, base.origin.y + round(_blockY[b] * s), _texture[b].width,
		                                        _texture[b].height)));
		_layers.alpha[b] = (float)(a * ga);
		layers |= 1u << b;
	}
	surface(quads, &count, panel, corner, s, ga, layers);
	BOOL stale = m->seconds == 0;
	if (graphAlpha > 0 && !stale && [_key[block_std] containsString:@"|live|"]) {
		int n = (int)MIN(m->frame_count, (uint32_t)graph_samples);
		if (n >= 2) {
			double h = graph_height;
			for (int i = 0; i < n; i++) {
				double ms = m->frame_ms_ring[(m->frame_count - (uint32_t)n + (uint32_t)i) % FG_METRICS_FRAMES];
				_graph.y[i] = (float)((h - 1 - fmin(ms, 34) / 34 * (h - 2)) * s);
			}
			const double lines[3] = { 8.3, 16.7, 33.3 };
			for (int g = 0; g < 3; g++)
				_graph.grid[g] = (float)((round(h - 1 - lines[g] / 34 * (h - 2)) + 0.5) * s);
			_graph.count = n;
			_graph.unit = (float)s;
			_graph.width = (float)(1.5 * s);
			CGRect r = map(CGRectMake(base.origin.x + pad_x * s, base.origin.y + round((pad_y + row_height + block_gap) * s),
			                          round((hud_width - 2 * pad_x) * s), round(graph_height * s)));
			Quad *q = add(quads, &count, quad_graph, r, panel, corner);
			if (q != NULL) {
				for (int i = 0; i < 3; i++)
					q->color[i] = green[i];
				q->color[3] = (float)(ga * graphAlpha);
			}
		}
	}
	// The warning capsule under the HUD, above it in a bottom corner
	BOOL warn = _map != NULL && _control.warning[0] != 0 && _control.menu_open == 0 && self.level != FGOverlayOff &&
	            _appearing != -1;
	if (warn && !_warnShown)
		_warnStart = now;
	_warnShown = warn;
	if (warn) {
		[self prepare:block_warn texts:[self texts:block_warn metrics:m] scale:s];
		double wa = reduce ? ease_out((now - _warnStart) / 0.12) : ease_out((now - _warnStart) / 0.24);
		double lift = reduce ? 0 : -4 * (1 - wa);
		double w = _texture[block_warn].width, h = _texture[block_warn].height;
		BOOL left = self.corner == FGOverlayTopLeft || self.corner == FGOverlayBottomLeft;
		BOOL top = self.corner == FGOverlayTopLeft || self.corner == FGOverlayTopRight;
		double x = left ? panel.origin.x : CGRectGetMaxX(panel) - w;
		double y = top ? CGRectGetMaxY(panel) + warn_gap * s : panel.origin.y - warn_gap * s - h;
		CGRect r = CGRectMake(round(x), round(y + lift * s), w, h);
		rect_of(_layers.rect[block_warn], r);
		_layers.alpha[block_warn] = (float)wa;
		surface(quads, &count, r, h / 2, s, wa, 1u << block_warn);
		_bounds = CGRectUnion(_bounds, shadowed(r, s));
	}
	return count;
}

static double rounded_scale(double scale)
{
	return fmin(4, fmax(1, round(scale * 2) / 2));
}

- (double)pixelsPerPoint:(double)scale
{
	int percent = self.sizePercent;
	return rounded_scale(scale) * (percent >= 50 && percent <= 200 ? percent : 100) / 100.0;
}

- (CGRect)clamp:(CGRect)r width:(NSUInteger)width height:(NSUInteger)height
{
	return CGRectIntersection(r, CGRectMake(0, 0, width, height));
}

- (CGRect)panelForWidth:(NSUInteger)width height:(NSUInteger)height scale:(double)scale
{
	double s = [self pixelsPerPoint:scale];
	if (width == _forWidth && height == _forHeight && s == _forScale && !CGRectIsEmpty(_panel))
		return _panel;
	FGOverlayLevel level = self.level;
	if (level == FGOverlayOff)
		return CGRectZero;
	FGMetricsBlock m;
	FGMetricsRead(&m);
	for (int b = block_mini; b <= block_mac; b++)
		if (has(level, b))
			[self prepare:b texts:[self texts:b metrics:&m] scale:s];
	CGSize size = [self sizeFor:level];
	double x, y;
	origin_for(self.corner, width / s, height / s, size.width, size.height, [self topInsetForHeight:height scale:s], &x, &y);
	return CGRectMake(round(x * s), round(y * s), round(size.width * s), round(size.height * s));
}

- (CGRect)boundsForWidth:(NSUInteger)width height:(NSUInteger)height scale:(double)scale
{
	double s = [self pixelsPerPoint:scale];
	if (width == _forWidth && height == _forHeight && s == _forScale && !CGRectIsEmpty(_bounds))
		return [self clamp:_bounds width:width height:height];
	return [self clamp:shadowed([self panelForWidth:width height:height scale:scale], s) width:width height:height];
}

- (void)encodeOnto:(id<MTLTexture>)texture scale:(double)scale commandBuffer:(id<MTLCommandBuffer>)buffer
{
	if (texture == nil)
		return;
	double now = self.testTime > 0 ? self.testTime : CACurrentMediaTime();
	[self readControl:now];
	BOOL reduce = _map != NULL && _control.reduce_motion != 0;
	double s = [self pixelsPerPoint:scale];
	FGMetricsBlock metrics;
	FGMetricsRead(&metrics);
	[self step:now metrics:&metrics width:texture.width height:texture.height scale:s reduce:reduce];
	_forWidth = texture.width;
	_forHeight = texture.height;
	_forScale = s;
	Quad quads[max_quads];
	int count = [self quads:quads now:now metrics:&metrics width:texture.width height:texture.height scale:s reduce:reduce];
	if (count == 0)
		return;
	id<MTLRenderPipelineState> pipeline = [self pipelineFor:texture.pixelFormat];
	if (pipeline == nil)
		return;
	CGRect area = CGRectIntegral([self clamp:_bounds width:texture.width height:texture.height]);
	if (area.size.width < 1 || area.size.height < 1)
		return;
	if (dispatch_semaphore_wait(_free, DISPATCH_TIME_NOW) != 0)
		return;
	MTLScissorRect scissor = { (NSUInteger)area.origin.x, (NSUInteger)area.origin.y, (NSUInteger)area.size.width,
		                       (NSUInteger)area.size.height };
	id<MTLBuffer> vertices = _buffers[_next++ % buffer_count];
	memcpy(vertices.contents, quads, sizeof(Quad) * (size_t)count);

	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	encoder.label = @"cartouche overlay";
	[encoder setRenderPipelineState:pipeline];
	[encoder setScissorRect:scissor];
	float size[2] = { (float)texture.width, (float)texture.height };
	uint32_t linear = linear_format(texture.pixelFormat);
	[encoder setVertexBuffer:vertices offset:0 atIndex:0];
	[encoder setVertexBytes:size length:sizeof(size) atIndex:1];
	for (int b = 0; b < block_count; b++)
		[encoder setFragmentTexture:_texture[b] ?: _blank atIndex:(NSUInteger)b];
	[encoder setFragmentBytes:&linear length:sizeof(linear) atIndex:0];
	[encoder setFragmentBytes:&_graph length:sizeof(_graph) atIndex:1];
	[encoder setFragmentBytes:&_layers length:sizeof(_layers) atIndex:2];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:(NSUInteger)count];
	[encoder endEncoding];
	dispatch_semaphore_t free = _free;
	[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
		(void)done;
		dispatch_semaphore_signal(free);
	}];
}

@end
