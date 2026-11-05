// The library's end of the Wine bridge (framegen/bridge): a ring the .so writes one message
// per frame into, and a reader thread that wakes on each. For now it keeps timing and loss
// numbers only; data from the game's upscaler calls will travel the same way.
#import <Foundation/Foundation.h>

#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/thread_policy.h>
#import <os/lock.h>
#import <os/os_sync_wait_on_address.h>
#import <pthread.h>
#import <stdlib.h>

#import "bridge/fg_bridge.h"

enum { samples_max = 1 << 17 };

static FGBridgeRing bridge_ring;
static os_unfair_lock bridge_lock = OS_UNFAIR_LOCK_INIT;
static uint32_t *samples;
static uint64_t received, lost, disordered, last_frame;

static void *read_ring(void *unused)
{
	(void)unused;
	mach_timebase_info_data_t base;
	mach_timebase_info(&base);
	// Real-time, as an audio thread: a plain thread wakes 50 to 100 us late now and then
	uint32_t us = 1000 * base.denom / base.numer;
	thread_time_constraint_policy_data_t policy = { .period = 0, .computation = 50 * us, .constraint = 200 * us,
		                                            .preemptible = 1 };
	if (thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
	                      (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT) != KERN_SUCCESS)
		pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
	uint64_t tail = 0;
	for (;;) {
		uint64_t head = atomic_load(&bridge_ring.head);
		if (head == tail) {
			atomic_store(&bridge_ring.waiting, 1);
			if (atomic_load(&bridge_ring.head) == tail)
				os_sync_wait_on_address(&bridge_ring.head, tail, sizeof(uint64_t), OS_SYNC_WAIT_ON_ADDRESS_NONE);
			atomic_store(&bridge_ring.waiting, 0);
			continue;
		}
		for (; tail != head; tail++) {
			FGBridgeMessage message = bridge_ring.slots[tail % fg_bridge_slots];
			uint64_t ns = (mach_continuous_time() - message.sent) * base.numer / base.denom;
			os_unfair_lock_lock(&bridge_lock);
			if (received < samples_max)
				samples[received] = ns > UINT32_MAX ? UINT32_MAX : (uint32_t)ns;
			received++;
			if (message.frame > last_frame) {
				lost += message.frame - last_frame - 1;
				last_frame = message.frame;
			} else
				disordered++;
			os_unfair_lock_unlock(&bridge_lock);
		}
		atomic_store(&bridge_ring.tail, tail);
	}
	return NULL;
}

__attribute__((visibility("default"))) FGBridgeRing *cartouche_framegen_bridge(void)
{
	static dispatch_once_t once;
	static BOOL started;
	dispatch_once(&once, ^{
		samples = calloc(samples_max, sizeof(*samples));
		pthread_t thread;
		started = samples != NULL && pthread_create(&thread, NULL, read_ring, NULL) == 0;
		if (started)
			pthread_detach(thread);
	});
	return started ? &bridge_ring : NULL;
}

static int ascending(const void *a, const void *b)
{
	uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
	return (x > y) - (x < y);
}

// Waits up to 100 ms for the reader to drain the ring first
__attribute__((visibility("default"))) void cartouche_framegen_bridge_stats(FGBridgeStats *out)
{
	for (int i = 0; i < 1000 && atomic_load(&bridge_ring.tail) != atomic_load(&bridge_ring.head); i++)
		usleep(100);
	os_unfair_lock_lock(&bridge_lock);
	uint64_t count = received < samples_max ? received : samples_max;
	uint32_t *sorted = count > 0 ? malloc(count * sizeof(*sorted)) : NULL;
	if (sorted != NULL)
		memcpy(sorted, samples, count * sizeof(*sorted));
	*out = (FGBridgeStats){ .received = received, .lost = lost, .disordered = disordered,
		                    .full = atomic_load(&bridge_ring.full) };
	os_unfair_lock_unlock(&bridge_lock);
	if (sorted == NULL)
		return;
	qsort(sorted, count, sizeof(*sorted), ascending);
	out->p50_us = sorted[count / 2] / 1000.0;
	out->p99_us = sorted[count * 99 / 100] / 1000.0;
	out->max_us = sorted[count - 1] / 1000.0;
	free(sorted);
}
