#import "fg_metrics.h"

#import <IOKit/IOKitLib.h>

#import <fcntl.h>
#import <mach/mach.h>
#import <math.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/resource.h>
#import <time.h>
#import <unistd.h>

enum { real_count = 600 };

static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static FGMetricsBlock current;
static FGMetricsBlock *shared;
static char shared_name[32];
static double real_ring[real_count];
static unsigned real_at;
static double present_gpu;
static unsigned present_count;
static _Atomic int running;
static dispatch_source_t sampler;

// Under lock: the shared block follows current, readers see no half-written copy
static void publish(void)
{
	current.updated_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
	if (shared == NULL)
		return;
	uint32_t sequence = shared->sequence;
	atomic_store_explicit((_Atomic uint32_t *)&shared->sequence, sequence + 1, memory_order_relaxed);
	atomic_thread_fence(memory_order_release);
	size_t header = offsetof(FGMetricsBlock, presented_fps);
	memcpy((char *)shared + header, (const char *)&current + header, sizeof(current) - header);
	shared->seconds = current.seconds;
	shared->updated_ns = current.updated_ns;
	atomic_store_explicit((_Atomic uint32_t *)&shared->sequence, sequence + 2, memory_order_release);
}

static void unpublish(void)
{
	if (shared_name[0] != 0)
		shm_unlink(shared_name);
}

static void open_shared(void)
{
	char name[sizeof(shared_name)];
	snprintf(name, sizeof(name), FG_METRICS_NAME, getpid());
	// A block left by a dead process that had our pid
	shm_unlink(name);
	int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0444);
	if (fd < 0)
		return;
	void *at = MAP_FAILED;
	if (ftruncate(fd, FG_METRICS_SIZE) == 0)
		at = mmap(NULL, FG_METRICS_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	if (at == MAP_FAILED) {
		shm_unlink(name);
		return;
	}
	shared = at;
	shared->magic = FG_METRICS_MAGIC;
	shared->version = FG_METRICS_VERSION;
	shared->size = FG_METRICS_SIZE;
	shared->pid = getpid();
	strlcpy(shared_name, name, sizeof(shared_name));
	atexit(unpublish);
}

// The whole GPU's busy share, from the accelerator's statistics in the IO registry
static double gpu_percent(void)
{
	io_iterator_t iterator;
	if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching("IOAccelerator"), &iterator) != KERN_SUCCESS)
		return -1;
	double percent = -1;
	io_object_t service;
	while ((service = IOIteratorNext(iterator)) != 0) {
		CFTypeRef stats = IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
		if (stats != NULL && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
			CFTypeRef value = CFDictionaryGetValue(stats, CFSTR("Device Utilization %"));
			int64_t v;
			if (value != NULL && CFGetTypeID(value) == CFNumberGetTypeID() &&
			    CFNumberGetValue(value, kCFNumberSInt64Type, &v))
				percent = fmax(percent, (double)v);
		}
		if (stats != NULL)
			CFRelease(stats);
		IOObjectRelease(service);
	}
	IOObjectRelease(iterator);
	return percent;
}

static double cpu_seconds(void)
{
	struct rusage usage;
	if (getrusage(RUSAGE_SELF, &usage) != 0)
		return 0;
	return (double)usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + (double)usage.ru_stime.tv_sec +
	       usage.ru_stime.tv_usec / 1e6;
}

static uint64_t footprint(void)
{
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
		return 0;
	return info.phys_footprint;
}

static void sample(void)
{
	static double last_cpu, last_wall;
	double cpu = cpu_seconds(), wall = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
	double percent = last_wall > 0 && wall > last_wall ? (cpu - last_cpu) / (wall - last_wall) * 100 : 0;
	last_cpu = cpu;
	last_wall = wall;
	double gpu = gpu_percent();
	uint64_t ram = footprint();
	int thermal = (int)NSProcessInfo.processInfo.thermalState;
	os_unfair_lock_lock(&lock);
	current.cpu_percent = (float)percent;
	current.gpu_percent = (float)gpu;
	current.ram_bytes = ram;
	current.thermal = thermal;
	publish();
	os_unfair_lock_unlock(&lock);
}

void FGMetricsStart(BOOL publish_block)
{
	int expected = 0;
	if (!atomic_compare_exchange_strong(&running, &expected, 1))
		return;
	os_unfair_lock_lock(&lock);
	current.magic = FG_METRICS_MAGIC;
	current.version = FG_METRICS_VERSION;
	current.size = FG_METRICS_SIZE;
	current.pid = getpid();
	current.framegen_factor = 1;
	if (publish_block)
		open_shared();
	os_unfair_lock_unlock(&lock);
	sampler = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
	dispatch_source_set_timer(sampler, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
	dispatch_source_set_event_handler(sampler, ^{
		sample();
	});
	dispatch_resume(sampler);
}

BOOL FGMetricsRunning(void)
{
	return atomic_load(&running) != 0;
}

void FGMetricsShown(double ms)
{
	if (!FGMetricsRunning())
		return;
	os_unfair_lock_lock(&lock);
	current.frame_ms_ring[current.frame_count % FG_METRICS_FRAMES] = (float)ms;
	current.frame_count++;
	if (shared != NULL) {
		uint32_t sequence = shared->sequence;
		atomic_store_explicit((_Atomic uint32_t *)&shared->sequence, sequence + 1, memory_order_relaxed);
		atomic_thread_fence(memory_order_release);
		shared->frame_ms_ring[(current.frame_count - 1) % FG_METRICS_FRAMES] = (float)ms;
		shared->frame_count = current.frame_count;
		atomic_store_explicit((_Atomic uint32_t *)&shared->sequence, sequence + 2, memory_order_release);
	}
	os_unfair_lock_unlock(&lock);
}

void FGMetricsReal(double ms)
{
	if (!FGMetricsRunning())
		return;
	os_unfair_lock_lock(&lock);
	real_ring[real_at++ % real_count] = ms;
	os_unfair_lock_unlock(&lock);
}

void FGMetricsPresentGPU(double ms)
{
	if (!FGMetricsRunning())
		return;
	os_unfair_lock_lock(&lock);
	present_gpu += ms;
	present_count++;
	os_unfair_lock_unlock(&lock);
}

static int ascending(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

double FGMetricsLow1(const double *ms, int count)
{
	if (count <= 0)
		return 0;
	double *sorted = malloc(sizeof(double) * (size_t)count);
	if (sorted == NULL)
		return 0;
	memcpy(sorted, ms, sizeof(double) * (size_t)count);
	qsort(sorted, (size_t)count, sizeof(double), ascending);
	int slowest = count / 100 > 0 ? count / 100 : 1;
	double sum = 0;
	for (int i = count - slowest; i < count; i++)
		sum += sorted[i];
	free(sorted);
	return sum > 0 ? 1000 * slowest / sum : 0;
}

void FGMetricsSecondDone(const FGMetricsSecond *second)
{
	if (!FGMetricsRunning())
		return;
	double intervals[real_count];
	os_unfair_lock_lock(&lock);
	int count = real_at < real_count ? (int)real_at : real_count;
	memcpy(intervals, real_ring, sizeof(double) * (size_t)count);
	os_unfair_lock_unlock(&lock);
	double low = FGMetricsLow1(intervals, count);
	os_unfair_lock_lock(&lock);
	current.seconds++;
	current.presented_fps = (float)second->presentedFps;
	current.real_fps = (float)second->realFps;
	current.frame_ms = (float)second->frameMs;
	current.low1_fps = (float)low;
	current.framegen_gpu_ms = (float)second->framegenGpuMs;
	current.present_gpu_ms = present_count ? (float)(present_gpu / present_count) : 0;
	present_gpu = 0;
	present_count = 0;
	current.added_latency_ms = (float)fmax(0, second->latencyMs - second->refreshMs);
	current.latency_max_ms = (float)second->latencyMaxMs;
	current.refresh_hz = second->refreshMs > 0 ? (float)(1000 / second->refreshMs) : 0;
	current.generated = second->generated;
	current.dropped = second->dropped;
	current.dropped_second = second->droppedSecond;
	current.framegen = second->framegen;
	current.framegen_factor = second->factor;
	current.framegen_ane = second->ane;
	current.pause_reason = second->pauseReason;
	publish();
	os_unfair_lock_unlock(&lock);
}

void FGMetricsUpscale(int mode, unsigned inWidth, unsigned inHeight, unsigned outWidth, unsigned outHeight)
{
	if (!FGMetricsRunning())
		return;
	os_unfair_lock_lock(&lock);
	current.upscale = mode;
	current.upscale_in_width = inWidth;
	current.upscale_in_height = inHeight;
	current.upscale_out_width = outWidth;
	current.upscale_out_height = outHeight;
	os_unfair_lock_unlock(&lock);
}

void FGMetricsRead(FGMetricsBlock *block)
{
	os_unfair_lock_lock(&lock);
	*block = current;
	os_unfair_lock_unlock(&lock);
}

const char *FGMetricsName(void)
{
	return shared_name;
}
