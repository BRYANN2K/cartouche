// The metrics block the library publishes for other processes (the Cartouche app, an overlay
// outside the game). Plain C, the same layout on x86_64 and arm64. Layout and reading rules:
// docs/research/frame-gen-v2/overlay.md.
//
// Name: "/cartouche-metrics.<pid>" (shm_open), 4096 bytes, mode 0444: only the game writes.
// Reading: open O_RDONLY, mmap PROT_READ, check magic, version and size, then copy while
// sequence is even and the same before and after the copy.

#ifndef FG_METRICS_SHM_H
#define FG_METRICS_SHM_H

#include <stddef.h>
#include <stdint.h>

#define FG_METRICS_MAGIC 0x584d5443u // "CTMX"
#define FG_METRICS_VERSION 1u
#define FG_METRICS_SIZE 4096u
#define FG_METRICS_FRAMES 256u
#define FG_METRICS_NAME "/cartouche-metrics.%d"

enum { FG_UPSCALE_NONE, FG_UPSCALE_SPATIAL, FG_UPSCALE_TEMPORAL };
enum { FG_FRAMEGEN_OFF, FG_FRAMEGEN_ON, FG_FRAMEGEN_PAUSED, FG_FRAMEGEN_GAME };
enum { FG_PAUSE_NONE, FG_PAUSE_SLOW_BASE, FG_PAUSE_SLOW_DISPLAY };

typedef struct {
	uint32_t magic;
	uint32_t version;
	uint32_t size;
	int32_t pid;
	uint32_t sequence;       // odd while the game writes
	uint32_t seconds;        // whole seconds measured so far
	uint64_t updated_ns;     // CLOCK_MONOTONIC_RAW at the last write

	float presented_fps;     // frames shown per second, generated ones included
	float real_fps;          // frames the game rendered per second
	float frame_ms;          // mean interval between shown frames
	float low1_fps;          // real frames: mean of the slowest 1 % of intervals, as fps
	float framegen_gpu_ms;   // our generation pass per generated frame
	float present_gpu_ms;    // our present pass per real frame: upscale, copy, overlay
	float added_latency_ms;  // real frames: game present to screen, less one refresh
	float latency_max_ms;
	float cpu_percent;       // this process, 100 per busy core
	float gpu_percent;       // the whole GPU, all processes
	float refresh_hz;
	float reserved0;
	uint64_t ram_bytes;      // this process's footprint
	uint64_t generated;      // frames generated since start
	uint64_t dropped;        // frames never shown since start
	uint32_t dropped_second; // in the last second
	int32_t thermal;         // NSProcessInfoThermalState: 0 nominal to 3 critical
	int32_t upscale;         // FG_UPSCALE_*
	uint32_t upscale_in_width, upscale_in_height, upscale_out_width, upscale_out_height;
	int32_t framegen;        // FG_FRAMEGEN_*
	int32_t framegen_factor; // shown frames per real one when on
	int32_t framegen_ane;    // 1 when the Neural Engine's flow served frames in the last second
	int32_t pause_reason;    // FG_PAUSE_*

	uint32_t frame_count;    // shown intervals written so far; the last is at (frame_count - 1) % FG_METRICS_FRAMES
	uint32_t reserved1;
	float frame_ms_ring[FG_METRICS_FRAMES];
} FGMetricsBlock;

_Static_assert(offsetof(FGMetricsBlock, presented_fps) == 32, "metrics layout");
_Static_assert(offsetof(FGMetricsBlock, ram_bytes) == 80, "metrics layout");
_Static_assert(offsetof(FGMetricsBlock, frame_count) == 148, "metrics layout");
_Static_assert(offsetof(FGMetricsBlock, frame_ms_ring) == 156, "metrics layout");
_Static_assert(sizeof(FGMetricsBlock) <= FG_METRICS_SIZE, "metrics block");

#endif
