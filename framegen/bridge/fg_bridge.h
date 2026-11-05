// What the Wine bridge and the frame generation library share. cartouche_bridge.dll, a Wine
// builtin in the game, calls its unix half cartouche_bridge.so through __wine_unix_call; the
// .so finds the library with dlsym and writes one message per frame into the library's ring.
#pragma once
#include <stdint.h>

#define FG_BRIDGE_RING "cartouche_framegen_bridge"
#define FG_BRIDGE_STATS "cartouche_framegen_bridge_stats"
#define FG_BRIDGE_METAL "cartouche_framegen_metal"

enum { fg_bridge_slots = 256 };

// __wine_unix_call codes, the order of __wine_unix_call_funcs
enum { fg_bridge_attach, fg_bridge_frame, fg_bridge_stats, fg_bridge_metal };

// sent is the game's rdtsc: under Rosetta it counts mach_continuous_time's nanoseconds
typedef struct {
	uint64_t frame;
	uint64_t sent;
} FGBridgeMessage;

// One-way: from the game's rdtsc to the library's reader; lost counts frame numbers never seen
typedef struct {
	uint64_t received, lost, disordered, full;
	double p50_us, p99_us, max_us;
} FGBridgeStats;

// Metal textures behind the game's D3D11 resources (DXMT's IMTLD3D11DeviceExt1, patched), handed
// to the library in one synchronous call. The library waits for the fence's shared event to reach
// wait before it reads them, and signals it to signal once done. probe (tests only) waits for the
// GPU on the game's thread; upscale does not.
enum { fg_metal_probe = 1, fg_metal_upscale = 2 };
enum { fg_metal_color, fg_metal_depth, fg_metal_motion, fg_metal_output, fg_metal_textures };

typedef struct {
	uint32_t op, reset;
	uint64_t event, wait, signal;
	uint64_t texture[fg_metal_textures];
	float jitter[2], motion_scale[2], sharpness, pad;
	// filled by the library: what each handle is, and for probe a hash of its texels
	uint32_t width[fg_metal_textures], height[fg_metal_textures], format[fg_metal_textures];
	uint64_t hash[fg_metal_textures];
	// the GPU time of the last finished upscale
	double gpu_ms;
	int32_t status;
	uint32_t pad2;
} FGBridgeMetal;

#ifndef _WIN32
#include <stdatomic.h>

typedef struct {
	_Atomic uint64_t head; // written by the .so
	char pad0[56];
	_Atomic uint64_t tail; // by the library's reader
	_Atomic uint32_t waiting;
	char pad1[52];
	_Atomic uint64_t full; // messages dropped on a full ring
	FGBridgeMessage slots[fg_bridge_slots];
} FGBridgeRing;
#endif
