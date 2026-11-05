// Frame generation for Windows games (spike). Loaded with DYLD_INSERT_LIBRARIES when
// CARTOUCHE_FRAMEGEN=1. The game's presents are held back: a present thread waits for
// each real frame to finish on the GPU, makes the frame between it and the previous one,
// and presents both, half a real-frame interval apart. Any failure turns the library
// into a pass-through for the rest of the session.
//
// CARTOUCHE_FRAMEGEN_INTERPOLATE=0, what Cartouche's launches set: no frame is generated. The
// library keeps the temporal scaler's chain, and takes the presents only to draw the HUD or
// count frames, without pacing, gating or copying them.
//
// Log lines go to stderr, prefixed "framegen:". With CARTOUCHE_FRAMEGEN_STATS=1, one CSV
// row per second goes to CARTOUCHE_FRAMEGEN_DIR (or /tmp). The test window tunes it live
// and reads its numbers through cartouche_framegen_set, _get and _intervals.

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import <dlfcn.h>
#import <fcntl.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <unistd.h>

#import "fg_ane.h"
#import "fg_metrics.h"
#import "fg_overlay.h"
#import "fg_pipeline.h"
#import "fg_temporal.h"
#import "fg_upscale.h"

#if defined(__x86_64__)
#define framegen_arch "x86_64"
#elif defined(__arm64__)
#define framegen_arch "arm64"
#else
#define framegen_arch "other"
#endif

enum { state_off, state_active, state_disabled };

static _Atomic int state = state_off;
static double watchdog = 0.1;
static char stats_dir[PATH_MAX];
static int stats_fd = -1;
static BOOL stats_wanted;
static void open_stats(void);
static const char *failure_point;
// Tests only (CARTOUCHE_FRAMEGEN_PROBE_LOG): when each generated frame was shown and its centre
// pixel, for the latency bench
static int probe_fd = -1;
// CARTOUCHE_FRAMEGEN_PROBE_AT=overlay: the probe reads a pixel inside the overlay's panel instead
// of the centre, before the overlay on generated frames and after it on every shown frame
static BOOL probe_overlay;

static id (*next_next_drawable)(id, SEL);
static void (*next_buffer_present)(id, SEL, id);
static void (*next_buffer_present_after)(id, SEL, id, CFTimeInterval);
static void (*next_buffer_present_at)(id, SEL, id, CFTimeInterval);
static void (*next_drawable_present)(id, SEL);
static void (*next_drawable_present_after)(id, SEL, CFTimeInterval);
static void (*next_drawable_present_at)(id, SEL, CFTimeInterval);
static void (*next_signal_drawable)(id, SEL, id);

static char own_key, signal_key;
// Tests only, see CARTOUCHE_FRAMEGEN_FRONT
static id front_activity;

// Tests only: the Mac's own screen, as the user works on the others; CARTOUCHE_FRAMEGEN_SCREEN=external
// picks another, main the one with the menu bar (as tests/screen.h)
static NSScreen *front_screen(void)
{
	const char *pick = getenv("CARTOUCHE_FRAMEGEN_SCREEN");
	NSArray<NSScreen *> *screens = NSScreen.screens;
	if (pick == NULL || strcmp(pick, "main") != 0) {
		BOOL builtin = pick == NULL || strcmp(pick, "external") != 0;
		for (NSScreen *screen in screens)
			if ((CGDisplayIsBuiltin([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]) != 0) == builtin)
				return screen;
	}
	return screens.firstObject;
}

// Live tuning and the last whole second's numbers, shared with the test window
static os_unfair_lock tuning_lock = OS_UNFAIR_LOCK_INIT;
static FGSettings tuning;
static double tuning_aim = 0.97;
// follow: aim follows the measured latency instead of the fixed value; cushion: the latency it
// holds above half an interval
static int tuning_follow = 1;
static double tuning_cushion = 0.001;
// The Neural Engine's flow (CARTOUCHE_FRAMEGEN_ANE=1 for RIFE lean, fg1 for Cartouche FG 1), and
// how long a frame waits for it before falling back to the GPU estimate
static int tuning_ane = 1;
static double tuning_ane_wait = 0.006;
static int tuning_enabled = 1;
static BOOL interpolate = YES;
// The limiter: the game's rate held at most this many fps, -1 for half the display's refresh, 0 off
static double tuning_limit = 0;
static _Atomic unsigned tuning_version;
static struct {
	double render, shown, gpu, gpu_max, interval, deviation, refresh_hz, screen_hz, latency, latency_max;
	double paused, generated, dropped;
} snapshot;
static double ring[240];
static unsigned ring_at;

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void say(const char *format, ...)
{
	char line[512];
	va_list args;
	va_start(args, format);
	int len = vsnprintf(line, sizeof(line) - 1, format, args);
	va_end(args);
	if (len < 0)
		return;
	if ((size_t)len > sizeof(line) - 2)
		len = (int)sizeof(line) - 2;
	line[len++] = '\n';
	(void)!write(STDERR_FILENO, "framegen: ", 10);
	(void)!write(STDERR_FILENO, line, (size_t)len);
}

// Drawables the present thread hands back to Metal go straight through the hooks
static BOOL owned(id drawable)
{
	return objc_getAssociatedObject(drawable, &own_key) != nil;
}

static void own(id drawable)
{
	objc_setAssociatedObject(drawable, &own_key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static const char *backend_name(void)
{
	for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
		const char *name = _dyld_get_image_name(i);
		if (name == NULL)
			continue;
		if (strstr(name, "D3DMetal.framework") != NULL)
			return "D3DMetal";
		if (strstr(name, "winemetal") != NULL)
			return "DXMT";
	}
	return NULL;
}

static id<MTLTexture> engine_motion(float *scale, unsigned long *seen);
// The FFX proxy's vectors, matched to the real frame by the game's frame number (fg_proxy.m)
uint64_t FGProxyTag(void);
BOOL FGProxyActive(void);
BOOL FGProxyGameGenerates(void);
id<MTLTexture> FGProxyMotion(uint64_t tag, float *scale);
void FGProxyDone(id<MTLTexture> motion);
void FGProxyUseDevice(id<MTLDevice> device);

API_AVAILABLE(macos(26.0))
@interface FGFrame : NSObject
@property (nonatomic, strong) id<CAMetalDrawable> drawable;
@property (nonatomic) uint64_t signal;
@property (nonatomic) double arrival;
@property (nonatomic) double hostArrival;
@property (nonatomic) uint64_t tag;
// The game's own timing for the present: a minimum duration, or a host time; 0 for none
@property (nonatomic) double minimum, at;
@end

@implementation FGFrame
@end

API_AVAILABLE(macos(26.0))
@interface FGPresenter : NSObject
@end

@implementation FGPresenter {
	CAMetalLayer *_layer;
	id<MTLCommandQueue> _queue;
	id<MTLSharedEvent> _event;
	_Atomic uint64_t _signalled;
	FGPipeline *_pipeline;
	NSCondition *_condition;
	NSMutableArray<FGFrame *> *_pending;
	// The game takes a drawable only once its previous frame is on its way: the layer has
	// three, one for the held real frame, one for the generated frame, one for the game
	dispatch_semaphore_t _gate;
	double _lastArrival, _interval;
	// Real frames' latency to the screen, smoothed, for the rate lock
	double _lag;
	// The game's motion copies already used, so a stale one is not used twice
	unsigned long _engineSeen;
	// The Neural Engine helper, the input slot the next frame goes to, whether the other slot holds
	// the frame before, and per second: frames it served, frames it missed, its time
	FGNeural *_neural;
	int _aneSlot;
	BOOL _aneFilled;
	unsigned _aneUsed, _aneMissed;
	double _aneMillis;
	// The display's refresh period, the shortest gap seen between two shown frames, and how
	// far the shown frames run behind the evenly spaced ones
	double _refresh, _debt;
	BOOL _paused;
	unsigned _stalls;
	double _slowSince, _fastSince;
	// Why generation is paused, told again when it changes: a game that starts slow and then runs
	// too fast for the display stays paused for the second reason
	const char *_pauseReason;
	// Per second, for the stats file and the pause rule. Presented-handler and completion
	// threads add to them, so they sit behind the lock.
	os_unfair_lock _lock;
	double _second;
	unsigned _real, _shown;
	double _gpu, _gpuMax, _confidence, _replaced;
	unsigned _gpuCount;
	double _lastShown, _sum, _sumSquares;
	unsigned _intervals;
	double _latency, _latencyMax;
	unsigned _latencyCount;
	unsigned long _generated, _dropped;
	// Pacing diagnostics per second: shown intervals by whole refreshes (1, 2, 3, 4 or more),
	// frames never shown, and the longest waits for a drawable on our side and the game's
	unsigned _byRefresh[4], _droppedSecond;
	double _generatedWaitMax, _admitWaitMax;
	// The limiter's next slot for the game, on its own thread
	double _slot;
	// The refresh period of the screen the game's window is on, from AppKit
	double _screenRefresh;
	unsigned _appliedVersion;
	id<MTLBuffer> _probe;
	unsigned _probeAt;
	// CARTOUCHE_FRAMEGEN_UPSCALE: frames shown at the screen's size in a layer of ours
	FGUpscale *_upscale;
	// CARTOUCHE_OVERLAY, and the sizes our upscale went from and to in this second
	FGOverlay *_overlay;
	BOOL _upscaled;
	unsigned _upscaleSizes[4];
}

API_AVAILABLE(macos(26.0)) static FGPresenter *presenter;

- (instancetype)initWithLayer:(CAMetalLayer *)layer
{
	if ((self = [super init]) == nil)
		return nil;
	_layer = layer;
	_condition = [NSCondition new];
	_lock = OS_UNFAIR_LOCK_INIT;
	_pending = [NSMutableArray new];
	_gate = dispatch_semaphore_create(1);
	return self;
}

- (CAMetalLayer *)layer { return _layer; }

// The HUD only draws on the frames; generation, upscaling and the probe read them too
- (BOOL)readsDrawables { return interpolate || _upscale != nil || _probe != nil; }

// A wait longer than the watchdog means the game dropped a drawable without presenting it
- (void)admit
{
	double start = now();
	dispatch_semaphore_wait(_gate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(watchdog * 2 * NSEC_PER_SEC)));
	double waited = now() - start;
	os_unfair_lock_lock(&_lock);
	_admitWaitMax = fmax(_admitWaitMax, waited);
	os_unfair_lock_unlock(&_lock);
}

// In the game's thread, before it takes a drawable: no sooner than one period after the last
// one, so it renders at a steady rate and no real frame waits in a queue. A game late for its
// slot goes at once, and the grid starts again from there.
- (void)limit
{
	os_unfair_lock_lock(&tuning_lock);
	double fps = tuning_limit;
	int enabled = tuning_enabled;
	os_unfair_lock_unlock(&tuning_lock);
	if (fps < 0) {
		double refresh = [self refresh];
		fps = refresh > 0 ? 1 / (refresh * 2) : 0;
	}
	if (fps <= 0 || !enabled) {
		_slot = 0;
		return;
	}
	double t = now();
	_slot = fmax(_slot + 1 / fps, t);
	// Sleep to a millisecond before the slot, then spin: a sleep can wake late
	if (_slot - t > 0.0015) {
		double sleep = _slot - t - 0.001;
		struct timespec ts = { (time_t)sleep, (long)((sleep - floor(sleep)) * 1e9) };
		nanosleep(&ts, NULL);
	}
	while (now() < _slot)
		;
}

- (BOOL)start
{
	id<MTLDevice> device = _layer.device ?: MTLCreateSystemDefaultDevice();
	if (device == nil || (interpolate && ![FGPipeline supportsDevice:device])) {
		say("unsupported device %s", device != nil ? device.name.UTF8String : "(none)");
		return NO;
	}
	if (interpolate) {
		NSString *error = nil;
		_pipeline = [[FGPipeline alloc] initWithDevice:device error:&error];
		if (_pipeline == nil) {
			say("disabled %s", error.UTF8String);
			return NO;
		}
		if (failure_point != NULL && strcmp(failure_point, "kernels") == 0) {
			say("disabled forced failure: kernels");
			return NO;
		}
	}
	_queue = [device newCommandQueue];
	_event = [device newSharedEvent];
	if (probe_fd >= 0)
		_probe = [device newBufferWithLength:128 * 4 options:MTLResourceStorageModeShared];
	if (interpolate)
		_layer.maximumDrawableCount = 3;
	_upscale = [FGUpscale upscaleForLayer:_layer device:device];
	_overlay = [FGOverlay overlayFromEnvironment:device log:say];
	const char *metrics = getenv("CARTOUCHE_METRICS");
	if (_overlay != nil || (metrics != NULL && strcmp(metrics, "1") == 0)) {
		FGMetricsStart(YES);
		if (FGMetricsName()[0] != 0)
			say("metrics %s", FGMetricsName());
	}
	FGProxyUseDevice(device);
	[NSThread detachNewThreadSelector:@selector(run) toTarget:self withObject:nil];
	CGSize size = _layer.drawableSize;
	const char *backend = backend_name();
	// Only the process that presents frames gets a CSV, not every helper Wine starts
	if (stats_wanted && stats_fd < 0)
		open_stats();
	say("active backend=%s size=%.0fx%.0f arch=%s", backend ? backend : "unknown", size.width, size.height,
	    framegen_arch);
	const char *ane = interpolate ? getenv("CARTOUCHE_FRAMEGEN_ANE") : NULL;
	if (ane != NULL && strcmp(ane, "1") == 0)
		[self startNeural:device model:@"framegen-flow.mlmodelc"];
	else if (ane != NULL && (strcmp(ane, "fg1") == 0 || strcmp(ane, "a6") == 0))
		[self startNeural:device model:@"framegen-flow-fg1.mlmodelc"];
	// Tests only: a game started from a terminal stays behind other windows, where macOS drops
	// its frames. Its window floats above them in the test screen's bottom-right corner, without
	// taking the focus or clicks, and the process stays out of App Nap, which slows a background
	// app's frames.
	const char *front = getenv("CARTOUCHE_FRAMEGEN_FRONT");
	if (front != NULL && strcmp(front, "1") == 0) {
		front_activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
		                                                              reason:@"framegen test"];
		CALayer *layer = _layer;
		dispatch_async(dispatch_get_main_queue(), ^{
			for (CALayer *at = layer; at != nil; at = at.superlayer)
				if ([at.delegate isKindOfClass:[NSView class]]) {
					NSWindow *window = ((NSView *)at.delegate).window;
					NSRect visible = front_screen().visibleFrame;
					window.level = NSFloatingWindowLevel;
					window.ignoresMouseEvents = YES;
					[window setFrameOrigin:NSMakePoint(NSMaxX(visible) - NSWidth(window.frame), NSMinY(visible))];
					[window orderFrontRegardless];
					break;
				}
		});
	}
	return YES;
}

// The helper and the network sit next to this library unless the variables say otherwise; the
// model loads in the background and the GPU estimate serves until it is ready
- (void)startNeural:(id<MTLDevice>)device model:(NSString *)name
{
	Dl_info info;
	NSString *dir = dladdr((const void *)now, &info) && info.dli_fname
		? [@(info.dli_fname) stringByDeletingLastPathComponent] : @".";
	const char *helper = getenv("CARTOUCHE_FRAMEGEN_ANE_HELPER"), *model = getenv("CARTOUCHE_FRAMEGEN_ANE_MODEL");
	NSString *helperPath = helper ? @(helper) : [dir stringByAppendingPathComponent:@"framegen-ane"];
	NSString *modelPath = model ? @(model) : [dir stringByAppendingPathComponent:name];
	__unsafe_unretained FGPresenter *target = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSString *error = nil;
		FGNeural *neural = [FGNeural startWithDevice:device helper:helperPath model:modelPath error:&error];
		if (neural == nil) {
			say("ane unavailable: %s", error.UTF8String);
			return;
		}
		[target takeNeural:neural];
		say("ane helper started");
	});
}

- (void)takeNeural:(FGNeural *)neural
{
	os_unfair_lock_lock(&_lock);
	_neural = neural;
	os_unfair_lock_unlock(&_lock);
}

// From the game's MTL4 queue: a value on our event once its work on the drawable is done
- (void)signalled:(id)queue drawable:(id)drawable
{
	uint64_t value = atomic_fetch_add(&_signalled, 1) + 1;
	((void (*)(id, SEL, id, uint64_t))objc_msgSend)(queue, @selector(signalEvent:value:), _event, value);
	objc_setAssociatedObject(drawable, &signal_key, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// tag: FGProxyTag() taken when the game presented, before it could submit the next frame
- (void)queueFrame:(id<CAMetalDrawable>)drawable signal:(uint64_t)signal tag:(uint64_t)tag minimum:(double)minimum
                at:(double)at
{
	FGFrame *frame = [FGFrame new];
	frame.drawable = drawable;
	frame.signal = signal;
	frame.minimum = minimum;
	frame.at = at;
	frame.arrival = now();
	frame.hostArrival = CACurrentMediaTime();
	frame.tag = tag;
	[_condition lock];
	[_pending addObject:frame];
	[_condition signal];
	[_condition unlock];
}

- (void)disable:(const char *)reason
{
	int expected = state_active;
	if (atomic_compare_exchange_strong(&state, &expected, state_disabled)) {
		FGUpscaleStopAll();
		say("disabled %s", reason);
	}
}

// arrival is the host time the game presented a real frame, 0 for a generated one
- (void)present:(id<CAMetalDrawable>)drawable buffer:(id<MTLCommandBuffer>)buffer after:(double)duration
        arrival:(double)arrival
{
	[self present:drawable buffer:buffer after:duration at:0 arrival:arrival];
}

- (void)present:(id<CAMetalDrawable>)drawable buffer:(id<MTLCommandBuffer>)buffer after:(double)duration
             at:(double)time arrival:(double)arrival
{
	own(drawable);
	// Upscaled, the game's frame still goes to its own layer, under ours
	id<CAMetalDrawable> shown = _upscale != nil && drawable.layer == _layer
		? [_upscale drawableFrom:drawable.texture commandBuffer:buffer] : nil;
	if (shown != nil) {
		_upscaled = YES;
		_upscaleSizes[0] = (unsigned)drawable.texture.width;
		_upscaleSizes[1] = (unsigned)drawable.texture.height;
		_upscaleSizes[2] = (unsigned)shown.texture.width;
		_upscaleSizes[3] = (unsigned)shown.texture.height;
		next_buffer_present(buffer, @selector(presentDrawable:), drawable);
		drawable = shown;
		own(drawable);
	}
	// The overlay goes last, on the frame as shown: the pipeline copied the real one before
	if (_overlay != nil) {
		id<MTLTexture> texture = drawable.texture;
		CGFloat points = drawable.layer.bounds.size.width;
		[_overlay encodeOnto:texture scale:points > 0 ? texture.width / points : 1 commandBuffer:buffer];
		if (_probe != nil && probe_overlay && !texture.framebufferOnly)
			[self probe:texture buffer:buffer drawable:drawable label:arrival > 0 ? "overlay real" : "overlay generated"
			     offset:64];
	}
	if (arrival > 0)
		FGDumpShown(drawable.texture, buffer);
	if (arrival > 0 && FGMetricsRunning())
		[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
			FGMetricsPresentGPU((done.GPUEndTime - done.GPUStartTime) * 1000);
		}];
	__unsafe_unretained FGPresenter *target = self;
	[drawable addPresentedHandler:^(id<MTLDrawable> shown) {
		[target noteShownAt:shown.presentedTime arrival:arrival];
	}];
	if (time > 0)
		next_buffer_present_at(buffer, @selector(presentDrawable:atTime:), drawable, time);
	else if (duration > 0)
		next_buffer_present_after(buffer, @selector(presentDrawable:afterMinimumDuration:), drawable, duration);
	else
		next_buffer_present(buffer, @selector(presentDrawable:), drawable);
}

// The pixel the latency probe reads: the centre, or inside the overlay's panel, left of the text
- (MTLOrigin)probePointIn:(id<MTLTexture>)texture
{
	if (probe_overlay && _overlay != nil) {
		CGFloat points = _layer.bounds.size.width;
		double scale = fmin(4, fmax(1, round((points > 0 ? texture.width / points : 1) * 2) / 2));
		CGRect panel = [_overlay panelForWidth:texture.width height:texture.height scale:scale];
		return MTLOriginMake((NSUInteger)(panel.origin.x + round(4 * scale)), (NSUInteger)CGRectGetMidY(panel), 0);
	}
	return MTLOriginMake(texture.width / 2, texture.height / 2, 0);
}

// Copies the probe pixel of texture and logs it with label once the drawable is shown
- (void)probe:(id<MTLTexture>)texture buffer:(id<MTLCommandBuffer>)buffer drawable:(id<CAMetalDrawable>)drawable
        label:(const char *)label offset:(NSUInteger)offset
{
	NSUInteger slot = offset + _probeAt++ % 64;
	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	[blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:[self probePointIn:texture]
	           sourceSize:MTLSizeMake(1, 1, 1) toBuffer:_probe destinationOffset:slot * 4 destinationBytesPerRow:4
	destinationBytesPerImage:4];
	[blit endEncoding];
	id<MTLBuffer> probe = _probe;
	[drawable addPresentedHandler:^(id<MTLDrawable> shown) {
		const uint8_t *p = (const uint8_t *)probe.contents + slot * 4;
		char line[96];
		int len = snprintf(line, sizeof(line), "%s %.6f %u %u %u\n", label, shown.presentedTime, p[2], p[1], p[0]);
		(void)!write(probe_fd, line, (size_t)len);
	}];
}

// A minimum duration on a present rounds up to whole refreshes, so each frame asks for a
// whole number of them, and what one frame gains or loses against half a real interval is
// carried to the next. The aim is 97 % of half: pacing that ran even slightly slower than
// the game would hold its next drawable back, the measured interval would grow, and the
// rate would spiral down. Until the refresh period is known, a frame waits 90 % of half.
- (double)refresh
{
	os_unfair_lock_lock(&_lock);
	double refresh = _screenRefresh > 0 ? _screenRefresh : _refresh;
	os_unfair_lock_unlock(&_lock);
	return refresh;
}

// The screen can change when the window moves, so it is asked again every second
- (void)watchScreen
{
	__unsafe_unretained FGPresenter *target = self;
	CALayer *layer = _layer;
	dispatch_async(dispatch_get_main_queue(), ^{
		NSView *view = nil;
		for (CALayer *at = layer; at != nil && view == nil; at = at.superlayer)
			if ([at.delegate isKindOfClass:[NSView class]])
				view = (NSView *)at.delegate;
		NSScreen *screen = view.window.screen ?: NSScreen.mainScreen;
		NSInteger fps = screen.maximumFramesPerSecond;
		[target noteScreen:fps > 0 ? 1.0 / (double)fps : 0];
	});
}

- (void)noteScreen:(double)period
{
	os_unfair_lock_lock(&_lock);
	_screenRefresh = period;
	os_unfair_lock_unlock(&_lock);
}

- (double)gap
{
	os_unfair_lock_lock(&tuning_lock);
	double aim = tuning_aim, cushion = tuning_cushion;
	int follow = tuning_follow;
	os_unfair_lock_unlock(&tuning_lock);
	if (follow) {
		// Frames waiting to be shown pile up when the pacing runs slower than the game, and run
		// out when it runs faster: hold the latency steady and the rates match
		os_unfair_lock_lock(&_lock);
		double lag = _lag;
		os_unfair_lock_unlock(&_lock);
		if (lag > 0 && _interval > 0)
			aim = fmax(0.9, fmin(1.05, 1 + 0.5 * (_interval / 2 + cushion - lag) / _interval));
	}
	double half = _interval / 2 * aim;
	double refresh = [self refresh];
	if (refresh <= 0)
		return _interval / 2 * 0.9;
	double target = half + _debt;
	double count = fmax(1, round(target / refresh));
	_debt = fmax(-half, fmin(half, target - count * refresh));
	return (count - 0.5) * refresh;
}

- (void)noteShownAt:(double)time arrival:(double)arrival
{
	os_unfair_lock_lock(&_lock);
	if (time <= 0) {
		_dropped++;
		_droppedSecond++;
		os_unfair_lock_unlock(&_lock);
		return;
	}
	if (arrival > 0 && time > arrival) {
		double latency = time - arrival;
		_latency += latency;
		_latencyCount++;
		_latencyMax = fmax(_latencyMax, latency);
		_lag = _lag > 0 ? _lag * 0.9 + latency * 0.1 : latency;
	}
	double step = time - _lastShown;
	if (_lastShown > 0 && step > 0.003 && step < 0.034 && (_refresh <= 0 || step < _refresh))
		_refresh = step;
	if (_lastShown > 0 && time > _lastShown) {
		double gap = time - _lastShown;
		_sum += gap;
		_sumSquares += gap * gap;
		_intervals++;
		double refresh = _screenRefresh > 0 ? _screenRefresh : _refresh;
		if (refresh > 0)
			_byRefresh[MIN(3, MAX(1, (int)lround(gap / refresh)) - 1)]++;
		os_unfair_lock_lock(&tuning_lock);
		ring[ring_at++ % 240] = gap * 1000;
		os_unfair_lock_unlock(&tuning_lock);
		FGMetricsShown(gap * 1000);
	}
	_lastShown = time;
	_shown++;
	os_unfair_lock_unlock(&_lock);
}

- (void)writeSecond:(double)at
{
	if (_second == 0) {
		_second = at;
		return;
	}
	if (at - _second < 1.0)
		return;
	double span = at - _second;
	double rate = _real / span;
	// The pause rule, over 2 s either way: under 30 fps MetalFX has too little to work
	// from, and when twice the rate does not fit the display, the doubled frames would hold
	// the game back to half the refresh rate
	[self watchScreen];
	double refresh = [self refresh];
	// 29 rather than 30: a game locked at 30 measures 29.9 in some seconds
	const char *reason = !interpolate ? NULL : rate < 29 ? "base <30 fps"
		: refresh > 0 && rate * 2 * refresh > 1.1 ? "display too slow" : NULL;
	if (reason != NULL) {
		_fastSince = 0;
		if (_slowSince == 0)
			_slowSince = _second;
		if (!_paused && at - _slowSince >= 2) {
			_paused = YES;
			_pauseReason = reason;
			say("paused (%s)", reason);
		} else if (_paused && reason != _pauseReason) {
			_pauseReason = reason;
			say("paused (%s)", reason);
		}
	} else {
		_slowSince = 0;
		if (_fastSince == 0)
			_fastSince = _second;
		if (_paused && at - _fastSince >= 2) {
			_paused = NO;
			[_pipeline reset];
			say("resumed");
		}
	}
	os_unfair_lock_lock(&_lock);
	if (stats_fd >= 0) {
		double mean = _intervals ? _sum / _intervals : 0;
		double deviation = _intervals ? sqrt(fmax(0, _sumSquares / _intervals - mean * mean)) : 0;
		// On a fixed refresh, an output period of n + f refreshes cannot vary less than
		// refresh * sqrt(f(1 - f)); intervals longer than n + 1 refreshes are real hitches
		double period = rate > 0 ? 1 / (rate * (_paused ? 1 : 2)) : 0, least = 0;
		unsigned longer = 0;
		if (refresh > 0 && period > 0) {
			double count = period / refresh, f = count - floor(count);
			least = refresh * sqrt(f * (1 - f));
			for (int k = (int)ceil(count - 1e-6); k < 4; k++)
				longer += _byRefresh[k];
		}
		char line[360];
		int len = snprintf(line, sizeof(line), "%ld,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%u,%.2f,%u,%u,%u,%u,%u,%.2f,%.2f,%.2f,%.3f,%.2f,%.1f,%.2f\n",
		                   (long)time(NULL), rate, _shown / span, _gpuCount ? _gpu / _gpuCount : 0, _gpuMax, mean * 1000,
		                   deviation * 1000, refresh * 1000, _paused ? 1 : 0, _droppedSecond, least * 1000, longer,
		                   _byRefresh[0], _byRefresh[1], _byRefresh[2], _byRefresh[3], _generatedWaitMax * 1000,
		                   _admitWaitMax * 1000, _latencyCount ? _latency / _latencyCount * 1000 : 0,
		                   _gpuCount ? _confidence / _gpuCount : 0, _gpuCount ? _replaced / _gpuCount * 100 : 0,
		                   _aneUsed + _aneMissed ? 100.0 * _aneUsed / (_aneUsed + _aneMissed) : 0,
		                   _aneUsed ? _aneMillis / _aneUsed : 0);
		(void)!write(stats_fd, line, (size_t)len);
	}
	FGMetricsSecond second = {
		.presentedFps = _shown / span,
		.realFps = rate,
		.frameMs = _intervals ? _sum / _intervals * 1000 : 0,
		.framegenGpuMs = _gpuCount ? _gpu / _gpuCount : 0,
		.latencyMs = _latencyCount ? _latency / _latencyCount * 1000 : 0,
		.latencyMaxMs = _latencyMax * 1000,
		.refreshMs = refresh * 1000,
		.generated = _generated,
		.dropped = _dropped,
		.droppedSecond = _droppedSecond,
		.ane = _aneUsed > 0,
	};
	memset(_byRefresh, 0, sizeof(_byRefresh));
	_droppedSecond = 0;
	_generatedWaitMax = _admitWaitMax = 0;
	double mean = _intervals ? _sum / _intervals : 0;
	os_unfair_lock_lock(&tuning_lock);
	snapshot.render = rate;
	snapshot.shown = _shown / span;
	snapshot.gpu = _gpuCount ? _gpu / _gpuCount : 0;
	snapshot.gpu_max = _gpuMax;
	snapshot.interval = mean * 1000;
	snapshot.deviation = _intervals ? sqrt(fmax(0, _sumSquares / _intervals - mean * mean)) * 1000 : 0;
	snapshot.refresh_hz = _refresh > 0 ? 1 / _refresh : 0;
	snapshot.screen_hz = _screenRefresh > 0 ? 1 / _screenRefresh : 0;
	snapshot.latency = _latencyCount ? _latency / _latencyCount * 1000 : 0;
	snapshot.latency_max = _latencyMax * 1000;
	snapshot.paused = _paused;
	snapshot.generated = (double)_generated;
	snapshot.dropped = (double)_dropped;
	os_unfair_lock_unlock(&tuning_lock);
	_latency = _latencyMax = 0;
	_latencyCount = 0;
	_second = at;
	_real = _shown = _gpuCount = _intervals = 0;
	_gpu = _gpuMax = _sum = _sumSquares = _confidence = _replaced = _aneMillis = 0;
	_aneUsed = _aneMissed = 0;
	os_unfair_lock_unlock(&_lock);
	if (FGMetricsRunning())
		[self noteMetrics:&second];
}

- (void)noteMetrics:(FGMetricsSecond *)second
{
	os_unfair_lock_lock(&tuning_lock);
	int enabled = tuning_enabled;
	os_unfair_lock_unlock(&tuning_lock);
	second->factor = 2;
	if (atomic_load(&state) != state_active || !enabled)
		second->framegen = FG_FRAMEGEN_OFF;
	else if (FGProxyGameGenerates())
		second->framegen = FG_FRAMEGEN_GAME;
	else if (_paused) {
		second->framegen = FG_FRAMEGEN_PAUSED;
		second->pauseReason = _pauseReason != NULL && strcmp(_pauseReason, "base <30 fps") == 0 ? FG_PAUSE_SLOW_BASE
		                                                                                       : FG_PAUSE_SLOW_DISPLAY;
	} else
		second->framegen = FG_FRAMEGEN_ON;
	FGMetricsSecondDone(second);
	id scaler = FGTemporalScaler();
	unsigned long encoded = FGTemporalTakeEncodes();
	if (_upscaled)
		FGMetricsUpscale(FG_UPSCALE_SPATIAL, _upscaleSizes[0], _upscaleSizes[1], _upscaleSizes[2], _upscaleSizes[3]);
	else if (scaler != nil && encoded > 0 && [scaler respondsToSelector:@selector(outputHeight)]) {
		NSUInteger (*size)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
		FGMetricsUpscale(FG_UPSCALE_TEMPORAL, (unsigned)size(scaler, @selector(inputWidth)),
		                 (unsigned)size(scaler, @selector(inputHeight)), (unsigned)size(scaler, @selector(outputWidth)),
		                 (unsigned)size(scaler, @selector(outputHeight)));
	}
	else
		FGMetricsUpscale(FG_UPSCALE_NONE, 0, 0, 0, 0);
	_upscaled = NO;
}

- (void)run
{
	pthread_setname_np("cartouche framegen");
	for (;;) {
		FGFrame *frame;
		@autoreleasepool {
			[_condition lock];
			while (_pending.count == 0)
				[_condition wait];
			frame = _pending.firstObject;
			[_pending removeObjectAtIndex:0];
			[_condition unlock];
			[self show:frame];
			if (interpolate)
				dispatch_semaphore_signal(_gate);
		}
	}
}

- (void)show:(FGFrame *)frame
{
	id<CAMetalDrawable> real = frame.drawable;
	id<MTLCommandBuffer> buffer = [_queue commandBuffer];
	if (frame.signal != 0)
		[buffer encodeWaitForEvent:_event value:frame.signal];

	double gap = _lastArrival > 0 ? frame.arrival - _lastArrival : 0;
	_lastArrival = frame.arrival;
	if (gap > 0 && gap < 0.5) {
		_interval = _interval > 0 ? _interval * 0.9 + gap * 0.1 : gap;
		FGMetricsReal(gap * 1000);
	}
	_real++;
	[self writeSecond:frame.arrival];

	double arrival = frame.hostArrival;
	if (!interpolate) {
		[self present:real buffer:buffer after:frame.minimum at:frame.at arrival:arrival];
		[buffer commit];
		return;
	}
	if (atomic_load(&state) != state_active) {
		[self present:real buffer:buffer after:0 arrival:arrival];
		[buffer commit];
		return;
	}

	unsigned version = atomic_load(&tuning_version);
	if (version != _appliedVersion) {
		os_unfair_lock_lock(&tuning_lock);
		FGSettings settings = tuning;
		os_unfair_lock_unlock(&tuning_lock);
		NSString *error = nil;
		if (![_pipeline useSettings:settings error:&error])
			say("tuning refused: %s", error.UTF8String);
		_appliedVersion = version;
	}
	os_unfair_lock_lock(&tuning_lock);
	int enabled = tuning_enabled;
	os_unfair_lock_unlock(&tuning_lock);

	id<MTLTexture> texture = real.texture;
	if (texture.width != _pipeline.width || texture.height != _pipeline.height ||
	    texture.pixelFormat != _pipeline.format) {
		NSString *error = nil;
		BOOL first = _pipeline.width == 0;
		if (![_pipeline prepareWidth:texture.width height:texture.height format:texture.pixelFormat error:&error]) {
			[self disable:error.UTF8String];
			[self present:real buffer:buffer after:0 arrival:arrival];
			[buffer commit];
			return;
		}
		if (!first)
			say("resized %lux%lu", (unsigned long)texture.width, (unsigned long)texture.height);
	}

	BOOL had = [_pipeline encodeCapture:texture commandBuffer:buffer];
	if (!had || _paused || !enabled || _interval <= 0 || FGProxyGameGenerates()) {
		_aneFilled = NO;
		[self present:real buffer:buffer after:0 arrival:arrival];
		[buffer commit];
		return;
	}

	// The Neural Engine's flow: this frame goes to its slot, and the helper works on it and the
	// frame before while this thread waits, up to the budget; past it the GPU estimate serves
	os_unfair_lock_lock(&_lock);
	FGNeural *neural = _neural;
	os_unfair_lock_unlock(&_lock);
	os_unfair_lock_lock(&tuning_lock);
	BOOL useNeural = tuning_ane != 0;
	double budget = tuning_ane_wait;
	os_unfair_lock_unlock(&tuning_lock);
	BOOL served = NO;
	if (neural != nil && neural.ready && useNeural) {
		int slot = _aneSlot;
		_aneSlot ^= 1;
		[_pipeline encodeNeuralInput:texture into:[neural inputForSlot:slot] commandBuffer:buffer];
		[buffer commit];
		[buffer waitUntilCompleted];
		buffer = [_queue commandBuffer];
		if (_aneFilled) {
			[neural requestEarlier:slot ^ 1];
			served = [neural waitFor:budget];
			os_unfair_lock_lock(&_lock);
			if (served) {
				_aneUsed++;
				_aneMillis += neural.lastMillis;
			} else
				_aneMissed++;
			os_unfair_lock_unlock(&_lock);
		}
		_aneFilled = YES;
		static BOOL told;
		if (served && !told) {
			told = YES;
			say("ane flow in use");
		}
	}
	_pipeline.neuralFlow = served ? neural.flow : nil;
	_pipeline.neuralMask = served ? neural.mask : nil;
	float scale = 1;
	BOOL proxied = FGProxyActive();
	id<MTLTexture> engine = proxied ? FGProxyMotion(frame.tag, &scale) : engine_motion(&scale, &_engineSeen);
	if (engine != nil && _pipeline.engineMotion == nil && _pipeline.settings.engine)
		say("engine motion in use %lux%lu", (unsigned long)engine.width, (unsigned long)engine.height);
	_pipeline.engineMotion = engine;
	_pipeline.engineMotionScale = scale;
	[_pipeline encodeFrame:buffer deltaTime:(float)_interval];
	if (proxied && engine != nil)
		[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
			(void)done;
			FGProxyDone(engine);
		}];
	// The interpolation starts on the GPU now; waiting for a drawable overlaps it instead of
	// holding it back. The presents follow in a second buffer on the same queue.
	__unsafe_unretained FGPresenter *weak = self;
	FGPipeline *pipeline = _pipeline;
	[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
		double confidence = 0, replaced = 0;
		[pipeline repairConfidence:&confidence replaced:&replaced];
		[weak noteGPU:(done.GPUEndTime - done.GPUStartTime) * 1000 confidence:confidence replaced:replaced];
	}];
	[buffer commit];
	buffer = [_queue commandBuffer];
	double asked = now();
	BOOL ours = NO;
	id<CAMetalDrawable> generated = [_upscale nextDrawableFor:_pipeline.output fits:&ours];
	if (!ours)
		generated = next_next_drawable(_layer, @selector(nextDrawable));
	os_unfair_lock_lock(&_lock);
	_generatedWaitMax = fmax(_generatedWaitMax, now() - asked);
	os_unfair_lock_unlock(&_lock);
	BOOL forced = failure_point != NULL && strcmp(failure_point, "drawable") == 0 && _shown > 30;
	BOOL late = generated == nil || now() - asked > watchdog;
	_stalls = late ? _stalls + 1 : 0;
	// One late drawable happens while the window appears or changes screen; three in a row is a stall
	if (_stalls >= 3 || forced) {
		[self disable:forced ? "forced failure: drawable" : "no drawable within 100 ms"];
	}
	if (late || forced) {
		if (generated != nil)
			own(generated);
		[_pipeline reset];
		[self present:real buffer:buffer after:0 arrival:arrival];
		[buffer commit];
		return;
	}
	BOOL upscaled = generated.layer != _layer;
	if (upscaled)
		[_upscale encode:_pipeline.output into:generated commandBuffer:buffer];
	id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
	if (!upscaled)
		[blit copyFromTexture:_pipeline.output toTexture:generated.texture];
	if (_probe != nil) {
		NSUInteger slot = _probeAt++ % 64;
		[blit copyFromTexture:_pipeline.output sourceSlice:0 sourceLevel:0
		         sourceOrigin:[self probePointIn:_pipeline.output] sourceSize:MTLSizeMake(1, 1, 1)
		             toBuffer:_probe destinationOffset:slot * 4 destinationBytesPerRow:4 destinationBytesPerImage:4];
		id<MTLBuffer> probe = _probe;
		[generated addPresentedHandler:^(id<MTLDrawable> shown) {
			const uint8_t *p = (const uint8_t *)probe.contents + slot * 4;
			char line[96];
			int len = snprintf(line, sizeof(line), "generated %.6f %u %u %u\n", shown.presentedTime, p[2], p[1], p[0]);
			(void)!write(probe_fd, line, (size_t)len);
		}];
	}
	[blit endEncoding];

	[self present:generated buffer:buffer after:[self gap] arrival:0];
	[self present:real buffer:buffer after:[self gap] arrival:arrival];
	os_unfair_lock_lock(&_lock);
	_generated++;
	os_unfair_lock_unlock(&_lock);
	[buffer commit];
}

- (void)noteGPU:(double)ms confidence:(double)confidence replaced:(double)replaced
{
	os_unfair_lock_lock(&_lock);
	_confidence += confidence;
	_replaced += replaced;
	os_unfair_lock_unlock(&_lock);
	[self noteGPU:ms];
}

- (void)noteGPU:(double)ms
{
	os_unfair_lock_lock(&_lock);
	_gpu += ms;
	_gpuCount++;
	if (ms > _gpuMax)
		_gpuMax = ms;
	os_unfair_lock_unlock(&_lock);
}

@end

static BOOL takes(id drawable)
{
	if (@available(macOS 26.0, *)) {
		return atomic_load(&state) == state_active && presenter != nil && drawable != nil && !owned(drawable) &&
		       [drawable respondsToSelector:@selector(layer)] && ((id<CAMetalDrawable>)drawable).layer == presenter.layer;
	}
	return NO;
}

static id hook_next_drawable(id layer, SEL selector)
{
	if (@available(macOS 26.0, *)) {
		if (atomic_load(&state) == state_active) {
			if (presenter == nil) {
				static dispatch_once_t once;
				dispatch_once(&once, ^{
					if (backend_name() == NULL) {
						say("unsupported backend");
						atomic_store(&state, state_disabled);
						return;
					}
					FGPresenter *candidate = [[FGPresenter alloc] initWithLayer:layer];
					if ([candidate start])
						presenter = candidate;
					else
						atomic_store(&state, state_disabled);
				});
			}
			if (presenter != nil && presenter.layer == layer && [presenter readsDrawables]) {
				// Our blits read the game's drawables and write the generated ones
				if (((CAMetalLayer *)layer).framebufferOnly)
					((CAMetalLayer *)layer).framebufferOnly = NO;
			}
			if (presenter != nil && presenter.layer == layer && interpolate) {
				[presenter limit];
				[presenter admit];
			}
		}
	}
	return next_next_drawable(layer, selector);
}

static void take_from_buffer(id buffer, id drawable, double minimum, double at)
{
	if (@available(macOS 26.0, *)) {
		FGPresenter *target = presenter;
		uint64_t tag = FGProxyTag();
		[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
			(void)done;
			[target queueFrame:drawable signal:0 tag:tag minimum:minimum at:at];
		}];
	}
}

static void hook_buffer_present(id buffer, SEL selector, id drawable)
{
	if (!takes(drawable))
		return next_buffer_present(buffer, selector, drawable);
	take_from_buffer(buffer, drawable, 0, 0);
}

static void hook_buffer_present_after(id buffer, SEL selector, id drawable, CFTimeInterval duration)
{
	if (!takes(drawable))
		return next_buffer_present_after(buffer, selector, drawable, duration);
	take_from_buffer(buffer, drawable, duration, 0);
}

static void hook_buffer_present_at(id buffer, SEL selector, id drawable, CFTimeInterval time)
{
	if (!takes(drawable))
		return next_buffer_present_at(buffer, selector, drawable, time);
	take_from_buffer(buffer, drawable, 0, time);
}

static void take_direct(id drawable, double minimum, double at)
{
	if (@available(macOS 26.0, *)) {
		NSNumber *signal = objc_getAssociatedObject(drawable, &signal_key);
		[presenter queueFrame:drawable signal:signal.unsignedLongLongValue tag:FGProxyTag() minimum:minimum at:at];
	}
}

static void hook_drawable_present(id drawable, SEL selector)
{
	if (!takes(drawable))
		return next_drawable_present(drawable, selector);
	take_direct(drawable, 0, 0);
}

static void hook_drawable_present_after(id drawable, SEL selector, CFTimeInterval duration)
{
	if (!takes(drawable))
		return next_drawable_present_after(drawable, selector, duration);
	take_direct(drawable, duration, 0);
}

static void hook_drawable_present_at(id drawable, SEL selector, CFTimeInterval time)
{
	if (!takes(drawable))
		return next_drawable_present_at(drawable, selector, time);
	take_direct(drawable, 0, time);
}

static BOOL replace(const char *class_name, SEL selector, IMP hook, void *previous);

// Level 1: a game whose upscaler goes through MetalFX (DLSS on DXMT or D3DMetal) hands it the
// depth and motion it rendered. At each encode, the motion is copied in the same command buffer,
// into one of two textures in turn; the copy the game's GPU has finished is the one to use.
// A Metal 4 scaler (MTL4FX) encodes into an MTL4 command buffer: there the copy needs our
// residency set and a queue barrier, and is finished once the queue that commits it signals.
static id (*next_new_scaler)(id, SEL, id);
static id (*next_new_scaler4)(id, SEL, id, id);
static id (*next_new_interpolator)(id, SEL, id);
static id (*next_new_interpolator4)(id, SEL, id, id);
static void (*next_commit4)(id, SEL, const __unsafe_unretained id *, NSUInteger);
static void (*next_commit4_options)(id, SEL, const __unsafe_unretained id *, NSUInteger, id);
static struct {
	Method method;
	IMP next;
} scaler_encoders[4];
static os_unfair_lock engine_lock = OS_UNFAIR_LOCK_INIT;
static id<MTLTexture> engine_copies[2];
static _Atomic int engine_ready = -1;
static _Atomic unsigned long engine_frames;
static float engine_scale = 1;
static int engine_next;
// MTL4 only: the set holding both copies, the event the committing queue signals, and the
// command buffer whose copy waits for its commit
static id engine_residency;
static BOOL engine_residency_stale;
static id<MTLSharedEvent> engine_event;
static MTLSharedEventListener *engine_listener;
static uint64_t engine_signalled;
static void *_Atomic engine_pending;
static int engine_pending_slot;

API_AVAILABLE(macos(26.0))
static void copy_motion4(id<MTL4CommandBuffer> buffer, id<MTLTexture> motion, id<MTLTexture> copy, int slot)
{
	os_unfair_lock_lock(&engine_lock);
	if (engine_residency == nil) {
		engine_residency = [motion.device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
		engine_event = [motion.device newSharedEvent];
		engine_listener = [MTLSharedEventListener new];
		engine_residency_stale = YES;
	}
	id<MTLResidencySet> set = engine_residency;
	if (set != nil && engine_residency_stale) {
		[set removeAllAllocations];
		for (int i = 0; i < 2; i++)
			if (engine_copies[i] != nil)
				[set addAllocation:engine_copies[i]];
		[set commit];
		engine_residency_stale = NO;
	}
	os_unfair_lock_unlock(&engine_lock);
	if (set == nil)
		return;
	[buffer useResidencySet:set];
	id<MTL4ComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
	[encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
	[encoder copyFromTexture:motion toTexture:copy];
	[encoder endEncoding];
	os_unfair_lock_lock(&engine_lock);
	engine_pending_slot = slot;
	atomic_store(&engine_pending, (__bridge void *)buffer);
	os_unfair_lock_unlock(&engine_lock);
}

static void hook_scaler_encode(id scaler, SEL selector, id buffer)
{
	Method method = class_getInstanceMethod(object_getClass(scaler), selector);
	IMP next = NULL;
	for (int i = 0; i < 4 && next == NULL; i++)
		if (scaler_encoders[i].method == method)
			next = scaler_encoders[i].next;
	if (next == NULL)
		return;
	// MetalFX clears reset once encoded
	float jx = ((float (*)(id, SEL))objc_msgSend)(scaler, @selector(jitterOffsetX));
	float jy = ((float (*)(id, SEL))objc_msgSend)(scaler, @selector(jitterOffsetY));
	BOOL reset = ((BOOL (*)(id, SEL))objc_msgSend)(scaler, @selector(reset));
	if (FGTemporalIsOwn(scaler)) {
		((void (*)(id, SEL, id))next)(scaler, selector, buffer);
		return;
	}
	FGTemporalEncode(scaler, selector, buffer, next);
	id<MTLTexture> motion = ((id (*)(id, SEL))objc_msgSend)(scaler, @selector(motionTexture));
	if (motion == nil || atomic_load(&state) != state_active)
		return;
	BOOL mtl4 = NO;
	if (@available(macOS 26.0, *))
		mtl4 = [buffer conformsToProtocol:@protocol(MTL4CommandBuffer)];
	float scale = ((float (*)(id, SEL))objc_msgSend)(scaler, @selector(motionVectorScaleX));
	os_unfair_lock_lock(&engine_lock);
	int slot = engine_next;
	engine_next ^= 1;
	id<MTLTexture> copy = engine_copies[slot];
	if (copy == nil || copy.width != motion.width || copy.height != motion.height || copy.pixelFormat != motion.pixelFormat) {
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:motion.pixelFormat
		                                                                             width:motion.width
		                                                                            height:motion.height
		                                                                         mipmapped:NO];
		d.usage = MTLTextureUsageShaderRead;
		d.storageMode = MTLStorageModePrivate;
		copy = engine_copies[slot] = [motion.device newTextureWithDescriptor:d];
		engine_residency_stale = YES;
	}
	engine_scale = scale != 0 ? scale : 1;
	os_unfair_lock_unlock(&engine_lock);
	if (atomic_fetch_add(&engine_frames, 1) == 0) {
		id<MTLTexture> depth = ((id (*)(id, SEL))objc_msgSend)(scaler, @selector(depthTexture));
		id<MTLTexture> color = ((id (*)(id, SEL))objc_msgSend)(scaler, @selector(colorTexture));
		id<MTLTexture> output = ((id (*)(id, SEL))objc_msgSend)(scaler, @selector(outputTexture));
		say("engine data scaler=%s color=%lux%lu output=%lux%lu depth=%lux%lu motion=%lux%lu format=%lu scale=%.2f "
		    "jitter=%.2f,%.2f reset=%d mtl4=%d",
		    class_getName(object_getClass(scaler)), (unsigned long)color.width, (unsigned long)color.height,
		    (unsigned long)output.width, (unsigned long)output.height, (unsigned long)depth.width,
		    (unsigned long)depth.height, (unsigned long)motion.width, (unsigned long)motion.height,
		    (unsigned long)motion.pixelFormat, scale, jx, jy, reset, mtl4);
	}
	if (!interpolate)
		return;
	if (mtl4) {
		if (@available(macOS 26.0, *))
			copy_motion4(buffer, motion, copy, slot);
		return;
	}
	id<MTLBlitCommandEncoder> blit = [(id<MTLCommandBuffer>)buffer blitCommandEncoder];
	[blit copyFromTexture:motion toTexture:copy];
	[blit endEncoding];
	[(id<MTLCommandBuffer>)buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
		(void)done;
		atomic_store(&engine_ready, slot);
	}];
}

// One hook serves every scaler class; each class's own encode is kept in scaler_encoders
static void hook_encoder(id scaler)
{
	Method method = class_getInstanceMethod(object_getClass(scaler), @selector(encodeToCommandBuffer:));
	if (method == NULL)
		return;
	os_unfair_lock_lock(&engine_lock);
	BOOL known = NO;
	int at = -1;
	for (int i = 0; i < 4; i++) {
		known |= scaler_encoders[i].method == method;
		if (at < 0 && scaler_encoders[i].method == NULL)
			at = i;
	}
	if (!known && at >= 0) {
		scaler_encoders[at].next = method_getImplementation(method);
		scaler_encoders[at].method = method;
		method_setImplementation(method, (IMP)hook_scaler_encode);
	}
	os_unfair_lock_unlock(&engine_lock);
	if (!known && at < 0)
		say("engine data unavailable: %s", class_getName(object_getClass(scaler)));
}

static id hook_new_scaler(id descriptor, SEL selector, id device)
{
	if (FGTemporalClaim(nil)) {
		id own = next_new_scaler(descriptor, selector, device);
		FGTemporalClaim(own);
		return own;
	}
	FGTemporalTune(descriptor);
	id scaler = next_new_scaler(descriptor, selector, device);
	if (scaler != nil)
		hook_encoder(scaler);
	FGTemporalAdopt(scaler, device);
	return scaler;
}

// The MTL4 copy is done once the queue that commits its command buffer passes our event
static void engine_committed(id queue, const __unsafe_unretained id *buffers, NSUInteger count)
{
	void *pending = atomic_load(&engine_pending);
	if (pending == NULL)
		return;
	for (NSUInteger i = 0; i < count; i++) {
		if ((__bridge void *)buffers[i] != pending)
			continue;
		os_unfair_lock_lock(&engine_lock);
		BOOL mine = atomic_compare_exchange_strong(&engine_pending, &pending, NULL);
		int slot = engine_pending_slot;
		uint64_t value = ++engine_signalled;
		id<MTLSharedEvent> event = engine_event;
		os_unfair_lock_unlock(&engine_lock);
		if (!mine)
			return;
		((void (*)(id, SEL, id, uint64_t))objc_msgSend)(queue, @selector(signalEvent:value:), event, value);
		[event notifyListener:engine_listener
		              atValue:value
		                block:^(id<MTLSharedEvent> e, uint64_t v) {
			                (void)e;
			                (void)v;
			                atomic_store(&engine_ready, slot);
		                }];
		return;
	}
}

static void hook_commit4(id queue, SEL selector, const __unsafe_unretained id *buffers, NSUInteger count)
{
	next_commit4(queue, selector, buffers, count);
	engine_committed(queue, buffers, count);
}

static void hook_commit4_options(id queue, SEL selector, const __unsafe_unretained id *buffers, NSUInteger count,
                                 id options)
{
	next_commit4_options(queue, selector, buffers, count, options);
	engine_committed(queue, buffers, count);
}

// The device's MTL4 queue class overrides commit, so the hook goes on that class, not on _MTL4CommandQueue
static id hook_new_scaler4(id descriptor, SEL selector, id device, id compiler)
{
	if (FGTemporalClaim(nil)) {
		id own = next_new_scaler4(descriptor, selector, device, compiler);
		FGTemporalClaim(own);
		return own;
	}
	if (FGTemporalMetal4())
		FGTemporalTune(descriptor);
	id scaler = next_new_scaler4(descriptor, selector, device, compiler);
	if (scaler == nil)
		return scaler;
	hook_encoder(scaler);
	FGTemporalAdopt(scaler, device);
	if (!interpolate)
		return scaler;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		id queue = ((id (*)(id, SEL))objc_msgSend)(device, sel_registerName("newMTL4CommandQueue"));
		const char *name = queue != nil ? class_getName(object_getClass(queue)) : "";
		if (!replace(name, sel_registerName("commit:count:"), (IMP)hook_commit4, &next_commit4) ||
		    !replace(name, sel_registerName("commit:count:options:"), (IMP)hook_commit4_options, &next_commit4_options))
			say("engine data unavailable: %s", name);
	});
	return scaler;
}

// The runner making its own interpolator means it generates frames already: ours stands down
static void runner_interpolates(void)
{
	if (interpolate && atomic_load(&FGCreatingInterpolator) == 0) {
		int expected = state_active;
		if (atomic_compare_exchange_strong(&state, &expected, state_disabled)) {
			FGUpscaleStopAll();
			say("disabled runner-fg");
		}
	}
}

static id hook_new_interpolator(id descriptor, SEL selector, id device)
{
	runner_interpolates();
	return next_new_interpolator(descriptor, selector, device);
}

static id hook_new_interpolator4(id descriptor, SEL selector, id device, id compiler)
{
	runner_interpolates();
	return next_new_interpolator4(descriptor, selector, device, compiler);
}

// The latest finished copy of the game's motion, or nil when the game sent none lately
static id<MTLTexture> engine_motion(float *scale, unsigned long *seen)
{
	unsigned long frames = atomic_load(&engine_frames);
	int ready = atomic_load(&engine_ready);
	if (ready < 0 || frames == *seen)
		return nil;
	*seen = frames;
	os_unfair_lock_lock(&engine_lock);
	id<MTLTexture> copy = engine_copies[ready];
	*scale = engine_scale;
	os_unfair_lock_unlock(&engine_lock);
	return copy;
}

static void watch_metalfx(const struct mach_header *header, intptr_t slide)
{
	(void)header;
	(void)slide;
	static _Atomic int scaler_hooked, interpolator_hooked;
	if (atomic_load(&scaler_hooked) == 0 && objc_getClass("MTLFXTemporalScalerDescriptor") != Nil &&
	    atomic_exchange(&scaler_hooked, 1) == 0) {
		replace("MTLFXTemporalScalerDescriptor", @selector(newTemporalScalerWithDevice:), (IMP)hook_new_scaler,
		        &next_new_scaler);
		replace("MTLFXTemporalScalerDescriptor", sel_registerName("newTemporalScalerWithDevice:compiler:"),
		        (IMP)hook_new_scaler4, &next_new_scaler4);
	}
	if (atomic_load(&interpolator_hooked) == 0 && objc_getClass("MTLFXFrameInterpolatorDescriptor") != Nil &&
	    atomic_exchange(&interpolator_hooked, 1) == 0) {
		replace("MTLFXFrameInterpolatorDescriptor", @selector(newFrameInterpolatorWithDevice:),
		        (IMP)hook_new_interpolator, &next_new_interpolator);
		replace("MTLFXFrameInterpolatorDescriptor", sel_registerName("newFrameInterpolatorWithDevice:compiler:"),
		        (IMP)hook_new_interpolator4, &next_new_interpolator4);
	}
}

static void hook_signal_drawable(id queue, SEL selector, id drawable)
{
	next_signal_drawable(queue, selector, drawable);
	if (@available(macOS 26.0, *)) {
		if (takes(drawable))
			[presenter signalled:queue drawable:drawable];
	}
}

static BOOL replace(const char *class_name, SEL selector, IMP hook, void *previous)
{
	Class class = objc_getClass(class_name);
	Method method = class != Nil ? class_getInstanceMethod(class, selector) : NULL;
	if (method == NULL)
		return NO;
	*(IMP *)previous = method_setImplementation(method, hook);
	return YES;
}

static void note_probe(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		return;
	(void)!write(fd, framegen_arch "\n", strlen(framegen_arch) + 1);
	close(fd);
}

static void open_stats(void)
{
	const char *dir = getenv("CARTOUCHE_FRAMEGEN_DIR");
	if (strlcpy(stats_dir, dir != NULL && dir[0] == '/' ? dir : "/tmp", sizeof(stats_dir)) >= sizeof(stats_dir))
		return;
	char path[PATH_MAX];
	time_t t = time(NULL);
	struct tm local;
	localtime_r(&t, &local);
	char stamp[32];
	strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", &local);
	if (snprintf(path, sizeof(path), "%s/framegen-%s-%d.csv", stats_dir, stamp, getpid()) >= (int)sizeof(path))
		return;
	stats_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (stats_fd < 0)
		return;
	const char *header = "time,render_fps,presented_fps,gpu_ms,gpu_max_ms,interval_ms,interval_sd_ms,refresh_ms,paused,"
	                     "dropped,sd_floor_ms,long_intervals,one_refresh,two_refresh,three_refresh,four_plus_refresh,"
	                     "generated_wait_max_ms,admit_wait_max_ms,latency_ms,confidence_mean,repaired_pct,ane_pct,ane_ms\n";
	(void)!write(stats_fd, header, strlen(header));
	say("stats %s", path);
}

// The test window's side. Names are the FGSettings fields, plus aim (pacing, share of half an
// interval), enabled and limit; _get also answers the last whole second's numbers.
static const char *const setting_names[] = { "block", "radius", "factor", "median", "expand", "zero", "mode", "bias",
                                             "motion_scale", "depth", "depth_reversed", "real_delta", "reset_every",
                                             "estimator", "still", "check", "cuts", "downscale", "repair", "hud", "overlay" };

static int setting_index(const char *name)
{
	for (int i = 0; i < (int)(sizeof(setting_names) / sizeof(*setting_names)); i++)
		if (strcmp(name, setting_names[i]) == 0)
			return i;
	return -1;
}

void cartouche_framegen_set(const char *name, double value)
{
	if (name == NULL)
		return;
	os_unfair_lock_lock(&tuning_lock);
	FGSettings *t = &tuning;
	switch (setting_index(name)) {
	case 0: t->block = (int)value; break;
	case 1: t->radius = (int)value; break;
	case 2: t->factor = (int)value; break;
	case 3: t->median = (int)value; break;
	case 4: t->expand = (int)value; break;
	case 5: t->zero = (int)value; break;
	case 6: t->mode = (int)value; break;
	case 7: t->bias = (float)value; break;
	case 8: t->motionScale = (float)value; break;
	case 9: t->depth = (float)value; break;
	case 10: t->depthReversed = (int)value; break;
	case 11: t->realDeltaTime = (int)value; break;
	case 12: t->resetEvery = (int)value; break;
	case 13: t->estimator = (int)value; break;
	case 14: t->still = (int)value; break;
	case 15: t->check = (int)value; break;
	case 16: t->cuts = (int)value; break;
	case 17: t->downscale = (int)value; break;
	case 18: t->repair = (int)value; break;
	case 19: t->hud = (int)value; break;
	case 20: t->overlay = (int)value; break;
	default:
		if (strcmp(name, "aim") == 0)
			tuning_aim = fmax(0.5, fmin(1.2, value));
		else if (strcmp(name, "ane") == 0)
			tuning_ane = value != 0;
		else if (strcmp(name, "ane_wait_ms") == 0)
			tuning_ane_wait = fmax(0, fmin(0.05, value / 1000));
		else if (strcmp(name, "follow") == 0)
			tuning_follow = value != 0;
		else if (strcmp(name, "cushion_ms") == 0)
			tuning_cushion = fmax(0, fmin(0.05, value / 1000));
		else if (strcmp(name, "enabled") == 0)
			tuning_enabled = interpolate && value != 0;
		else if (strcmp(name, "limit") == 0)
			tuning_limit = value < 0 ? -1 : fmin(1000, value);
		break;
	}
	os_unfair_lock_unlock(&tuning_lock);
	atomic_fetch_add(&tuning_version, 1);
}

double cartouche_framegen_get(const char *name)
{
	if (name == NULL)
		return 0;
	os_unfair_lock_lock(&tuning_lock);
	FGSettings t = tuning;
	const struct { const char *name; double value; } values[] = {
		{ "block", t.block }, { "radius", t.radius }, { "factor", t.factor }, { "median", t.median },
		{ "expand", t.expand }, { "zero", t.zero }, { "mode", t.mode }, { "bias", t.bias },
		{ "motion_scale", t.motionScale }, { "depth", t.depth }, { "depth_reversed", t.depthReversed },
		{ "real_delta", t.realDeltaTime }, { "reset_every", t.resetEvery }, { "estimator", t.estimator },
		{ "still", t.still }, { "check", t.check }, { "cuts", t.cuts }, { "downscale", t.downscale }, { "repair", t.repair }, { "hud", t.hud }, { "overlay", t.overlay },
		{ "aim", tuning_aim }, { "follow", tuning_follow }, { "ane", tuning_ane }, { "ane_wait_ms", tuning_ane_wait * 1000 }, { "cushion_ms", tuning_cushion * 1000 },
		{ "enabled", tuning_enabled }, { "limit", tuning_limit }, { "active", atomic_load(&state) == state_active },
		{ "render_fps", snapshot.render }, { "shown_fps", snapshot.shown }, { "gpu_ms", snapshot.gpu },
		{ "gpu_max_ms", snapshot.gpu_max }, { "interval_ms", snapshot.interval },
		{ "interval_sd_ms", snapshot.deviation }, { "refresh_hz", snapshot.refresh_hz },
		{ "screen_hz", snapshot.screen_hz }, { "latency_ms", snapshot.latency },
		{ "latency_max_ms", snapshot.latency_max }, { "paused", snapshot.paused },
		{ "generated", snapshot.generated }, { "dropped", snapshot.dropped },
	};
	os_unfair_lock_unlock(&tuning_lock);
	for (size_t i = 0; i < sizeof(values) / sizeof(*values); i++)
		if (strcmp(name, values[i].name) == 0)
			return values[i].value;
	return 0;
}

// The last shown intervals in milliseconds, oldest first
int cartouche_framegen_intervals(double *out, int max)
{
	os_unfair_lock_lock(&tuning_lock);
	unsigned count = ring_at < 240 ? ring_at : 240;
	if (max < (int)count)
		count = (unsigned)max;
	for (unsigned i = 0; i < count; i++)
		out[i] = ring[(ring_at - count + i) % 240];
	os_unfair_lock_unlock(&tuning_lock);
	return (int)count;
}

// Without generation, the presents matter only to what draws on them or counts them
static BOOL presents_wanted(void)
{
	FGOverlayLevel level;
	const char *control = getenv("CARTOUCHE_OVERLAY_CONTROL"), *metrics = getenv("CARTOUCHE_METRICS");
	return !FGOverlayParseLevel(getenv("CARTOUCHE_OVERLAY"), &level) || level != FGOverlayOff ||
	       (control != NULL && strcmp(control, "1") == 0) || (metrics != NULL && strcmp(metrics, "1") == 0) ||
	       stats_wanted || getenv("CARTOUCHE_FRAMEGEN_UPSCALE") != NULL || probe_fd >= 0;
}

__attribute__((constructor)) static void framegen_load(void)
{
	const char *probe = getenv("CARTOUCHE_FRAMEGEN_PROBE");
	if (probe != NULL && probe[0] == '/')
		note_probe(probe);

	const char *enabled = getenv("CARTOUCHE_FRAMEGEN");
	if (enabled == NULL || strcmp(enabled, "1") != 0)
		return;
	say("loaded arch=%s", framegen_arch);
	if (@available(macOS 26.0, *)) {
	} else {
		say("unsupported macOS");
		return;
	}
	tuning = FGDefaultSettings();
	const char *interpolation = getenv("CARTOUCHE_FRAMEGEN_INTERPOLATE");
	interpolate = interpolation == NULL || strcmp(interpolation, "0") != 0;
	tuning_enabled = interpolate;
	// CARTOUCHE_FRAMEGEN_TUNE="name=value,...": the test window's settings from the start
	const char *tune = getenv("CARTOUCHE_FRAMEGEN_TUNE");
	if (tune != NULL) {
		char *copy = strdup(tune), *save = NULL;
		for (char *pair = strtok_r(copy, ",", &save); pair != NULL; pair = strtok_r(NULL, ",", &save)) {
			char name[32], text[32];
			if (sscanf(pair, "%31[^=]=%31s", name, text) == 2)
				cartouche_framegen_set(name, strcmp(text, "auto") == 0 ? -1 : atof(text));
		}
		free(copy);
	}
	failure_point = getenv("CARTOUCHE_FRAMEGEN_FAIL");
	const char *probe_at = getenv("CARTOUCHE_FRAMEGEN_PROBE_AT");
	probe_overlay = probe_at != NULL && strcmp(probe_at, "overlay") == 0;
	const char *probe_log = getenv("CARTOUCHE_FRAMEGEN_PROBE_LOG");
	if (probe_log != NULL && probe_log[0] == '/')
		probe_fd = open(probe_log, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);
	const char *stats = getenv("CARTOUCHE_FRAMEGEN_STATS");
	stats_wanted = stats != NULL && strcmp(stats, "1") == 0;

	if (!interpolate && !presents_wanted()) {
		say("interpolation off, presents untouched");
		FGTemporalStart(say);
		_dyld_register_func_for_add_image(watch_metalfx);
		atomic_store(&state, state_active);
		return;
	}
	if (!interpolate)
		say("interpolation off");
	BOOL hooked = replace("CAMetalLayer", @selector(nextDrawable), (IMP)hook_next_drawable, &next_next_drawable) &&
		replace("_MTLCommandBuffer", @selector(presentDrawable:), (IMP)hook_buffer_present, &next_buffer_present) &&
		replace("_MTLCommandBuffer", @selector(presentDrawable:afterMinimumDuration:), (IMP)hook_buffer_present_after,
		        &next_buffer_present_after) &&
		replace("_MTLCommandBuffer", @selector(presentDrawable:atTime:), (IMP)hook_buffer_present_at,
		        &next_buffer_present_at) &&
		replace("CAMetalDrawable", @selector(present), (IMP)hook_drawable_present, &next_drawable_present) &&
		replace("CAMetalDrawable", @selector(presentAfterMinimumDuration:), (IMP)hook_drawable_present_after,
		        &next_drawable_present_after) &&
		replace("CAMetalDrawable", @selector(presentAtTime:), (IMP)hook_drawable_present_at, &next_drawable_present_at);
	if (!hooked) {
		say("disabled Metal classes not found");
		return;
	}
	// Older systems have no MTL4 queue; the classic path still works without it
	replace("_MTL4CommandQueue", sel_registerName("signalDrawable:"), (IMP)hook_signal_drawable, &next_signal_drawable);
	FGTemporalStart(say);
	// MetalFX loads with the runner, not always with the game: look for it now and on each image
	_dyld_register_func_for_add_image(watch_metalfx);
	atomic_store(&state, state_active);
}
