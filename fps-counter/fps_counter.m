// Frame counter for Windows games (P8). D3DMetal, DXMT and DXVK through MoltenVK all
// take their drawables from CAMetalLayer, so counting nextDrawable counts presented
// frames for every backend. One line per second goes to a file in the folder the
// run script made for this launch; the app reads it back after the game ends.
//
// Line format: "<unix time> <frames> <frontmost> <width> <height>". Frontmost is 1
// when the process's NSApp is active, or when the process has no NSApp at all.

#import <QuartzCore/CAMetalLayer.h>

#import <dlfcn.h>
#import <fcntl.h>
#import <limits.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <unistd.h>

#if defined(__x86_64__)
#define counter_arch "x86_64"
#elif defined(__arm64__)
#define counter_arch "arm64"
#else
#define counter_arch "other"
#endif

static char samples_dir[PATH_MAX];
static char samples_path[PATH_MAX];
static _Atomic uint64_t frames;
static _Atomic uint32_t drawable_width;
static _Atomic uint32_t drawable_height;
static atomic_flag sampler_started = ATOMIC_FLAG_INIT;
static id (*next_next_drawable)(id, SEL);

static int frontmost(void)
{
	id *app_slot = (id *)dlsym(RTLD_DEFAULT, "NSApp");
	id app = app_slot != NULL ? *app_slot : nil;

	if (app == nil)
		return 1;
	return ((BOOL (*)(id, SEL))objc_msgSend)(app, sel_registerName("isActive")) ? 1 : 0;
}

static void sleep_until(const struct timespec *deadline)
{
	for (;;) {
		struct timespec now, left;
		clock_gettime(CLOCK_MONOTONIC, &now);
		left.tv_sec = deadline->tv_sec - now.tv_sec;
		left.tv_nsec = deadline->tv_nsec - now.tv_nsec;
		if (left.tv_nsec < 0) {
			left.tv_sec -= 1;
			left.tv_nsec += 1000000000L;
		}
		if (left.tv_sec < 0)
			return;
		if (nanosleep(&left, NULL) == 0)
			return;
	}
}

static void *sampler(void *unused)
{
	(void)unused;
	if (samples_path[0] == '\0')
		return NULL;
	int fd = open(samples_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	if (fd < 0)
		return NULL;

	char line[128];
	int len = snprintf(line, sizeof(line), "# cartouche-fps 1 pid=%d arch=%s\n", getpid(), counter_arch);
	if (write(fd, line, (size_t)len) != len) {
		close(fd);
		return NULL;
	}

	// Steps from a fixed start, so a slow write does not drift the seconds
	struct timespec deadline;
	clock_gettime(CLOCK_MONOTONIC, &deadline);
	for (;;) {
		deadline.tv_sec += 1;
		sleep_until(&deadline);
		uint64_t count = atomic_exchange_explicit(&frames, 0, memory_order_relaxed);
		int front;
		@autoreleasepool {
			front = frontmost();
		}
		len = snprintf(line, sizeof(line), "%ld %llu %d %u %u\n", (long)time(NULL),
		               (unsigned long long)count, front,
		               atomic_load_explicit(&drawable_width, memory_order_relaxed),
		               atomic_load_explicit(&drawable_height, memory_order_relaxed));
		if (write(fd, line, (size_t)len) != len)
			break;
	}
	close(fd);
	return NULL;
}

static void start_sampler(void)
{
	pthread_attr_t attr;
	pthread_t thread;

	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	pthread_create(&thread, &attr, sampler, NULL);
	pthread_attr_destroy(&attr);
}

static id hook_next_drawable(id layer, SEL selector)
{
	id drawable = next_next_drawable(layer, selector);

	if (drawable != nil) {
		// The first frame of each second records the size the game renders at
		if (atomic_fetch_add_explicit(&frames, 1, memory_order_relaxed) == 0) {
			CGSize size = ((CAMetalLayer *)layer).drawableSize;
			atomic_store_explicit(&drawable_width, (uint32_t)size.width, memory_order_relaxed);
			atomic_store_explicit(&drawable_height, (uint32_t)size.height, memory_order_relaxed);
		}
		if (!atomic_flag_test_and_set_explicit(&sampler_started, memory_order_relaxed))
			start_sampler();
	}
	return drawable;
}

static int name_samples(void)
{
	int len = snprintf(samples_path, sizeof(samples_path), "%s/samples-%d", samples_dir, getpid());
	return len > 0 && (size_t)len < sizeof(samples_path);
}

// A forked child has no sampler thread, so its first frame starts one, in its own file
static void forked_child(void)
{
	atomic_flag_clear(&sampler_started);
	atomic_store(&frames, 0);
	if (!name_samples())
		samples_path[0] = '\0';
}

static void note_probe(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		return;
	(void)!write(fd, counter_arch "\n", strlen(counter_arch) + 1);
	close(fd);
}

__attribute__((constructor)) static void fps_counter_load(void)
{
	// The run script's check that this runner's loader accepts the library
	const char *probe = getenv("CARTOUCHE_FPS_PROBE");
	if (probe != NULL && probe[0] == '/')
		note_probe(probe);

	const char *dir = getenv("CARTOUCHE_FPS_DIR");
	if (dir == NULL || dir[0] != '/')
		return;
	if (strlcpy(samples_dir, dir, sizeof(samples_dir)) >= sizeof(samples_dir) || !name_samples())
		return;

	Class layer = objc_getClass("CAMetalLayer");
	Method method = layer != Nil ? class_getInstanceMethod(layer, @selector(nextDrawable)) : NULL;
	if (method == NULL)
		return;
	next_next_drawable = (id (*)(id, SEL))method_getImplementation(method);
	method_setImplementation(method, (IMP)hook_next_drawable);
	pthread_atfork(NULL, NULL, forked_child);
}
