// Cartouche Frame Gen Test: two lanes in one window show the same scene, the Cartouche logo
// crossing or a small 3D flight between spinning cubes, at the same speed, the top one as the game renders it, the bottom one through the frame
// generation library. A separate settings window tunes the library live and shows the
// numbers of both lanes: rates, intervals, latency, GPU time, and a graph of shown intervals.
//
//   framegen_test [<logo.svg>]
//
// The library takes the first layer that asks for a drawable, so the bottom lane starts
// first. Its controls go through cartouche_framegen_set, found in the process with dlsym.

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

#import <dlfcn.h>
#import <math.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <time.h>

static _Atomic double rate = 40;
static _Atomic double speed = 960; // logo speed, in points per second
static _Atomic int scene = 1;      // 0 the logo, 1 the 3D flight

static void (*fg_set)(const char *, double);
static double (*fg_get)(const char *);
static int (*fg_intervals)(double *, int);

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

// The logo's distance travelled, shared by both lanes; a speed change starts from where it is
static os_unfair_lock travel_lock = OS_UNFAIR_LOCK_INIT;
static double travel_at, travel_points;

static double travelled(double t)
{
	os_unfair_lock_lock(&travel_lock);
	if (travel_at == 0)
		travel_at = t;
	double points = travel_points + (t - travel_at) * atomic_load(&speed);
	os_unfair_lock_unlock(&travel_lock);
	return points;
}

static void set_speed(double value)
{
	double t = now();
	os_unfair_lock_lock(&travel_lock);
	if (travel_at > 0)
		travel_points += (t - travel_at) * atomic_load(&speed);
	travel_at = t;
	atomic_store(&speed, value);
	os_unfair_lock_unlock(&travel_lock);
}

static void wait_until(double deadline)
{
	double left = deadline - now() - 0.002;
	if (left > 0) {
		struct timespec t = { (time_t)left, (long)((left - (double)(time_t)left) * 1e9) };
		nanosleep(&t, NULL);
	}
	while (now() < deadline) {
	}
}

#import "scene.h"
#import "screen.h"

// The top lane's numbers, measured here from its own presented times
@interface Lane : NSObject {
@public
	os_unfair_lock lock;
	double lastShown, ring[240];
	unsigned ringAt;
	long shown, dropped;
	double latency, latencyMax;
	long latencyCount;
}
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) CATextLayer *label;
@property (nonatomic, strong) id<MTLTexture> depth;
@end

@implementation Lane
- (void)shownAt:(double)time submitted:(double)submitted
{
	os_unfair_lock_lock(&lock);
	if (time <= 0) {
		dropped++;
	} else {
		if (lastShown > 0 && time > lastShown)
			ring[ringAt++ % 240] = (time - lastShown) * 1000;
		lastShown = time;
		shown++;
		if (time > submitted) {
			latency += time - submitted;
			latencyMax = fmax(latencyMax, time - submitted);
			latencyCount++;
		}
	}
	os_unfair_lock_unlock(&lock);
}
@end

static id<MTLDevice> device;
static id<MTLRenderPipelineState> trackPipeline, logoPipeline;
static Scene3DPipes pipes;
static id<MTLTexture> logoTexture;

// A flight between spinning cubes over a checkered floor, with a still logo in the corner as a HUD:
// depth, parallax, rotation and things uncovered every frame, as in a game
static void render3d(Lane *lane, id<MTLCommandQueue> queue, id<CAMetalDrawable> drawable, double t, CGSize size,
                     float scale)
{
	if (lane.depth.width != (NSUInteger)size.width || lane.depth.height != (NSUInteger)size.height) {
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
		                                                                             width:(NSUInteger)size.width
		                                                                            height:(NSUInteger)size.height
		                                                                         mipmapped:NO];
		d.usage = MTLTextureUsageRenderTarget;
		d.storageMode = MTLStorageModePrivate;
		lane.depth = [device newTextureWithDescriptor:d];
	}
	float now3d = (float)fmod(t, 3600), dist = (float)(travelled(t) / 60);
	Scene3D s = { now3d, dist, (float)(size.width / size.height), now3d, dist };
	float logo = (float)size.height * 0.22f;
	Uniforms u = { { (float)size.width, (float)size.height }, 0, logo, scale };

	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = drawable.texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0.11, 0.115, 0.14, 1);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.depthAttachment.texture = lane.depth;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = 1;
	pass.depthAttachment.storeAction = MTLStoreActionDontCare;
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	scene3d_draw(encoder, &pipes, s, u, logoTexture);
	[encoder endEncoding];
	[buffer presentDrawable:drawable];
	[buffer commit];
}

static void render(Lane *lane, id<MTLCommandQueue> queue, double t)
{
	id<CAMetalDrawable> drawable = [lane.layer nextDrawable];
	if (drawable == nil)
		return;
	double submitted = CACurrentMediaTime();
	[drawable addPresentedHandler:^(id<MTLDrawable> d) {
		[lane shownAt:d.presentedTime submitted:submitted];
	}];
	CGSize size = lane.layer.drawableSize;
	float scale = (float)lane.layer.contentsScale;
	float logo = (float)size.height * 0.7f;
	float travel = (float)size.width + logo;
	Uniforms u = { { (float)size.width, (float)size.height },
	               fmodf((float)(travelled(t) * scale), travel) - logo, logo, scale };

	if (atomic_load(&scene) == 1) {
		render3d(lane, queue, drawable, t, size, scale);
		return;
	}
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = drawable.texture;
	pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
	[encoder setRenderPipelineState:trackPipeline];
	[encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[encoder setRenderPipelineState:logoPipeline];
	[encoder setVertexBytes:&u length:sizeof(u) atIndex:0];
	[encoder setFragmentTexture:logoTexture atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[encoder endEncoding];
	[buffer presentDrawable:drawable];
	[buffer commit];
}

// Locked to the chosen rate; the logo's place comes from the shared distance, so both lanes agree
static void run_lane(Lane *lane, void (^first)(void))
{
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
		id<MTLCommandQueue> queue = [device newCommandQueue];
		double next = now();
		BOOL started = NO;
		for (;;) {
			@autoreleasepool {
				render(lane, queue, now());
			}
			// After the first frame only: the main thread must stay free for Core Animation
			if (first != nil && !started) {
				started = YES;
				dispatch_async(dispatch_get_main_queue(), first);
			}
			next += 1.0 / atomic_load(&rate);
			if (next < now())
				next = now();
			wait_until(next);
		}
	});
}

#pragma mark - Interval graph

@interface Graph : NSView
@property (nonatomic, copy) NSArray<NSNumber *> *top, *bottom;
@property (nonatomic) double refresh; // ms
@end

@implementation Graph
- (BOOL)isFlipped { return NO; }

- (void)drawSeries:(NSArray<NSNumber *> *)values color:(NSColor *)color inRect:(NSRect)box scale:(double)top
{
	if (values.count < 2)
		return;
	NSBezierPath *path = [NSBezierPath bezierPath];
	for (NSUInteger i = 0; i < values.count; i++) {
		CGFloat x = NSMinX(box) + NSWidth(box) * (CGFloat)i / 239.0;
		CGFloat y = NSMinY(box) + NSHeight(box) * (CGFloat)fmin(values[i].doubleValue / top, 1);
		if (i == 0)
			[path moveToPoint:NSMakePoint(x, y)];
		else
			[path lineToPoint:NSMakePoint(x, y)];
	}
	path.lineWidth = 1.5;
	[color setStroke];
	[path stroke];
}

- (void)drawPanel:(NSArray<NSNumber *> *)values title:(NSString *)title color:(NSColor *)color inRect:(NSRect)box
{
	[[NSColor colorWithWhite:0.1 alpha:1] setFill];
	NSRectFill(box);
	double top = 50; // ms at the top of the panel
	NSDictionary *small = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],
	                         NSForegroundColorAttributeName: [NSColor colorWithWhite:0.6 alpha:1] };
	// One line per whole refresh: shown intervals can only sit on these
	if (self.refresh > 0)
		for (int k = 1; k * self.refresh < top; k++) {
			CGFloat y = NSMinY(box) + NSHeight(box) * (CGFloat)(k * self.refresh / top);
			[[NSColor colorWithWhite:0.25 alpha:1] setFill];
			NSRectFill(NSMakeRect(NSMinX(box), y, NSWidth(box), 1));
			[[NSString stringWithFormat:@"%.1f", k * self.refresh] drawAtPoint:NSMakePoint(NSMaxX(box) - 30, y + 1)
			                                                    withAttributes:small];
		}
	[self drawSeries:values color:color inRect:box scale:top];
	[title drawAtPoint:NSMakePoint(NSMinX(box) + 6, NSMaxY(box) - 14) withAttributes:small];
}

- (void)drawRect:(NSRect)dirty
{
	(void)dirty;
	NSRect half = NSMakeRect(0, NSHeight(self.bounds) / 2 + 3, NSWidth(self.bounds), NSHeight(self.bounds) / 2 - 3);
	[self drawPanel:self.top title:@"OFF · shown intervals (ms), last 240" color:NSColor.systemTealColor inRect:half];
	half.origin.y = 0;
	[self drawPanel:self.bottom title:@"ON · shown intervals (ms), last 240" color:NSColor.systemOrangeColor inRect:half];
}
@end

#pragma mark - Settings window

@interface Settings : NSObject
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextField *data;
@property (nonatomic, strong) Graph *graph;
@property (nonatomic, strong) NSMutableArray<void (^)(void)> *refreshers;
@property (nonatomic) BOOL follow;
@end

@implementation Settings

static char set_key;

static NSTextField *text(NSString *string, CGFloat size, NSFontWeight weight)
{
	NSTextField *field = [NSTextField labelWithString:string];
	field.font = [NSFont systemFontOfSize:size weight:weight];
	return field;
}

- (NSView *)row:(NSString *)title control:(NSView *)control value:(NSTextField *)value
{
	NSTextField *name = text(title, 12, NSFontWeightRegular);
	[name.widthAnchor constraintEqualToConstant:150].active = YES;
	NSMutableArray *views = [NSMutableArray arrayWithObjects:name, control, nil];
	if (value != nil) {
		value.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
		[value.widthAnchor constraintEqualToConstant:56].active = YES;
		[views addObject:value];
	}
	NSStackView *row = [NSStackView stackViewWithViews:views];
	row.spacing = 8;
	return row;
}

- (NSView *)header:(NSString *)title
{
	NSTextField *field = text(title.uppercaseString, 11, NSFontWeightBold);
	field.textColor = NSColor.secondaryLabelColor;
	return field;
}

// A slider for a library setting or a scene value
- (NSView *)slider:(NSString *)title min:(double)min max:(double)max get:(double (^)(void))get
               set:(void (^)(double))set format:(NSString *)format
{
	NSSlider *slider = [NSSlider sliderWithValue:get() minValue:min maxValue:max target:nil action:nil];
	[slider.widthAnchor constraintEqualToConstant:170].active = YES;
	NSTextField *value = [NSTextField labelWithString:@""];
	void (^show)(void) = ^{
		value.stringValue = [NSString stringWithFormat:format, slider.doubleValue];
	};
	slider.continuous = YES;
	slider.target = self;
	slider.action = @selector(changed:);
	objc_setAssociatedObject(slider, &set_key, ^{ set(slider.doubleValue); show(); }, OBJC_ASSOCIATION_COPY);
	[self.refreshers addObject:^{ slider.doubleValue = get(); show(); }];
	show();
	return [self row:title control:slider value:value];
}

- (NSView *)choice:(NSString *)title items:(NSArray<NSString *> *)items values:(NSArray<NSNumber *> *)values
               key:(const char *)key
{
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[popup addItemsWithTitles:items];
	[popup.widthAnchor constraintEqualToConstant:170].active = YES;
	popup.target = self;
	popup.action = @selector(changed:);
	void (^select)(void) = ^{
		NSUInteger at = [values indexOfObject:@((int)fg_get(key))];
		[popup selectItemAtIndex:at == NSNotFound ? 0 : (NSInteger)at];
	};
	objc_setAssociatedObject(popup, &set_key, ^{ fg_set(key, values[(NSUInteger)popup.indexOfSelectedItem].doubleValue); },
	                         OBJC_ASSOCIATION_COPY);
	[self.refreshers addObject:select];
	select();
	return [self row:title control:popup value:nil];
}

- (NSView *)check:(NSString *)title key:(const char *)key
{
	NSButton *box = [NSButton checkboxWithTitle:@"" target:self action:@selector(changed:)];
	void (^select)(void) = ^{ box.state = fg_get(key) != 0 ? NSControlStateValueOn : NSControlStateValueOff; };
	objc_setAssociatedObject(box, &set_key, ^{ fg_set(key, box.state == NSControlStateValueOn); }, OBJC_ASSOCIATION_COPY);
	[self.refreshers addObject:select];
	select();
	return [self row:title control:box value:nil];
}

- (void)changed:(id)sender
{
	void (^set)(void) = objc_getAssociatedObject(sender, &set_key);
	if (set != nil)
		set();
}

- (void)reset:(id)sender
{
	(void)sender;
	const char *keys[] = { "block", "radius", "factor", "median", "expand", "zero", "mode", "bias", "motion_scale",
	                       "depth", "depth_reversed", "real_delta", "reset_every", "aim", "enabled", "estimator",
	                       "still", "check", "cuts", "downscale" };
	double values[] = { 16, 18, 0, 1, 0, 0, 0, 0.02, 1, 0.5, 0, 1, 0, 0.97, 1, 1, 1, 1, 1, 0 };
	for (size_t i = 0; i < sizeof(values) / sizeof(*values); i++)
		fg_set(keys[i], values[i]);
	for (void (^refresh)(void) in self.refreshers)
		refresh();
}

static double screen_hz(NSWindow *window)
{
	NSScreen *screen = window.screen ?: NSScreen.mainScreen;
	return (double)screen.maximumFramesPerSecond;
}

- (void)halfScreen:(id)sender
{
	(void)sender;
	atomic_store(&rate, fmax(20, screen_hz(self.panel) / 2));
	for (void (^refresh)(void) in self.refreshers)
		refresh();
}

- (void)followChanged:(NSButton *)box
{
	self.follow = box.state == NSControlStateValueOn;
	if (self.follow)
		[self halfScreen:nil];
}

- (instancetype)initBeside:(NSWindow *)main
{
	if ((self = [super init]) == nil)
		return nil;
	_refreshers = [NSMutableArray new];
	_follow = YES;
	NSMutableArray<NSView *> *rows = [NSMutableArray new];

	[rows addObject:[self header:@"Scene"]];
	NSPopUpButton *sceneMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[sceneMenu addItemsWithTitles:@[ @"Logo crossing", @"3D flight" ]];
	[sceneMenu.widthAnchor constraintEqualToConstant:170].active = YES;
	[sceneMenu selectItemAtIndex:atomic_load(&scene)];
	sceneMenu.target = self;
	sceneMenu.action = @selector(changed:);
	objc_setAssociatedObject(sceneMenu, &set_key, ^{ atomic_store(&scene, (int)sceneMenu.indexOfSelectedItem); },
	                         OBJC_ASSOCIATION_COPY);
	[rows addObject:[self row:@"Scene" control:sceneMenu value:nil]];
	[rows addObject:[self slider:@"Game rate (fps)" min:20 max:120 get:^double { return atomic_load(&rate); }
	                         set:^(double v) { atomic_store(&rate, round(v)); } format:@"%.0f"]];
	NSButton *follow = [NSButton checkboxWithTitle:@"Follow the screen: rate = refresh / 2" target:self
	                                        action:@selector(followChanged:)];
	follow.state = NSControlStateValueOn;
	[rows addObject:[self row:@"" control:follow value:nil]];
	[rows addObject:[self slider:@"Logo speed (pt/s)" min:120 max:3000 get:^double { return atomic_load(&speed); }
	                         set:^(double v) { set_speed(round(v)); } format:@"%.0f"]];

	[rows addObject:[self header:@"Frame generation"]];
	[rows addObject:[self check:@"Enabled" key:"enabled"]];
	[rows addObject:[self choice:@"Output" items:@[ @"MetalFX interpolation", @"50 % blend", @"Previous frame again",
	                                               @"Motion vectors view" ]
	                      values:@[ @0, @1, @2, @3 ] key:"mode"]];
	[rows addObject:[self slider:@"Pacing aim (× half)" min:0.8 max:1.05 get:^double { return fg_get("aim"); }
	                         set:^(double v) { fg_set("aim", v); } format:@"%.2f"]];

	[rows addObject:[self header:@"Motion estimation"]];
	[rows addObject:[self check:@"No motion at all" key:"zero"]];
	[rows addObject:[self choice:@"Estimator" items:@[ @"Block matching", @"Pyramid" ] values:@[ @0, @1 ] key:"estimator"]];
	[rows addObject:[self check:@"Both ways check" key:"check"]];
	[rows addObject:[self check:@"Still pixels stay" key:"still"]];
	[rows addObject:[self check:@"Scene cut detection" key:"cuts"]];
	[rows addObject:[self choice:@"Analysis size" items:@[ @"Automatic", @"Full", @"Half", @"Quarter" ] values:@[ @0, @1, @2, @4 ]
	                         key:"factor"]];
	[rows addObject:[self choice:@"Block size" items:@[ @"4 px", @"8 px", @"16 px" ] values:@[ @4, @8, @16 ] key:"block"]];
	[rows addObject:[self slider:@"Search radius (px)" min:2 max:31 get:^double { return fg_get("radius"); }
	                         set:^(double v) { fg_set("radius", round(v)); } format:@"%.0f"]];
	[rows addObject:[self slider:@"Stillness bias" min:0 max:1 get:^double { return fg_get("bias"); }
	                         set:^(double v) { fg_set("bias", v); } format:@"%.3f"]];
	[rows addObject:[self check:@"Median over blocks" key:"median"]];
	[rows addObject:[self choice:@"Per-pixel vectors" items:@[ @"Bilinear", @"Nearest block", @"Refined per pixel" ]
	                      values:@[ @0, @1, @2 ] key:"expand"]];

	[rows addObject:[self header:@"MetalFX inputs"]];
	[rows addObject:[self choice:@"Interpolation size" items:@[ @"Automatic", @"Full", @"Half" ] values:@[ @0, @1, @2 ]
	                         key:"downscale"]];
	[rows addObject:[self slider:@"Vector scale" min:-2 max:2 get:^double { return fg_get("motion_scale"); }
	                         set:^(double v) { fg_set("motion_scale", v); } format:@"%+.2f"]];
	[rows addObject:[self slider:@"Constant depth" min:0 max:1 get:^double { return fg_get("depth"); }
	                         set:^(double v) { fg_set("depth", v); } format:@"%.2f"]];
	[rows addObject:[self check:@"Reversed depth" key:"depth_reversed"]];
	[rows addObject:[self check:@"Real delta time" key:"real_delta"]];
	[rows addObject:[self check:@"Reset history each frame" key:"reset_every"]];

	NSButton *reset = [NSButton buttonWithTitle:@"Reset to defaults" target:self action:@selector(reset:)];
	NSButton *half = [NSButton buttonWithTitle:@"Rate = refresh / 2" target:self action:@selector(halfScreen:)];
	[rows addObject:[NSStackView stackViewWithViews:@[ reset, half ]]];

	[rows addObject:[self header:@"Live data"]];
	_data = [NSTextField wrappingLabelWithString:@""];
	_data.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
	[_data.widthAnchor constraintEqualToConstant:400].active = YES;
	[rows addObject:_data];
	_graph = [[Graph alloc] initWithFrame:NSMakeRect(0, 0, 400, 220)];
	[_graph.widthAnchor constraintEqualToConstant:400].active = YES;
	[_graph.heightAnchor constraintEqualToConstant:220].active = YES;
	[rows addObject:_graph];

	NSStackView *stack = [NSStackView stackViewWithViews:rows];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment = NSLayoutAttributeLeading;
	stack.spacing = 6;
	stack.edgeInsets = NSEdgeInsetsMake(14, 16, 14, 16);
	// Right edge of the lanes' screen, above everything, so the lanes never hide it
	NSRect visible = main.screen.visibleFrame;
	_panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(NSMaxX(visible) - 452, NSMinY(visible) + 8, 440,
	                                                         NSHeight(visible) - 40)
	                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskUtilityWindow
	                                      backing:NSBackingStoreBuffered
	                                        defer:NO];
	_panel.title = @"Cartouche Frame Gen Test — settings";
	_panel.floatingPanel = YES;
	_panel.level = NSFloatingWindowLevel;
	_panel.hidesOnDeactivate = NO;
	_panel.contentView = stack;
	[_panel orderFrontRegardless];
	return self;
}
@end

#pragma mark - Main

static CATextLayer *label(CGFloat scale)
{
	CATextLayer *text = [CATextLayer layer];
	text.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold];
	text.fontSize = 15;
	text.foregroundColor = NSColor.whiteColor.CGColor;
	text.contentsScale = scale;
	return text;
}

static NSArray<NSNumber *> *numbers(const double *values, int count)
{
	NSMutableArray *out = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
	for (int i = 0; i < count; i++)
		[out addObject:@(values[i])];
	return out;
}

static double deviation(NSArray<NSNumber *> *values, double *mean)
{
	double sum = 0, squares = 0;
	for (NSNumber *v in values) {
		sum += v.doubleValue;
		squares += v.doubleValue * v.doubleValue;
	}
	double n = (double)values.count;
	*mean = n > 0 ? sum / n : 0;
	return n > 0 ? sqrt(fmax(0, squares / n - *mean * *mean)) : 0;
}

// Held for the process lifetime, see main
static id activity;

int main(int argc, char **argv)
{
	NSString *logoPath = argc > 1 ? @(argv[1]) : @"mockup/brand/cartouche-icon-default.svg";
	fg_set = (void (*)(const char *, double))dlsym(RTLD_DEFAULT, "cartouche_framegen_set");
	fg_get = (double (*)(const char *))dlsym(RTLD_DEFAULT, "cartouche_framegen_get");
	fg_intervals = (int (*)(double *, int))dlsym(RTLD_DEFAULT, "cartouche_framegen_intervals");
	if (fg_set == NULL || fg_get == NULL || fg_intervals == NULL) {
		fprintf(stderr, "the frame generation library is not loaded: run it with make framegen-test\n");
		return 2;
	}

	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
		// An app in the background gets App Nap and coalesced timers, which slow its frames
		activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
		                                                        reason:@"framegen test"];
		device = MTLCreateSystemDefaultDevice();

		NSError *error = nil;
		id<MTLLibrary> library = [device newLibraryWithSource:shaders options:nil error:&error];
		MTLRenderPipelineDescriptor *describe = [MTLRenderPipelineDescriptor new];
		describe.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		describe.vertexFunction = [library newFunctionWithName:@"track"];
		describe.fragmentFunction = [library newFunctionWithName:@"track_f"];
		trackPipeline = [device newRenderPipelineStateWithDescriptor:describe error:&error];
		describe.vertexFunction = [library newFunctionWithName:@"logo"];
		describe.fragmentFunction = [library newFunctionWithName:@"logo_f"];
		describe.colorAttachments[0].blendingEnabled = YES;
		describe.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
		describe.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		logoPipeline = [device newRenderPipelineStateWithDescriptor:describe error:&error];
		BOOL built = scene3d_build(device, library, &pipes, &error);
		if (trackPipeline == nil || logoPipeline == nil || !built) {
			fprintf(stderr, "shaders: %s\n", error.localizedDescription.UTF8String);
			return 3;
		}
		NSImage *image = [[NSImage alloc] initWithContentsOfFile:logoPath];
		CGImageRef cg = [image CGImageForProposedRect:&(NSRect){ { 0, 0 }, { 512, 512 } } context:nil hints:nil];
		if (cg == NULL) {
			fprintf(stderr, "logo: cannot read %s\n", logoPath.UTF8String);
			return 3;
		}
		logoTexture = [[[MTKTextureLoader alloc] initWithDevice:device]
			newTextureWithCGImage:cg options:@{ MTKTextureLoaderOptionSRGB: @NO } error:&error];

		// On the test screen, left of the settings
		NSRect visible = test_screen().visibleFrame;
		const CGFloat width = fmin(1280, NSWidth(visible) - 460), laneHeight = 300, gap = 40;
		NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, 2 * (laneHeight + gap))
		                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
		                                                 backing:NSBackingStoreBuffered
		                                                   defer:NO];
		window.title = @"Cartouche Frame Gen Test";
		NSView *view = window.contentView;
		view.wantsLayer = YES;
		view.layer.backgroundColor = [NSColor colorWithWhite:0.06 alpha:1].CGColor;
		CGFloat scale = window.backingScaleFactor;

		NSArray<Lane *> *lanes = @[ [Lane new], [Lane new] ];
		for (int i = 0; i < 2; i++) {
			Lane *lane = lanes[i];
			lane->lock = OS_UNFAIR_LOCK_INIT;
			CGFloat y = i == 0 ? laneHeight + gap : 0;
			lane.layer = [CAMetalLayer layer];
			lane.layer.device = device;
			lane.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
			lane.layer.contentsScale = scale;
			lane.layer.frame = CGRectMake(0, y, width, laneHeight);
			lane.layer.drawableSize = CGSizeMake(width * scale, laneHeight * scale);
			[view.layer addSublayer:lane.layer];
			lane.label = label(scale);
			lane.label.frame = CGRectMake(14, y + laneHeight + 10, width - 28, 22);
			[view.layer addSublayer:lane.label];
		}
		place_test_window(window, 460);
		Settings *settings = [[Settings alloc] initBeside:window];
		atomic_store(&rate, fmax(20, screen_hz(window) / 2));
		for (void (^refresh)(void) in settings.refreshers)
			refresh();

		// Bottom lane first, so the library takes it
		run_lane(lanes[1], ^{
			run_lane(lanes[0], nil);
		});

		__block long lastShown = 0;
		__block double lastHz = 0;
		[NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
			(void)timer;
			Lane *top = lanes[0];
			os_unfair_lock_lock(&top->lock);
			long shown = top->shown, dropped = top->dropped;
			unsigned count = top->ringAt < 240 ? top->ringAt : 240;
			double topRing[240];
			for (unsigned i = 0; i < count; i++)
				topRing[i] = top->ring[(top->ringAt - count + i) % 240];
			double latency = top->latencyCount ? top->latency / (double)top->latencyCount * 1000 : 0;
			double latencyMax = top->latencyMax * 1000;
			top->latency = top->latencyMax = 0;
			top->latencyCount = 0;
			os_unfair_lock_unlock(&top->lock);

			double hz = screen_hz(window);
			if (settings.follow && hz != lastHz) {
				atomic_store(&rate, fmax(20, hz / 2));
				for (void (^refresh)(void) in settings.refreshers)
					refresh();
			}
			lastHz = hz;

			double bottomRing[240];
			int bottomCount = fg_intervals(bottomRing, 240);
			NSArray *topValues = numbers(topRing, (int)count), *bottomValues = numbers(bottomRing, bottomCount);
			double topMean, topSd = deviation(topValues, &topMean);

			double render = fg_get("render_fps"), shownOn = fg_get("shown_fps");
			NSString *state = fg_get("active") == 0 ? @"disabled" : fg_get("paused") != 0 ? @"paused"
			                : fg_get("enabled") == 0 ? @"off (switch)" : @"on";
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			top.label.string = [NSString stringWithFormat:@"FRAME GEN OFF   %ld fps shown   interval %.1f ± %.1f ms   latency %.1f ms",
			                    shown - lastShown, topMean, topSd, latency];
			lanes[1].label.string = [NSString stringWithFormat:@"FRAME GEN %@   %.0f → %.0f fps   interval %.1f ± %.1f ms   latency %.1f ms   GPU %.1f ms",
			                         state.uppercaseString, render, shownOn, fg_get("interval_ms"), fg_get("interval_sd_ms"),
			                         fg_get("latency_ms"), fg_get("gpu_ms")];
			[CATransaction commit];

			double refresh = hz > 0 ? 1000 / hz : fg_get("refresh_hz") > 0 ? 1000 / fg_get("refresh_hz") : 0;
			settings.data.stringValue = [NSString stringWithFormat:
				@"Screen          %.0f Hz (%.2f ms)   library sees %.0f Hz, measured %.0f Hz\n"
				 "Game rate       %.0f fps target   speed %.0f pt/s   %.1f pt per real frame\n"
				 "\n"
				 "OFF lane        %ld fps shown   %ld dropped in total\n"
				 "                interval %.2f ± %.2f ms   latency %.1f ms (max %.1f)\n"
				 "\n"
				 "ON lane         %@   %.1f fps rendered → %.1f fps shown\n"
				 "                interval %.2f ± %.2f ms  (half a refresh: %.2f ms)\n"
				 "                latency %.1f ms (max %.1f)   real frame held, then shown\n"
				 "                GPU %.2f ms (max %.2f) per generated frame\n"
				 "                generated %.0f   dropped %.0f in total",
				hz, refresh, fg_get("screen_hz"), fg_get("refresh_hz"),
				atomic_load(&rate), atomic_load(&speed), atomic_load(&speed) / atomic_load(&rate),
				shown - lastShown, dropped, topMean, topSd, latency, latencyMax,
				state, render, shownOn, fg_get("interval_ms"), fg_get("interval_sd_ms"), refresh / 2,
				fg_get("latency_ms"), fg_get("latency_max_ms"), fg_get("gpu_ms"), fg_get("gpu_max_ms"),
				fg_get("generated"), fg_get("dropped")];
			settings.graph.top = topValues;
			settings.graph.bottom = bottomValues;
			settings.graph.refresh = refresh;
			settings.graph.needsDisplay = YES;
			lastShown = shown;
		}];
		[NSApp run];
	}
	return 0;
}
