// What the FFX proxy and the frame generation library share. The proxy, a Wine builtin named
// like AMD's FFX DLL, forwards the game's calls to AMD's own and tells its unix half about them;
// the unix half finds the library with dlsym, as the bridge in framegen/bridge does.
#pragma once
#include <stdint.h>

#define FG_PROXY_LOG "cartouche_framegen_ffx_log"
#define FG_PROXY_FRAME "cartouche_framegen_ffx_frame"
#define FG_PROXY_SHARED "cartouche_framegen_ffx_shared"

// __wine_unix_call codes, the order of __wine_unix_call_funcs
enum { fg_proxy_attach, fg_proxy_log, fg_proxy_frame };

// Written by the proxy, read by the library, in the same process. signaled: the frame number of
// the last copy whose command list the game submitted, so the frame the game presents next.
// game_generates: FSR frame generation is on in the game, so the library's stands down.
typedef struct {
	volatile uint64_t signaled;
	volatile uint32_t game_generates;
} FGProxyShared;

// The DXGI formats the library reads from a copy
enum {
	fg_proxy_r32g32b32a32_float = 2,
	fg_proxy_r16g16b16a16_float = 10,
	fg_proxy_r11g11b10_float = 26,
	fg_proxy_r8g8b8a8_unorm = 28,
	fg_proxy_r32g32_float = 16,
	fg_proxy_r16g16_float = 34,
	fg_proxy_d32_float = 40,
	fg_proxy_r32_float = 41
};

typedef struct {
	const void *data;
	uint32_t width, height, row_bytes, format;
} FGProxyPlane;

// One frame's depth and motion, copied by the game's GPU into a readback buffer and mapped, and
// for tests (CARTOUCHE_FFX_COPY=2) the upscaler's output. The library copies them out before the
// call returns. Times are QueryPerformanceCounter ticks,
// which Wine counts in 100 ns.
enum { fg_proxy_vectors, fg_proxy_ui };

// kind fg_proxy_ui (tests, CARTOUCHE_FFX_UI=1 with copies): color is the real frame without its
// UI as AMD's swapchain hands it to the game's present callback, final the frame the callback
// made with the UI on it.
typedef struct {
	uint64_t frame;
	uint32_t kind;
	FGProxyPlane depth, motion, color, final;
	float motion_scale[2], jitter[2];
	uint32_t reset, flags;
	// Proxy only: QueryPerformanceCounter ticks at recording and once the fence passed
	int64_t recorded, completed;
	// Filled by the library: how long its copy took, in microseconds
	double copy_us;
} FGProxyFrame;
