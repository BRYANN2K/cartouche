// A Metal test app for the frame counter: presents frames through CAMetalLayer at a
// locked rate, or as fast as it can for the overhead runs.
//
//   present locked <fps> <seconds> [--appkit]   prints the frames it presented
//   present bench <seconds> [<ms>]              prints its own average FPS
//
// A bench frame is rendered, not presented, and spends <ms> of CPU time (8 by
// default) as a game's own work, so the rate sits under the display's pacing and
// any cost the counter adds shows in it.
//
// --version answers as a Wine loader does, so the run script's probe can try it.
// --appkit loads AppKit and makes an NSApplication that is never activated, as a game
// in the background has.

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import <dlfcn.h>
#import <objc/message.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void wait_until(double deadline)
{
	double left = deadline - now();
	if (left <= 0)
		return;
	struct timespec t = { (time_t)left, (long)((left - (double)(time_t)left) * 1e9) };
	nanosleep(&t, NULL);
	// The last stretch spins, so frames stay on time
	while (now() < deadline) {
	}
}

int main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "--version") == 0) {
		puts("wine-10.0 (Cartouche test loader)");
		return 0;
	}
	if (argc < 3)
		return 2;
	int locked = strcmp(argv[1], "locked") == 0;
	double rate = locked ? atof(argv[2]) : 0;
	double seconds = atof(argv[locked ? 3 : 2]);
	int appkit = argc > (locked ? 4 : 3) && strcmp(argv[argc - 1], "--appkit") == 0;
	double work = !locked && argc > 3 ? atof(argv[3]) / 1000.0 : 0.008;

	@autoreleasepool {
		if (appkit) {
			if (dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW) == NULL)
				return 3;
			((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"),
			                                sel_registerName("sharedApplication"));
		}

		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			fprintf(stderr, "no Metal device\n");
			return 3;
		}
		CAMetalLayer *layer = [CAMetalLayer layer];
		layer.device = device;
		layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
		layer.drawableSize = CGSizeMake(1280, 720);
		layer.displaySyncEnabled = NO;
		id<MTLCommandQueue> queue = [device newCommandQueue];

		unsigned long presented = 0;
		double start = now();
		double end = start + seconds;
		double next = start;
		while (now() < end) {
			@autoreleasepool {
				id<CAMetalDrawable> drawable = [layer nextDrawable];
				if (drawable == nil)
					continue;
				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = drawable.texture;
				pass.colorAttachments[0].loadAction = MTLLoadActionClear;
				pass.colorAttachments[0].clearColor = MTLClearColorMake((presented % 60) / 60.0, 0.2, 0.4, 1);
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				id<MTLCommandBuffer> buffer = [queue commandBuffer];
				[[buffer renderCommandEncoderWithDescriptor:pass] endEncoding];
				if (locked)
					[buffer presentDrawable:drawable];
				[buffer commit];
				presented++;
			}
			if (locked) {
				next += 1.0 / rate;
				wait_until(next);
			} else {
				// Spins rather than sleeps, as a sleep's wake-up varies more than the counter costs
				double until = now() + work;
				while (now() < until) {
				}
			}
		}
		double elapsed = now() - start;
		if (locked)
			printf("%lu\n", presented);
		else
			printf("%.1f\n", (double)presented / elapsed);
	}
	return 0;
}
