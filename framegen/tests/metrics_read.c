// Reads a game's shared metrics block from another process, as the Cartouche app or an overlay
// outside the game would: native arm64 against the library's x86_64 writer.
// Usage: metrics-read <pid>. Prints one "name=value" line; 1 when there is no valid block.

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "../fg_metrics_shm.h"

int main(int argc, char **argv)
{
	if (argc < 2)
		return 2;
	char name[32];
	snprintf(name, sizeof(name), FG_METRICS_NAME, atoi(argv[1]));
	int fd = shm_open(name, O_RDONLY);
	if (fd < 0) {
		printf("missing %s: %s\n", name, strerror(errno));
		return 1;
	}
	const FGMetricsBlock *block = mmap(NULL, FG_METRICS_SIZE, PROT_READ, MAP_SHARED, fd, 0);
	close(fd);
	if (block == MAP_FAILED)
		return 1;
	if (block->magic != FG_METRICS_MAGIC || block->version != FG_METRICS_VERSION || block->size != FG_METRICS_SIZE) {
		printf("invalid magic=%08x version=%u size=%u\n", block->magic, block->version, block->size);
		return 1;
	}
	FGMetricsBlock copy;
	uint32_t before, after;
	int tries = 0;
	do {
		before = __atomic_load_n(&block->sequence, __ATOMIC_ACQUIRE);
		memcpy(&copy, block, sizeof(copy));
		__atomic_thread_fence(__ATOMIC_ACQUIRE);
		after = __atomic_load_n(&block->sequence, __ATOMIC_RELAXED);
	} while (((before & 1) != 0 || before != after) && ++tries < 1000);
	int writable = shm_open(name, O_RDWR);
	if (writable >= 0)
		close(writable);
	printf("pid=%d seconds=%u presented=%.1f real=%.1f frame_ms=%.2f low1=%.1f framegen=%d factor=%d ane=%d "
	       "fg_gpu_ms=%.2f present_gpu_ms=%.2f added_latency_ms=%.1f upscale=%d %ux%u->%ux%u frames=%u last_ms=%.2f "
	       "cpu=%.0f gpu=%.0f ram_mb=%.0f thermal=%d dropped=%llu write=%s tries=%d\n",
	       copy.pid, copy.seconds, copy.presented_fps, copy.real_fps, copy.frame_ms, copy.low1_fps, copy.framegen,
	       copy.framegen_factor, copy.framegen_ane, copy.framegen_gpu_ms, copy.present_gpu_ms, copy.added_latency_ms,
	       copy.upscale, copy.upscale_in_width, copy.upscale_in_height, copy.upscale_out_width, copy.upscale_out_height,
	       copy.frame_count, copy.frame_count ? copy.frame_ms_ring[(copy.frame_count - 1) % FG_METRICS_FRAMES] : 0,
	       copy.cpu_percent, copy.gpu_percent, copy.ram_bytes / 1e6, copy.thermal, (unsigned long long)copy.dropped,
	       writable >= 0 ? "allowed" : "refused", tries);
	return tries < 1000 ? 0 : 1;
}
