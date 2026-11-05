// A stand-in game for the frame generation library: a window whose Metal layer shows a
// moving pattern at locked rates, presented the way D3DMetal and DXMT do.
//
//   game <rate>:<seconds>[,<rate>:<seconds>...] [--mtl4] [--mtl4fx] [--mtl4fx-interpolator] [--resize]
//        [--latency <clicks>] [--load <n>] [--render-scale <s>] [--clicks <n>] [--cover] [--times <file>] [--no-vsync]
//
// --mtl4 presents through an MTL4 queue (signalDrawable, then present), as D3DMetal can.
// --mtl4fx, with --mtl4, upscales each frame's color, depth and motion with an MTL4FX
// temporal scaler first, as a DLSS game under D3DMetal may. --mtl4fx-interpolator makes an
// MTL4FX frame interpolator, as a runner that generates frames itself.
// --resize halves the drawable size half way through. Prints the number of frames it
// rendered and how many of them reached the screen. --version answers as a Wine loader.
// --latency: a square in the middle turns white or black on each click; clicks are CGEvents
// posted to this process every 200 to 400 ms. Prints, per click, the host times it was
// posted, handled, and first shown: the presentedTime of the first frame drawn after it.
// --load draws the frame n times over, for a GPU load closer to a game's (classic path).
// --hz prints the refresh rate of the screen the window would go to, see screen.h.
// --render-scale renders at that share of the window's pixels, as a game set below the screen's
// resolution. --clicks posts that many clicks to this process at known places in the window and
// draws a white mark where each landed, in render pixels; prints where each was, in the
// window's points from its top left and in render pixels (classic path only).
// --cover makes the window borderless over the whole test screen, as a game in fullscreen under Wine.
// --times writes the presentedTime of every frame shown, in seconds of host time, one per line.
// --no-vsync lets nextDrawable run past the screen's refresh, as a game with vsync off.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>

#import <os/lock.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <unistd.h>

#import "screen.h"

static _Atomic long shown;
static _Atomic long clicks;
static double *shownTimes;
static long shownCap;
static double *posted, *handled, *firstShown;
static os_unfair_lock shownLock = OS_UNFAIR_LOCK_INIT;

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
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

static NSString *pattern_source = @
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct V { float4 p [[position]]; };\n"
	"vertex V v(uint i [[vertex_id]]) { float2 c = float2((i << 1) & 2, i & 2); V o; o.p = float4(c * 2 - 1, 0, 1); return o; }\n"
	"static float4 pattern(float4 p, float4 u) {\n"
	"  float2 at = p.xy + float2(u.x, 0);\n"
	"  if (u.y >= 0 && all(abs(p.xy - u.zw * 0.5) < u.w * 0.25)) return float4(float3(u.y), 1);\n"
	"  float check = fmod(floor(at.x / 64) + floor(at.y / 64), 2.0);\n"
	"  return float4(check, 0.3 + 0.4 * check, 1 - check, 1);\n"
	"}\n"
	"fragment float4 f(V in [[stage_in]], constant float4 &u [[buffer(0)]]) { return pattern(in.p, u); }\n"
	"fragment float4 marked(V in [[stage_in]], constant float4 &u [[buffer(0)]], constant float2 *marks [[buffer(1)]]) {\n"
	"  for (int i = 1; i <= int(marks[0].x); i++) if (all(abs(in.p.xy - marks[i]) < 3)) return float4(1);\n"
	"  return pattern(in.p, u);\n"
	"}\n";

// Clicks for --clicks: in the window's points from its top left, and the marks they left, in
// render pixels; marks[0].x is how many
static long markCount;
static float marks[9][2];
static os_unfair_lock marksLock = OS_UNFAIR_LOCK_INIT;

static void click_at(long count, NSWindow *window)
{
	sleep(3);
	static const double spots[4][2] = { { 0.25, 0.3 }, { 0.7, 0.62 }, { 0.5, 0.85 }, { 0.12, 0.75 } };
	for (long i = 0; i < count && i < 4; i++) {
		__block CGPoint point;
		dispatch_sync(dispatch_get_main_queue(), ^{
			NSView *view = window.contentView;
			NSRect onScreen = [window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
			CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
			point = CGPointMake(NSMinX(onScreen) + spots[i][0] * NSWidth(onScreen),
			                    top - NSMaxY(onScreen) + spots[i][1] * NSHeight(onScreen));
		});
		CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
		CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
		CGEventPostToPid(getpid(), down);
		CGEventPostToPid(getpid(), up);
		CFRelease(down);
		CFRelease(up);
		usleep(300000);
	}
}

// Clicks on the window's centre, posted to this process only, every 200 to 400 ms after
// five seconds for the window to settle; then the results, and exit
static void inject(long count, NSWindow *window)
{
	sleep(5);
	__block CGPoint point;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSRect frame = window.frame;
		CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
		point = CGPointMake(NSMidX(frame), top - NSMidY(frame));
	});
	BOOL direct = CGPreflightPostEventAccess();
	fprintf(stderr, "game: clicks %s\n", direct ? "posted to the pid" : "queued in the app");
	for (long i = 0; i < count; i++) {
		usleep(200000 + (useconds_t)arc4random_uniform(200000));
		CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
		CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
		posted[i] = CACurrentMediaTime();
		if (direct) {
			CGEventPostToPid(getpid(), down);
			CGEventPostToPid(getpid(), up);
		} else {
			[NSApp postEvent:[NSEvent eventWithCGEvent:down] atStart:NO];
			[NSApp postEvent:[NSEvent eventWithCGEvent:up] atStart:NO];
		}
		CFRelease(down);
		CFRelease(up);
	}
	sleep(1);
	os_unfair_lock_lock(&shownLock);
	for (long i = 0; i < count; i++)
		printf("click %ld %.6f %.6f %.6f\n", i, posted[i], handled[i], firstShown[i]);
	os_unfair_lock_unlock(&shownLock);
	fflush(stdout);
	exit(0);
}

// Render-size color, depth and motion, cleared each frame by an empty pass: the motion is a
// steady 4 px to the left, in render pixels
API_AVAILABLE(macos(26.0))
static id make_scaler(id<MTLDevice> device, id<MTL4Compiler> compiler, id<MTL4CommandQueue> queue,
                      id *inputs)
{
	MTLFXTemporalScalerDescriptor *describe = [MTLFXTemporalScalerDescriptor new];
	describe.colorTextureFormat = MTLPixelFormatRGBA16Float;
	describe.depthTextureFormat = MTLPixelFormatDepth32Float;
	describe.motionTextureFormat = MTLPixelFormatRG16Float;
	describe.outputTextureFormat = MTLPixelFormatRGBA16Float;
	describe.inputWidth = 960;
	describe.inputHeight = 540;
	describe.outputWidth = 1920;
	describe.outputHeight = 1080;
	id<MTL4FXTemporalScaler> scaler = [describe newTemporalScalerWithDevice:device compiler:compiler];
	if (scaler == nil) {
		fprintf(stderr, "game: no MTL4FX temporal scaler\n");
		return nil;
	}
	id<MTLTexture> (^texture)(MTLPixelFormat, NSUInteger, NSUInteger, MTLTextureUsage) =
		^(MTLPixelFormat format, NSUInteger width, NSUInteger height, MTLTextureUsage usage) {
			MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
			                                                                             width:width
			                                                                            height:height
			                                                                         mipmapped:NO];
			d.usage = usage;
			d.storageMode = MTLStorageModePrivate;
			return [device newTextureWithDescriptor:d];
		};
	scaler.colorTexture = texture(describe.colorTextureFormat, 960, 540, scaler.colorTextureUsage | MTLTextureUsageRenderTarget);
	scaler.depthTexture = texture(describe.depthTextureFormat, 960, 540, scaler.depthTextureUsage | MTLTextureUsageRenderTarget);
	scaler.motionTexture = texture(describe.motionTextureFormat, 960, 540, scaler.motionTextureUsage | MTLTextureUsageRenderTarget);
	// A DLSS output is an unordered access view: shader writable
	scaler.outputTexture = texture(describe.outputTextureFormat, 1920, 1080, scaler.outputTextureUsage | MTLTextureUsageShaderWrite);
	scaler.inputContentWidth = 960;
	scaler.inputContentHeight = 540;
	scaler.motionVectorScaleX = 1;
	scaler.motionVectorScaleY = 1;
	id<MTLResidencySet> set = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
	for (id<MTLTexture> t in @[ scaler.colorTexture, scaler.depthTexture, scaler.motionTexture, scaler.outputTexture ])
		[set addAllocation:t];
	[set commit];
	[queue addResidencySet:set];
	MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
	pass.colorAttachments[0].texture = scaler.colorTexture;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0.4, 0.5, 0.6, 1);
	pass.colorAttachments[1].texture = scaler.motionTexture;
	pass.colorAttachments[1].clearColor = MTLClearColorMake(-4, 0, 0, 0);
	for (int i = 0; i < 2; i++) {
		pass.colorAttachments[i].loadAction = MTLLoadActionClear;
		pass.colorAttachments[i].storeAction = MTLStoreActionStore;
	}
	pass.depthAttachment.texture = scaler.depthTexture;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.storeAction = MTLStoreActionStore;
	pass.depthAttachment.clearDepth = 0.5;
	*inputs = pass;
	return scaler;
}

API_AVAILABLE(macos(26.0))
static id make_interpolator(id<MTLDevice> device, id<MTL4Compiler> compiler)
{
	MTLFXFrameInterpolatorDescriptor *describe = [MTLFXFrameInterpolatorDescriptor new];
	describe.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
	describe.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
	describe.depthTextureFormat = MTLPixelFormatDepth32Float;
	describe.motionTextureFormat = MTLPixelFormatRG16Float;
	describe.inputWidth = describe.outputWidth = 1920;
	describe.inputHeight = describe.outputHeight = 1080;
	return [describe newFrameInterpolatorWithDevice:device compiler:compiler];
}

// Held for the process lifetime, see main
static id activity;

int main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "--version") == 0) {
		puts("wine-10.0 (Cartouche test loader)");
		return 0;
	}
	if (argc == 2 && strcmp(argv[1], "--hz") == 0) {
		[NSApplication sharedApplication];
		printf("%ld\n", (long)test_screen().maximumFramesPerSecond);
		return 0;
	}
	if (argc < 2)
		return 2;
	BOOL mtl4 = NO, resize = NO, mtl4fx = NO, interpolator = NO, cover = NO, vsync = YES;
	const char *timesPath = NULL;
	long latency = 0, load = 1, clickCount = 0;
	double renderScale = 0;
	for (int i = 2; i < argc; i++) {
		mtl4 |= strcmp(argv[i], "--mtl4") == 0;
		mtl4fx |= strcmp(argv[i], "--mtl4fx") == 0;
		interpolator |= strcmp(argv[i], "--mtl4fx-interpolator") == 0;
		resize |= strcmp(argv[i], "--resize") == 0;
		cover |= strcmp(argv[i], "--cover") == 0;
		vsync &= strcmp(argv[i], "--no-vsync") != 0;
		if (strcmp(argv[i], "--times") == 0 && i + 1 < argc)
			timesPath = argv[++i];
		if (strcmp(argv[i], "--latency") == 0 && i + 1 < argc)
			latency = atol(argv[++i]);
		if (strcmp(argv[i], "--load") == 0 && i + 1 < argc)
			load = MAX(1, atol(argv[++i]));
		if (strcmp(argv[i], "--render-scale") == 0 && i + 1 < argc)
			renderScale = atof(argv[++i]);
		if (strcmp(argv[i], "--clicks") == 0 && i + 1 < argc)
			clickCount = atol(argv[++i]);
	}
	static double rates[16], spans[16];
	double total = 0;
	int steps = 0;
	for (char *part = strtok(argv[1], ","); part != NULL && steps < 16; part = strtok(NULL, ",")) {
		if (sscanf(part, "%lf:%lf", &rates[steps], &spans[steps]) != 2)
			return 2;
		total += spans[steps++];
	}
	if (timesPath != NULL) {
		shownCap = (long)(total * 500) + 1000;
		shownTimes = calloc((size_t)shownCap, sizeof(double));
	}

	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
		// An app in the background gets App Nap and coalesced timers, which slow its frames
		activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
		                                                        reason:@"framegen test"];
		NSWindow *window = [[NSWindow alloc] initWithContentRect:cover ? test_screen().frame : NSMakeRect(100, 100, 960, 540)
		                                               styleMask:cover ? NSWindowStyleMaskBorderless : NSWindowStyleMaskTitled
		                                                 backing:NSBackingStoreBuffered
		                                                   defer:NO];
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		CAMetalLayer *layer = [CAMetalLayer layer];
		layer.device = device;
		layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
		layer.displaySyncEnabled = vsync;
		window.contentView.wantsLayer = YES;
		window.contentView.layer = layer;
		layer.drawableSize = CGSizeMake(1920, 1080);
		if (cover) {
			window.level = NSFloatingWindowLevel;
			window.ignoresMouseEvents = YES;
			[window setFrame:test_screen().frame display:NO];
			[window orderFrontRegardless];
		} else
			place_test_window(window, 0);
		if (renderScale > 0) {
			NSSize points = window.contentView.bounds.size;
			CGFloat density = window.backingScaleFactor;
			layer.drawableSize = CGSizeMake(round(points.width * density * renderScale), round(points.height * density * renderScale));
			fprintf(stderr, "game: render %.0fx%.0f in %.0fx%.0f points at %.0fx\n", layer.drawableSize.width,
			        layer.drawableSize.height, points.width, points.height, density);
		}
		if (clickCount > 0) {
			[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
				CGPoint at = CGEventGetLocation(event.CGEvent);
				CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
				NSView *view = window.contentView;
				NSPoint inView = [view convertPoint:[window convertPointFromScreen:NSMakePoint(at.x, top - at.y)] fromView:nil];
				NSSize size = view.bounds.size;
				CGSize drawable = layer.drawableSize;
				float x = (float)(inView.x / size.width * drawable.width), y = (float)((size.height - inView.y) / size.height * drawable.height);
				os_unfair_lock_lock(&marksLock);
				if (markCount < 8) {
					markCount++;
					marks[markCount][0] = floorf(x) + 0.5f;
					marks[markCount][1] = floorf(y) + 0.5f;
				}
				os_unfair_lock_unlock(&marksLock);
				printf("click %.2f %.2f render %.2f %.2f\n", inView.x, size.height - inView.y, floorf(x) + 0.5f, floorf(y) + 0.5f);
				fflush(stdout);
				return nil;
			}];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				click_at(clickCount, window);
			});
		}

		if (latency > 0) {
			posted = calloc((size_t)latency, sizeof(double));
			handled = calloc((size_t)latency, sizeof(double));
			firstShown = calloc((size_t)latency, sizeof(double));
			[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
				(void)event;
				long c = atomic_load(&clicks);
				if (c < latency)
					handled[c] = CACurrentMediaTime();
				atomic_store(&clicks, c + 1);
				return nil;
			}];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				inject(latency, window);
			});
		}

		NSError *error = nil;
		id<MTLLibrary> library = [device newLibraryWithSource:pattern_source options:nil error:&error];
		MTLRenderPipelineDescriptor *describe = [MTLRenderPipelineDescriptor new];
		describe.vertexFunction = [library newFunctionWithName:@"v"];
		describe.fragmentFunction = [library newFunctionWithName:clickCount > 0 ? @"marked" : @"f"];
		describe.colorAttachments[0].pixelFormat = layer.pixelFormat;
		id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:describe error:&error];
		if (pipeline == nil) {
			fprintf(stderr, "pipeline: %s\n", error.localizedDescription.UTF8String);
			return 3;
		}

		__block long rendered = 0;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
			id<MTLCommandQueue> queue = [device newCommandQueue];
			id<MTL4CommandQueue> queue4 = nil;
			id<MTL4CommandAllocator> allocator = nil;
			id<MTL4CommandBuffer> buffer4 = nil;
			id<MTL4ArgumentTable> table = nil;
			id<MTLBuffer> shiftBuffer = nil;
			id scaler = nil;
			id inputs = nil;
			if (mtl4) {
				if (@available(macOS 26.0, *)) {
					queue4 = [device newMTL4CommandQueue];
					[queue4 addResidencySet:layer.residencySet];
					id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:nil];
					if (mtl4fx)
						scaler = make_scaler(device, compiler, queue4, &inputs);
					if (interpolator && make_interpolator(device, compiler) == nil)
						fprintf(stderr, "game: no MTL4FX interpolator\n");
					allocator = [device newCommandAllocator];
					buffer4 = [device newCommandBuffer];
					MTL4ArgumentTableDescriptor *tableDescriptor = [MTL4ArgumentTableDescriptor new];
					tableDescriptor.maxBufferBindCount = 1;
					table = [device newArgumentTableWithDescriptor:tableDescriptor error:nil];
					shiftBuffer = [device newBufferWithLength:4 * sizeof(float) options:MTLResourceStorageModeShared];
				}
			}
			double start = now(), next = start, end = start;
			BOOL resized = NO;
			for (int step = 0; step < steps; step++) {
				end += spans[step];
				while (now() < end) {
					@autoreleasepool {
						if (resize && !resized && now() - start > total / 2) {
							layer.drawableSize = CGSizeMake(960, 540);
							resized = YES;
						}
						id<CAMetalDrawable> drawable = [layer nextDrawable];
						if (drawable != nil) {
							long seen = atomic_load(&clicks);
							[drawable addPresentedHandler:^(id<MTLDrawable> d) {
								double at = d.presentedTime;
								if (at > 0) {
									long n = atomic_fetch_add(&shown, 1);
									if (n < shownCap)
										shownTimes[n] = at;
								}
								if (at > 0 && seen > 0 && seen <= latency) {
									os_unfair_lock_lock(&shownLock);
									if (firstShown[seen - 1] == 0 || at < firstShown[seen - 1])
										firstShown[seen - 1] = at;
									os_unfair_lock_unlock(&shownLock);
								}
							}];
							// The pattern moves 4 px per real frame
							float shift[4] = { (float)(rendered * 4 % 128), latency > 0 ? (float)(seen & 1) : -1,
							                   (float)drawable.texture.width, (float)drawable.texture.height };
							MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
							pass.colorAttachments[0].texture = drawable.texture;
							pass.colorAttachments[0].loadAction = MTLLoadActionClear;
							pass.colorAttachments[0].storeAction = MTLStoreActionStore;
							if (queue4 != nil) {
								if (@available(macOS 26.0, *)) {
									memcpy(shiftBuffer.contents, shift, sizeof(shift));
									[allocator reset];
									[buffer4 beginCommandBufferWithAllocator:allocator];
									if (scaler != nil) {
										id<MTL4FXTemporalScaler> fx = scaler;
										[[buffer4 renderCommandEncoderWithDescriptor:inputs] endEncoding];
										fx.jitterOffsetX = 0.25f;
										fx.jitterOffsetY = -0.25f;
										fx.reset = rendered == 0;
										[fx encodeToCommandBuffer:buffer4];
									}
									MTL4RenderPassDescriptor *pass4 = [MTL4RenderPassDescriptor new];
									pass4.colorAttachments[0].texture = drawable.texture;
									pass4.colorAttachments[0].loadAction = MTLLoadActionClear;
									pass4.colorAttachments[0].storeAction = MTLStoreActionStore;
									id<MTL4RenderCommandEncoder> encoder = [buffer4 renderCommandEncoderWithDescriptor:pass4];
									[encoder setRenderPipelineState:pipeline];
									[table setAddress:shiftBuffer.gpuAddress atIndex:0];
									[encoder setArgumentTable:table atStages:MTLRenderStageFragment];
									[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
									[encoder endEncoding];
									[buffer4 endCommandBuffer];
									[queue4 waitForDrawable:drawable];
									id<MTL4CommandBuffer> list[1] = { buffer4 };
									[queue4 commit:list count:1];
									[queue4 signalDrawable:drawable];
									[drawable present];
									// One allocator: wait for the GPU before reusing it
									id<MTLSharedEvent> done = [device newSharedEvent];
									[queue4 signalEvent:done value:1];
									[done waitUntilSignaledValue:1 timeoutMS:1000];
								}
							} else {
								id<MTLCommandBuffer> buffer = [queue commandBuffer];
								id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
								[encoder setRenderPipelineState:pipeline];
								[encoder setFragmentBytes:shift length:sizeof(shift) atIndex:0];
								if (clickCount > 0) {
									os_unfair_lock_lock(&marksLock);
									marks[0][0] = (float)markCount;
									[encoder setFragmentBytes:marks length:sizeof(marks) atIndex:1];
									os_unfair_lock_unlock(&marksLock);
								}
								for (long k = 0; k < load; k++)
									[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
								[encoder endEncoding];
								[buffer presentDrawable:drawable];
								[buffer commit];
							}
							rendered++;
						}
					}
					next += 1.0 / rates[step];
					if (next < now())
						next = now();
					wait_until(next);
				}
			}
			usleep(300000);
			dispatch_async(dispatch_get_main_queue(), ^{
				printf("rendered %ld shown %ld\n", rendered, atomic_load(&shown));
				FILE *out = timesPath != NULL ? fopen(timesPath, "w") : NULL;
				for (long i = 0; out != NULL && i < MIN(atomic_load(&shown), shownCap); i++)
					fprintf(out, "%.6f\n", shownTimes[i]);
				if (out != NULL)
					fclose(out);
				fflush(stdout);
				exit(0);
			});
		});
		[NSApp run];
	}
	return 0;
}
