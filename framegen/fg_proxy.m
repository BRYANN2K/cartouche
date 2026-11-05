// The library's end of the FFX proxy (framegen/proxy): its log lines, and each frame's depth and
// motion from the game's readback copies, turned into pixels on the GPU and matched to the real
// frame by the game's frame number. docs/FRAME-GENERATION.md, FFX proxy.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import <mach/mach_time.h>
#import <math.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdio.h>

#import "proxy/fg_proxy.h"

enum { proxy_slots = 4, presents_kept = 64, delays_kept = 512 };
enum { slot_empty, slot_converting, slot_ready, slot_refused };

static const char *kernels =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct Layout { uint pitch, stride, width, height; float2 scale; float limit; };\n"
	"template <typename T> void convert(device const T *in, constant Layout &l, device atomic_uint *bad,\n"
	"    texture2d<half, access::write> out, uint2 gid) {\n"
	"  if (gid.x >= l.width || gid.y >= l.height) return;\n"
	"  device const T *p = in + gid.y * l.pitch + gid.x * l.stride;\n"
	"  float2 m = float2(p[0], p[1]) * l.scale;\n"
	"  if (any(isnan(m)) || length(m) > l.limit) { atomic_fetch_add_explicit(bad, 1, memory_order_relaxed); m = 0; }\n"
	"  out.write(half4(half2(m), 0, 0), gid);\n"
	"}\n"
	"kernel void ffx_motion_half(device const half *in [[buffer(0)]], constant Layout &l [[buffer(1)]],\n"
	"    device atomic_uint *bad [[buffer(2)]], texture2d<half, access::write> out [[texture(0)]],\n"
	"    uint2 gid [[thread_position_in_grid]]) { convert(in, l, bad, out, gid); }\n"
	"kernel void ffx_motion_float(device const float *in [[buffer(0)]], constant Layout &l [[buffer(1)]],\n"
	"    device atomic_uint *bad [[buffer(2)]], texture2d<half, access::write> out [[texture(0)]],\n"
	"    uint2 gid [[thread_position_in_grid]]) { convert(in, l, bad, out, gid); }\n";

typedef struct {
	uint32_t pitch, stride, width, height;
	float scale[2];
	float limit;
} Layout;

typedef struct {
	uint64_t frame;
	int state;
	// Presenter command buffers still reading motion: the slot is not rewritten meanwhile
	int readers;
	id<MTLBuffer> raw, depth, bad;
	id<MTLTexture> motion;
} Slot;

static FGProxyShared shared;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLComputePipelineState> to_pixels[2];
static Slot slots[proxy_slots];
static uint64_t frames, ui_frames;
static double copy_us, copy_max_us, gpu_us;
static dispatch_once_t started;
static _Atomic int warming;
static BOOL ready;
// The presenter's device, set before the first frame; the default device otherwise
static id<MTLDevice> wanted;
// Guarded by lock: the slots' states, presents seen, and the numbers below
static NSCondition *lock;
static struct {
	uint64_t frame;
	double at;
} presents[presents_kept];
static uint64_t last_tag, tag_steps[4], refused, matched, waited, missed, repeats, late, busy;
static double delays[delays_kept], wait_total;
static uint64_t delay_count;

static BOOL start(void);

// The proxy logs long before its first frame: the device and the kernel get ready meanwhile, as
// compiling them on the first frame holds the copies back half a second
static void warm(void)
{
	dispatch_once(&started, ^{
		lock = [NSCondition new];
		ready = start();
	});
}

__attribute__((visibility("default"))) FGProxyShared *cartouche_framegen_ffx_shared(void)
{
	return &shared;
}

__attribute__((visibility("default"))) void cartouche_framegen_ffx_log(const char *line)
{
	fprintf(stderr, "framegen: %s\n", line);
	if (atomic_exchange(&warming, 1) == 0)
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			warm();
		});
}

// The game's motion is x and y first, in two or four half or full floats
static int motion_stride(uint32_t format)
{
	switch (format) {
	case fg_proxy_r16g16_float:
	case fg_proxy_r32g32_float:
		return 2;
	case fg_proxy_r16g16b16a16_float:
	case fg_proxy_r32g32b32a32_float:
		return 4;
	}
	return 0;
}

void FGProxyUseDevice(id<MTLDevice> presenter)
{
	wanted = presenter;
}

static BOOL start(void)
{
	device = wanted ?: MTLCreateSystemDefaultDevice();
	queue = [device newCommandQueue];
	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:@(kernels) options:nil error:&error];
	for (int i = 0; i < 2 && library != nil; i++) {
		id<MTLFunction> f = [library newFunctionWithName:i ? @"ffx_motion_float" : @"ffx_motion_half"];
		to_pixels[i] = f != nil ? [device newComputePipelineStateWithFunction:f error:&error] : nil;
	}
	if (to_pixels[0] == nil || to_pixels[1] == nil)
		fprintf(stderr, "framegen: ffx motion kernel: %s\n", error.localizedDescription.UTF8String);
	return to_pixels[0] != nil && to_pixels[1] != nil;
}

static double now(void)
{
	mach_timebase_info_data_t base;
	mach_timebase_info(&base);
	return (double)mach_absolute_time() * base.numer / base.denom / 1e9;
}

static int ascending(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static double wait_budget(void)
{
	const char *ms = getenv("CARTOUCHE_FRAMEGEN_FFX_WAIT");
	return (ms != NULL ? atof(ms) : 0) / 1000;
}

// Under lock: from a real frame's present to its vectors being ready, in ms, negative when early
static void print_stats(void)
{
	uint64_t n = delay_count < delays_kept ? delay_count : delays_kept;
	double sorted[delays_kept];
	memcpy(sorted, delays, n * sizeof(double));
	qsort(sorted, n, sizeof(double), ascending);
	uint64_t in_time = 0;
	for (uint64_t i = 0; i < n; i++)
		in_time += sorted[i] <= wait_budget() * 1000;
	fprintf(stderr,
	        "framegen: ffx match frames=%llu refused=%llu repeats=%llu tag_steps=%llu,%llu,%llu,%llu+ vectors_after_present_ms "
	        "p50=%.1f p90=%.1f p99=%.1f in_budget=%.0f%% matched=%llu late=%llu waited=%llu wait_avg_ms=%.2f missed=%llu busy=%llu\n",
	        (unsigned long long)frames, (unsigned long long)refused, (unsigned long long)repeats, (unsigned long long)tag_steps[0],
	        (unsigned long long)tag_steps[1], (unsigned long long)tag_steps[2], (unsigned long long)tag_steps[3],
	        n ? sorted[n / 2] : 0, n ? sorted[n * 9 / 10] : 0, n ? sorted[n * 99 / 100] : 0,
	        n ? 100.0 * in_time / n : 0, (unsigned long long)matched, (unsigned long long)late, (unsigned long long)waited,
	        waited ? wait_total * 1000 / waited : 0, (unsigned long long)missed, (unsigned long long)busy);
}

// The real frame the game just presented: the number of the last list it submitted, 0 without
// the proxy's copies, and 0 for a present that shows the same frame again (the FSR sample on
// D3DMetal presents most frames twice): no vectors belong to it
uint64_t FGProxyTag(void)
{
	uint64_t tag = shared.signaled;
	if (tag == 0 || lock == nil)
		return 0;
	[lock lock];
	uint64_t step = last_tag != 0 && tag > last_tag ? tag - last_tag : 0;
	if (last_tag != 0)
		tag_steps[step < 3 ? step : 3]++;
	if (last_tag != 0 && step == 0) {
		repeats++;
		[lock unlock];
		return 0;
	}
	last_tag = tag;
	presents[tag % presents_kept].frame = tag;
	presents[tag % presents_kept].at = now();
	[lock unlock];
	return tag;
}

// FSR frame generation in the game: the library's stands down, and says so when it changes
BOOL FGProxyGameGenerates(void)
{
	static int told;
	int on = shared.game_generates != 0;
	if (on != told) {
		fprintf(stderr, "framegen: %s\n", on ? "standing down: the game generates frames" : "the game stopped generating frames");
		told = on;
	}
	return on;
}

BOOL FGProxyActive(void)
{
	return shared.signaled != 0;
}

// The vectors of frame tag, in pixels, waited for up to the budget, else the newest ones at most
// two frames older; nil when refused or none, and our estimate serves
id<MTLTexture> FGProxyMotion(uint64_t tag, float *scale)
{
	if (tag == 0 || lock == nil)
		return nil;
	*scale = 1;
	double deadline = now() + wait_budget(), began = now();
	id<MTLTexture> found = nil;
	Slot *taken = NULL;
	BOOL refused_frame = NO, had_to_wait = NO, stale = NO;
	@autoreleasepool {
	[lock lock];
	for (;;) {
		Slot *slot = NULL;
		for (int i = 0; i < proxy_slots; i++)
			if (slots[i].frame == tag)
				slot = &slots[i];
		if (slot != NULL && slot->state == slot_ready) {
			taken = slot;
			break;
		}
		if (slot != NULL && slot->state == slot_refused) {
			refused_frame = YES;
			break;
		}
		if (now() >= deadline) {
			Slot *newest = NULL;
			for (int i = 0; i < proxy_slots; i++)
				if (slots[i].state == slot_ready && slots[i].frame < tag && slots[i].frame + 2 >= tag &&
				    (newest == NULL || slots[i].frame > newest->frame))
					newest = &slots[i];
			if (newest != NULL) {
				taken = newest;
				stale = YES;
			}
			break;
		}
		had_to_wait = YES;
		[lock waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:deadline - now()]];
	}
	// Textures of another device than the presenter's are no use to it
	if (taken != NULL && taken->motion.device == (wanted ?: device)) {
		found = taken->motion;
		taken->readers++;
	} else
		stale = NO;
	if (stale)
		late++;
	else if (found != nil) {
		matched++;
		if (had_to_wait) {
			waited++;
			wait_total += now() - began;
		}
	} else if (!refused_frame)
		missed++;
	[lock unlock];
	}
	return found;
}

void FGProxyDone(id<MTLTexture> motion)
{
	if (motion == nil || lock == nil)
		return;
	[lock lock];
	for (int i = 0; i < proxy_slots; i++)
		if (slots[i].motion == motion && slots[i].readers > 0)
			slots[i].readers--;
	[lock unlock];
}

static void write_rows(const char *path, const FGProxyPlane *plane, uint32_t bytes_per_pixel)
{
	FILE *f = fopen(path, "wb");
	for (uint32_t y = 0; f != NULL && y < plane->height; y++)
		fwrite((const uint8_t *)plane->data + (size_t)y * plane->row_bytes, bytes_per_pixel, plane->width, f);
	if (f != NULL)
		fclose(f);
}

// Tests only, on the proxy's thread: the motion converted here too, as the GPU's copy is not waited for
static void dump(const FGProxyFrame *frame, int stride)
{
	const char *dir = getenv("CARTOUCHE_FRAMEGEN_FFX_DUMP");
	const char *from_text = getenv("CARTOUCHE_FRAMEGEN_FFX_DUMP_FROM"), *count_text = getenv("CARTOUCHE_FRAMEGEN_FFX_DUMP_COUNT");
	uint64_t from = from_text ? strtoull(from_text, NULL, 10) : 1, count = count_text ? strtoull(count_text, NULL, 10) : 8;
	if (dir == NULL || frame->frame < from || frame->frame >= from + count)
		return;
	char path[1024];
	const FGProxyPlane *m = &frame->motion;
	BOOL full = m->format == fg_proxy_r32g32_float || m->format == fg_proxy_r32g32b32a32_float;
	float *pixels = malloc((size_t)m->width * m->height * 2 * sizeof(float));
	for (uint32_t y = 0; pixels != NULL && y < m->height; y++) {
		const uint8_t *row = (const uint8_t *)m->data + (size_t)y * m->row_bytes;
		for (uint32_t x = 0; x < m->width; x++)
			for (int c = 0; c < 2; c++)
				pixels[((size_t)y * m->width + x) * 2 + c] =
					(full ? ((const float *)row)[stride * x + c] : (float)((const _Float16 *)row)[stride * x + c]) *
					frame->motion_scale[c];
	}
	snprintf(path, sizeof(path), "%s/motion-%llu-%ux%u.f32", dir, (unsigned long long)frame->frame, m->width, m->height);
	FILE *f = fopen(path, "wb");
	if (f != NULL && pixels != NULL)
		fwrite(pixels, sizeof(float) * 2, (size_t)m->width * m->height, f);
	if (f != NULL)
		fclose(f);
	free(pixels);
	snprintf(path, sizeof(path), "%s/depth-%llu-%ux%u.f32", dir, (unsigned long long)frame->frame, frame->depth.width,
	         frame->depth.height);
	write_rows(path, &frame->depth, 4);
	if (frame->color.data != NULL) {
		snprintf(path, sizeof(path), "%s/color-%llu-%ux%u-f%u.raw", dir, (unsigned long long)frame->frame,
		         frame->color.width, frame->color.height, frame->color.format);
		write_rows(path, &frame->color, frame->color.format == fg_proxy_r16g16b16a16_float ? 8 : 4);
	}
}

static id<MTLBuffer> fit(id<MTLBuffer> buffer, NSUInteger length)
{
	return buffer != nil && buffer.length >= length ? buffer
		: [device newBufferWithLength:MAX(length, 1) options:MTLResourceStorageModeShared];
}

// Tests only: a real frame without and with its UI, for score.m
static void dump_ui(const FGProxyFrame *frame)
{
	const char *dir = getenv("CARTOUCHE_FRAMEGEN_FFX_DUMP");
	const char *from_text = getenv("CARTOUCHE_FRAMEGEN_FFX_DUMP_FROM"), *count_text = getenv("CARTOUCHE_FRAMEGEN_FFX_DUMP_COUNT");
	uint64_t from = from_text ? strtoull(from_text, NULL, 10) : 1, count = count_text ? strtoull(count_text, NULL, 10) : 8;
	if (ui_frames++ == 0)
		fprintf(stderr, "framegen: ffx ui frame %llu without ui %ux%u format %u, final %ux%u format %u\n",
		        (unsigned long long)frame->frame, frame->color.width, frame->color.height, frame->color.format,
		        frame->final.width, frame->final.height, frame->final.format);
	if (dir == NULL || frame->frame < from || frame->frame >= from + count)
		return;
	char path[1024];
	snprintf(path, sizeof(path), "%s/hudless-%llu-%ux%u-f%u.raw", dir, (unsigned long long)frame->frame,
	         frame->color.width, frame->color.height, frame->color.format);
	write_rows(path, &frame->color, 4);
	snprintf(path, sizeof(path), "%s/final-%llu-%ux%u-f%u.raw", dir, (unsigned long long)frame->frame,
	         frame->final.width, frame->final.height, frame->final.format);
	write_rows(path, &frame->final, 4);
}

// Called by the proxy's delivery thread only, once the GPU wrote the copies
static void take_frame(FGProxyFrame *frame);

__attribute__((visibility("default"))) void cartouche_framegen_ffx_frame(FGProxyFrame *frame)
{
	@autoreleasepool {
		take_frame(frame);
	}
}

static void take_frame(FGProxyFrame *frame)
{
	if (frame->kind == fg_proxy_ui) {
		dump_ui(frame);
		return;
	}
	uint64_t t0 = mach_absolute_time();
	const FGProxyPlane *m = &frame->motion;
	int stride = motion_stride(m->format);
	warm();
	if (stride == 0 || !ready) {
		if (frames++ == 0)
			fprintf(stderr, "framegen: ffx frames not read: motion format %u, metal %d\n", m->format, ready);
		return;
	}
	// The oldest slot that no GPU work is converting or reading; none free drops this frame
	[lock lock];
	Slot *slot = NULL;
	for (int i = 0; i < proxy_slots; i++)
		if (slots[i].state != slot_converting && slots[i].readers == 0 && (slot == NULL || slots[i].frame < slot->frame))
			slot = &slots[i];
	if (slot != NULL) {
		slot->frame = frame->frame;
		slot->state = slot_converting;
	} else
		busy++;
	[lock unlock];
	if (slot == NULL)
		return;
	NSUInteger motion_bytes = (NSUInteger)m->row_bytes * m->height, depth_bytes = (NSUInteger)frame->depth.row_bytes * frame->depth.height;
	slot->raw = fit(slot->raw, motion_bytes);
	slot->depth = fit(slot->depth, depth_bytes);
	slot->bad = fit(slot->bad, sizeof(uint32_t));
	if (slot->motion == nil || slot->motion.width != m->width || slot->motion.height != m->height) {
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
		                                                                             width:m->width
		                                                                            height:m->height
		                                                                         mipmapped:NO];
		d.storageMode = MTLStorageModePrivate;
		d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		slot->motion = [device newTextureWithDescriptor:d];
	}
	if (slot->raw == nil || slot->depth == nil || slot->bad == nil || slot->motion == nil) {
		[lock lock];
		slot->state = slot_empty;
		slot->frame = 0;
		missed++;
		[lock unlock];
		return;
	}
	memcpy(slot->raw.contents, m->data, motion_bytes);
	memcpy(slot->depth.contents, frame->depth.data, depth_bytes);
	*(uint32_t *)slot->bad.contents = 0;
	BOOL full = m->format == fg_proxy_r32g32_float || m->format == fg_proxy_r32g32b32a32_float;
	// FFX's motion times its scale is in pixels, toward the previous frame, as MetalFX's
	Layout layout = { m->row_bytes / (full ? 4 : 2), (uint32_t)stride, m->width, m->height,
		              { frame->motion_scale[0], frame->motion_scale[1] }, (float)MAX(m->width, m->height) };
	id<MTLCommandBuffer> buffer = [queue commandBuffer];
	id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
	[compute setComputePipelineState:to_pixels[full]];
	[compute setBuffer:slot->raw offset:0 atIndex:0];
	[compute setBytes:&layout length:sizeof(layout) atIndex:1];
	[compute setBuffer:slot->bad offset:0 atIndex:2];
	[compute setTexture:slot->motion atIndex:0];
	[compute dispatchThreads:MTLSizeMake(m->width, m->height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
	[compute endEncoding];
	uint64_t number = frame->frame, pixels = (uint64_t)m->width * m->height;
	BOOL reset = frame->reset != 0;
	[buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
		uint32_t bad = *(const uint32_t *)slot->bad.contents;
		double at = now();
		[lock lock];
		if (slot->frame == number) {
			slot->state = reset || bad * 500 > pixels ? slot_refused : slot_ready;
			refused += slot->state == slot_refused;
		}
		if (presents[number % presents_kept].frame == number)
			delays[delay_count++ % delays_kept] = (at - presents[number % presents_kept].at) * 1000;
		gpu_us += (done.GPUEndTime - done.GPUStartTime) * 1e6;
		[lock broadcast];
		[lock unlock];
	}];
	[buffer commit];
	mach_timebase_info_data_t base;
	mach_timebase_info(&base);
	frame->copy_us = (double)(mach_absolute_time() - t0) * base.numer / base.denom / 1000.0;
	copy_us += frame->copy_us;
	copy_max_us = frame->copy_us > copy_max_us ? frame->copy_us : copy_max_us;
	dump(frame, stride);
	if (frames++ == 0)
		fprintf(stderr,
		        "framegen: ffx engine data motion=%ux%u format=%u scale=%.1f,%.1f depth=%ux%u format=%u jitter=%.3f,%.3f "
		        "reset=%u flags=0x%x color=%ux%u format=%u\n",
		        m->width, m->height, m->format, frame->motion_scale[0], frame->motion_scale[1], frame->depth.width,
		        frame->depth.height, frame->depth.format, frame->jitter[0], frame->jitter[1], frame->reset, frame->flags,
		        frame->color.data ? frame->color.width : 0, frame->color.data ? frame->color.height : 0, frame->color.format);
	if (frames % 120 == 0) {
		[lock lock];
		fprintf(stderr, "framegen: ffx library frames=%llu memcpy_avg_us=%.1f memcpy_max_us=%.1f bytes=%lu gpu_avg_us=%.1f\n",
		        (unsigned long long)frames, copy_us / (double)frames, copy_max_us,
		        (unsigned long)(motion_bytes + depth_bytes), gpu_us / (double)frames);
		print_stats();
		[lock unlock];
	}
}
