// A Direct3D 11 stand-in game for frame generation: spinning cubes over a checkered ground,
// a camera that sways while flying forward, and a still striped HUD in the bottom left.
// It runs in Wine on DXMT or D3DMetal like a real game, at a capped rate.
// Usage: scene.exe [fps] [seconds] [jitter 0..1, the share the GPU time varies by] [dlss] [halton] [mfx]
//                  [bridge:N] [probe:N] [ss] [capture:F[:N]:path] [mouse]
// Prints "rendered N" on exit. bridge:N loads cartouche_bridge.dll, sends it one message per
// frame for N frames, then prints the bridge's numbers. halton jitters the DLSS render as a game
// does (16 phases). mfx: as dlss, jittered, but our MetalFX chain does the upscale on the Metal
// textures DXMT's patched IMTLD3D11DeviceExt1 hands out (framegen/dxmt), through the bridge.
// probe:N: for N frames the library hashes the Metal textures behind colour, depth, motion and
// output, and the scene its own D3D11 copies of them. ss: twice the size, no upscale, the
// reference. capture:F:path writes frame F before the HUD to path.ppm, and the render-size colour
// to path-low.ppm; capture:F:N:path writes frames F to F+N-1 to path-<i>.ppm. mouse: a white mark
// where each left click lands, and "click X Y" in client pixels; a click never activates the window.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <d3d11_4.h>
#include <d3dcompiler.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <x86intrin.h>

#include "../../bridge/fg_bridge.h"

static const char *source =
	"cbuffer Frame : register(b0) { row_major float4x4 viewProj; row_major float4x4 prevViewProj;\n"
	"  float time; float dist; float load; float prevTime; float prevDist; float2 size; float jx; float jy; float3 pad; };\n"
	"struct V { float4 p : SV_Position; float3 local : LOCAL; float3 normal : NORMAL; float depth : DEPTH; float3 tint : TINT;\n"
	"  float4 cur : CUR; float4 prev : PREV; };\n"
	"float hash(float n) { return frac(sin(n * 12.9898) * 43758.5453); }\n"
	"static const float3 normals[6] = { float3(1,0,0), float3(-1,0,0), float3(0,1,0), float3(0,-1,0), float3(0,0,1), float3(0,0,-1) };\n"
	"static const float3 axisA[6] = { float3(0,1,0), float3(0,0,1), float3(0,0,1), float3(1,0,0), float3(1,0,0), float3(0,1,0) };\n"
	"static const float3 axisB[6] = { float3(0,0,1), float3(0,1,0), float3(1,0,0), float3(0,0,1), float3(0,1,0), float3(1,0,0) };\n"
	"static const float2 corners[6] = { float2(0,0), float2(0,1), float2(1,0), float2(1,0), float2(0,1), float2(1,1) };\n"
	"float3 cube_world(uint v, uint inst, float t, float d, out float3 normal) {\n"
	"  uint face = v / 6; float2 c = corners[v % 6] * 2 - 1;\n"
	"  float3 local = normals[face] + c.x * axisA[face] + c.y * axisB[face];\n"
	"  float h = hash(float(inst) + 1.0), a = t * (0.4 + h * 1.6) + h * 6.28;\n"
	"  float3x3 ry = float3x3(cos(a), 0, sin(a), 0, 1, 0, -sin(a), 0, cos(a));\n"
	"  float3x3 rx = float3x3(1, 0, 0, 0, cos(a * 0.7), -sin(a * 0.7), 0, sin(a * 0.7), cos(a * 0.7));\n"
	"  float gx = float(inst % 8) - 3.5, gz = float(inst / 8);\n"
	"  float z = -fmod(gz * 5.0 - fmod(d, 160.0) + 160.0, 160.0) - 3.0;\n"
	"  normal = mul(rx, mul(ry, normals[face]));\n"
	"  return mul(rx, mul(ry, local)) * (0.6 + h * 0.5) + float3(gx * 4.5, (hash(float(inst) * 3.1) - 0.3) * 3.0, z);\n"
	"}\n"
	"float4 jittered(float4 p) { return float4(p.xy + float2(jx, -jy) * 2.0 / size * p.w, p.zw); }\n"
	"V cube(uint v : SV_VertexID, uint inst : SV_InstanceID) {\n"
	"  float3 normal, before; float3 world = cube_world(v, inst, time, dist, normal);\n"
	"  float3 then = cube_world(v, inst, prevTime, prevDist, before);\n"
	"  uint face = v / 6; float2 c = corners[v % 6] * 2 - 1; float h = hash(float(inst) + 1.0);\n"
	"  V o; o.p = mul(viewProj, float4(world, 1)); o.cur = o.p; o.p = jittered(o.p); o.local = normals[face] + c.x * axisA[face] + c.y * axisB[face];\n"
	"  o.normal = normal; o.depth = -world.z; o.tint = 0.45 + 0.45 * cos(6.28 * (h + float3(0, 0.33, 0.67)));\n"
	"  o.prev = mul(prevViewProj, float4(then, 1)); return o;\n"
	"}\n"
	"V ground(uint v : SV_VertexID) {\n"
	"  float2 c = float2(v & 1, v >> 1);\n"
	"  float3 world = float3((c.x * 2 - 1) * 80.0, -2.5, -c.y * 170.0);\n"
	"  V o; o.p = mul(viewProj, float4(world, 1)); o.cur = o.p; o.p = jittered(o.p); o.local = float3(world.x, 0, world.z - dist);\n"
	"  o.normal = float3(0, 1, 0); o.depth = -world.z; o.tint = float3(0.55, 0.57, 0.62);\n"
	"  o.prev = mul(prevViewProj, float4(world + float3(0, 0, prevDist - dist), 1)); return o;\n"
	"}\n"
	"struct Out { float4 color : SV_Target0; float2 motion : SV_Target1; };\n"
	"Out lit(V i) {\n"
	"  float3 q = floor(i.local * 2.0);\n"
	"  float check = fmod(abs(q.x + q.y + q.z), 2.0) < 0.5 ? 1.0 : 0.55;\n"
	"  float light = 0.35 + 0.65 * saturate(dot(normalize(i.normal), normalize(float3(0.4, 0.8, 0.45))));\n"
	"  float fog = saturate(exp(-i.depth * 0.018));\n"
	"  float3 c = lerp(float3(0.11, 0.115, 0.14), i.tint * check * light, fog);\n"
	"  // Extra work that varies frame to frame, to make the GPU time jitter\n"
	"  float waste = 0; for (int k = 0; k < (int)load; k++) waste += sin(waste + k) * 1e-7;\n"
	"  Out o; o.color = float4(c + waste, 1);\n"
	"  // Where this pixel was in the previous frame, in render pixels, as DLSS takes it\n"
	"  o.motion = (i.prev.xy / i.prev.w - i.cur.xy / i.cur.w) * float2(0.5, -0.5) * size; return o;\n"
	"}\n"
	"struct H { float4 p : SV_Position; float2 uv : UV; };\n"
	"H hud(uint v : SV_VertexID) { float2 c = float2(v & 1, v >> 1); H o;\n"
	"  o.p = float4(-0.97 + c.x * 0.36, -0.95 + c.y * 0.2, 0, 1); o.uv = c; return o; }\n"
	"cbuffer Marks : register(b1) { float4 marks[8]; };\n"
	"H mark(uint v : SV_VertexID, uint inst : SV_InstanceID) { float2 c = float2(v & 1, v >> 1); H o;\n"
	"  float2 px = marks[inst].xy + (c - 0.5) * 6.0; o.p = float4(px / size * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = c; return o; }\n"
	"float4 mark_f(H i) : SV_Target { return float4(1, 1, 1, 1); }\n"
	"float4 hud_f(H i) : SV_Target {\n"
	"  float bar = step(0.5, frac(i.uv.y * 4.0)) * step(0.08, i.uv.x) * step(i.uv.x, 0.08 + 0.84 * frac(floor(i.uv.y * 4.0) * 0.37 + 0.5));\n"
	"  return float4(lerp(float3(0.05, 0.06, 0.08), float3(0.95, 0.92, 0.75), bar), 1);\n"
	"}\n";

typedef struct {
	float viewProj[16], prevViewProj[16];
	float time, dist, load, prevTime, prevDist, size[2], jx, jy, pad[3];
} Frame;

// DLSS through DXMT's nvngx.dll: its parameter object's methods, in DXMT's vtable order
typedef struct Params Params;
typedef struct {
	void (*setPointer)(Params *, const char *, void *);
	void (*set12)(Params *, const char *, void *);
	void (*set11)(Params *, const char *, ID3D11Resource *);
	void (*setInt)(Params *, const char *, int);
	void (*setUint)(Params *, const char *, unsigned int);
	void (*setDouble)(Params *, const char *, double);
	void (*setFloat)(Params *, const char *, float);
	void (*setU64)(Params *, const char *, unsigned long long);
} ParamsTable;
struct Params {
	const ParamsTable *table;
};
typedef unsigned int (*NgxInit)(unsigned long long, const wchar_t *, ID3D11Device *, const void *, unsigned int);
typedef unsigned int (*NgxAllocate)(Params **);
typedef unsigned int (*NgxCreate)(ID3D11DeviceContext *, unsigned int, Params *, unsigned int **);
typedef unsigned int (*NgxEvaluate)(ID3D11DeviceContext *, const unsigned int *, Params *, void *);

static int running = 1;
// mouse: the marks, centred on the clicked pixels
static int marking, markCount;
static float markAt[8][4];

// The frame generation bridge, when asked for: its exports and the game side's cost per call
static struct {
	const char *(*kind)(void);
	LONG (*open)(void);
	LONG (*frame)(UINT64);
	LONG (*stats)(FGBridgeStats *);
	LONG (*metal)(FGBridgeMetal *);
	long frames, failed;
	double *call_us;
} bridge;

static int load_bridge(long frames)
{
	HMODULE dll = LoadLibraryA("cartouche_bridge.dll");
	if (dll == NULL) {
		fprintf(stderr, "scene: no cartouche_bridge.dll (%lu)\n", GetLastError());
		return 0;
	}
	char path[MAX_PATH] = "";
	GetModuleFileNameA(dll, path, sizeof(path));
	bridge.kind = (const char *(*)(void))(void *)GetProcAddress(dll, "cartouche_bridge_kind");
	bridge.open = (LONG(*)(void))(void *)GetProcAddress(dll, "cartouche_bridge_open");
	bridge.frame = (LONG(*)(UINT64))(void *)GetProcAddress(dll, "cartouche_bridge_frame");
	bridge.stats = (LONG(*)(FGBridgeStats *))(void *)GetProcAddress(dll, "cartouche_bridge_stats");
	bridge.metal = (LONG(*)(FGBridgeMetal *))(void *)GetProcAddress(dll, "cartouche_bridge_metal");
	if (!bridge.kind || !bridge.open || !bridge.frame || !bridge.stats || !bridge.metal)
		return 0;
	LONG status = bridge.open();
	printf("bridge kind=%s path=%s open=0x%lx\n", bridge.kind(), path, (unsigned long)status);
	fflush(stdout);
	bridge.frames = frames;
	bridge.call_us = calloc(frames > 0 ? (size_t)frames : 1, sizeof(double));
	return status == 0 && bridge.call_us != NULL;
}

// DXMT's IMTLD3D11DeviceExt1, from framegen/dxmt/0001-GetMetalTexture.patch
typedef struct MetalExt MetalExt;
typedef struct {
	HRESULT(STDMETHODCALLTYPE *QueryInterface)(MetalExt *, REFIID, void **);
	ULONG(STDMETHODCALLTYPE *AddRef)(MetalExt *);
	ULONG(STDMETHODCALLTYPE *Release)(MetalExt *);
	void(STDMETHODCALLTYPE *SetShaderExtensionSlot)(MetalExt *, UINT);
	HRESULT(STDMETHODCALLTYPE *GetMetalTexture)(MetalExt *, ID3D11Resource *, UINT64 *);
	HRESULT(STDMETHODCALLTYPE *GetMetalSharedEvent)(MetalExt *, ID3D11Fence *, UINT64 *);
} MetalExtTable;
struct MetalExt {
	const MetalExtTable *table;
};
static const GUID IID_MetalExt = { 0x137ce045, 0x283f, 0x4481, { 0xb9, 0x39, 0xf4, 0x72, 0x33, 0x52, 0x3d, 0x22 } };

// A copy the CPU can read, mapped; release with unmap_copy
static D3D11_MAPPED_SUBRESOURCE map_copy(ID3D11Device *device, ID3D11DeviceContext *context, ID3D11Texture2D *texture,
                                         ID3D11Texture2D **staging)
{
	D3D11_TEXTURE2D_DESC desc;
	ID3D11Texture2D_GetDesc(texture, &desc);
	desc.Usage = D3D11_USAGE_STAGING;
	desc.BindFlags = 0;
	desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
	desc.MiscFlags = 0;
	D3D11_MAPPED_SUBRESOURCE mapped = { 0 };
	if (FAILED(ID3D11Device_CreateTexture2D(device, &desc, NULL, staging)))
		return mapped;
	ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)*staging, (ID3D11Resource *)texture);
	ID3D11DeviceContext_Map(context, (ID3D11Resource *)*staging, 0, D3D11_MAP_READ, 0, &mapped);
	return mapped;
}

static void unmap_copy(ID3D11DeviceContext *context, ID3D11Texture2D *staging)
{
	ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
	ID3D11Texture2D_Release(staging);
}

// FNV-1a over the rows without their padding, as the library hashes its Metal copies
static UINT64 hash_texture(ID3D11Device *device, ID3D11DeviceContext *context, ID3D11Texture2D *texture)
{
	ID3D11Texture2D *staging = NULL;
	D3D11_MAPPED_SUBRESOURCE mapped = map_copy(device, context, texture, &staging);
	if (mapped.pData == NULL)
		return 0;
	D3D11_TEXTURE2D_DESC desc;
	ID3D11Texture2D_GetDesc(texture, &desc);
	UINT64 h = 0xcbf29ce484222325ull;
	for (UINT y = 0; y < desc.Height; y++) {
		const unsigned char *row = (const unsigned char *)mapped.pData + (size_t)y * mapped.RowPitch;
		for (UINT x = 0; x < desc.Width * 4; x++)
			h = (h ^ row[x]) * 0x100000001b3ull;
	}
	unmap_copy(context, staging);
	return h;
}

// An RGBA8 texture as a binary PPM
static void write_ppm(ID3D11Device *device, ID3D11DeviceContext *context, ID3D11Texture2D *texture, const char *path)
{
	ID3D11Texture2D *staging = NULL;
	D3D11_MAPPED_SUBRESOURCE mapped = map_copy(device, context, texture, &staging);
	FILE *file = fopen(path, "wb");
	if (mapped.pData == NULL || file == NULL) {
		fprintf(stderr, "scene: no capture to %s\n", path);
		if (file)
			fclose(file);
		return;
	}
	D3D11_TEXTURE2D_DESC desc;
	ID3D11Texture2D_GetDesc(texture, &desc);
	fprintf(file, "P6\n%u %u\n255\n", desc.Width, desc.Height);
	for (UINT y = 0; y < desc.Height; y++) {
		const unsigned char *row = (const unsigned char *)mapped.pData + (size_t)y * mapped.RowPitch;
		for (UINT x = 0; x < desc.Width; x++)
			fwrite(row + x * 4, 1, 3, file);
	}
	fclose(file);
	unmap_copy(context, staging);
}

// What the probe and the upscale found, over the run
static struct {
	long frames, same[fg_metal_textures], failed, upscaled;
	double gpu_ms;
} probe;

static void check_probe(ID3D11Device *device, ID3D11DeviceContext *context, const FGBridgeMetal *m, ID3D11Texture2D **textures)
{
	if (probe.frames++ == 0)
		for (int i = 0; i < fg_metal_textures; i++)
			printf("metal texture %d %ux%u format=%u\n", i, m->width[i], m->height[i], m->format[i]);
	for (int i = 0; i < fg_metal_textures; i++) {
		UINT64 h = hash_texture(device, context, textures[i]);
		if (h == m->hash[i] && h != 0)
			probe.same[i]++;
		else if (probe.frames <= 3)
			printf("metal texture %d differs: d3d11=%016llx metal=%016llx\n", i, h, m->hash[i]);
	}
}

// The Halton sequence in the given base, as games jitter their render for a temporal upscaler
static float halton(long index, int base)
{
	float f = 1, r = 0;
	for (long i = index; i > 0; i /= base) {
		f /= (float)base;
		r += f * (float)(i % base);
	}
	return r;
}

static int by_value(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static void report_bridge(long sent)
{
	FGBridgeStats stats = { 0 };
	LONG status = bridge.stats(&stats);
	qsort(bridge.call_us, (size_t)sent, sizeof(double), by_value);
	printf("bridge sent=%ld failed=%ld received=%llu lost=%llu disordered=%llu full=%llu one_way_p50_us=%.2f "
	       "one_way_p99_us=%.2f one_way_max_us=%.2f call_p50_us=%.2f call_p99_us=%.2f call_max_us=%.2f status=0x%lx\n",
	       sent, bridge.failed, (unsigned long long)stats.received, (unsigned long long)stats.lost,
	       (unsigned long long)stats.disordered, (unsigned long long)stats.full, stats.p50_us, stats.p99_us, stats.max_us,
	       sent ? bridge.call_us[sent / 2] : 0, sent ? bridge.call_us[sent * 99 / 100] : 0,
	       sent ? bridge.call_us[sent - 1] : 0, (unsigned long)status);
}

static LRESULT CALLBACK proc(HWND window, UINT message, WPARAM w, LPARAM l)
{
	if (message == WM_CLOSE || message == WM_DESTROY) {
		running = 0;
		return 0;
	}
	if (marking && message == WM_MOUSEACTIVATE)
		return MA_NOACTIVATE;
	if (marking && message == WM_LBUTTONDOWN) {
		int x = (short)LOWORD(l), y = (short)HIWORD(l);
		if (markCount < 8) {
			markAt[markCount][0] = (float)x + 0.5f;
			markAt[markCount][1] = (float)y + 0.5f;
			markCount++;
		}
		printf("click %d %d\n", x, y);
		fflush(stdout);
		return 0;
	}
	return DefWindowProcA(window, message, w, l);
}

// Row-major viewProj for mul(viewProj, v): the same camera as framegen/tests/scene.h
static void camera(float t, float aspect, float out[16])
{
	float yaw = sinf(t * 0.6f) * 0.35f, c = cosf(yaw), s = sinf(yaw);
	float f = 1.0f / tanf(0.5236f), n = 0.1f, r = 200.0f;
	float view[16] = { c, 0, s, -sinf(t * 0.9f) * 1.5f, 0, 1, 0, -0.4f, -s, 0, c, 0, 0, 0, 0, 1 };
	float proj[16] = { f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, r / (n - r), n * r / (n - r), 0, 0, -1, 0 };
	for (int i = 0; i < 4; i++)
		for (int j = 0; j < 4; j++) {
			float sum = 0;
			for (int k = 0; k < 4; k++)
				sum += proj[i * 4 + k] * view[k * 4 + j];
			out[i * 4 + j] = sum;
		}
}

static ID3DBlob *compile(const char *entry, const char *profile)
{
	ID3DBlob *code = NULL, *errors = NULL;
	if (FAILED(D3DCompile(source, strlen(source), "scene", NULL, NULL, entry, profile, 0, 0, &code, &errors))) {
		fprintf(stderr, "scene: %s: %s\n", entry, errors ? (char *)ID3D10Blob_GetBufferPointer(errors) : "?");
		exit(2);
	}
	return code;
}

int main(int argc, char **argv)
{
	double fps = argc > 1 ? atof(argv[1]) : 40, seconds = argc > 2 ? atof(argv[2]) : 20;
	double jitter = argc > 3 ? atof(argv[3]) : 0;
	// dlss: the scene renders at two thirds of the size and DXMT's DLSS brings it up, with the
	// depth and motion a DLSS game hands over
	int dlss = 0, jitters = 0, mfx = 0, ss = 0, bridged_on = 0;
	long bridged = 0, probes = 0, capture_at = -1, capture_count = 0;
	const char *capture = NULL;
	// jsign:X:Y and msign:X:Y: the signs of the jitter and motion the upscaler is told
	float jsign[2] = { 1, 1 }, msign[2] = { 1, 1 }, sharpness = 0.5f;
	for (int i = 4; i < argc; i++) {
		dlss |= strcmp(argv[i], "dlss") == 0;
		marking |= strcmp(argv[i], "mouse") == 0;
		jitters |= strcmp(argv[i], "halton") == 0;
		mfx |= strcmp(argv[i], "mfx") == 0;
		ss |= strcmp(argv[i], "ss") == 0;
		if (strncmp(argv[i], "probe:", 6) == 0)
			probes = atol(argv[i] + 6);
		int at = 0, more = 0;
		if (sscanf(argv[i], "capture:%ld:%n", &capture_at, &at) == 1 && at > 0) {
			capture = argv[i] + at;
			if (sscanf(capture, "%ld:%n", &capture_count, &more) == 1 && more > 0)
				capture += more;
			else
				capture_count = 0;
		}
		if (strncmp(argv[i], "jsign:", 6) == 0)
			sscanf(argv[i] + 6, "%f:%f", &jsign[0], &jsign[1]);
		if (strncmp(argv[i], "msign:", 6) == 0)
			sscanf(argv[i] + 6, "%f:%f", &msign[0], &msign[1]);
		if (strncmp(argv[i], "sharp:", 6) == 0)
			sharpness = (float)atof(argv[i] + 6);
		if (strncmp(argv[i], "bridge:", 7) == 0) {
			if (!load_bridge(atol(argv[i] + 7)))
				return 1;
			bridged_on = 1;
		}
	}
	if ((mfx || probes > 0) && !bridged_on && !load_bridge(0))
		return 1;
	const int low = dlss || mfx || probes > 0;
	// Frames the run must produce before the clock may stop it: probes, captures, bridge sends
	long due = probes;
	if (bridge.frames > due)
		due = bridge.frames;
	if (capture && capture_at + (capture_count > 0 ? capture_count : 1) > due)
		due = capture_at + (capture_count > 0 ? capture_count : 1);
	const int width = ss ? 2560 : 1280, height = ss ? 1440 : 720;
	const int rw = low ? 1280 * 2 / 3 : width, rh = low ? 720 * 2 / 3 : height;

	WNDCLASSA wc = { 0 };
	wc.lpfnWndProc = proc;
	wc.hInstance = GetModuleHandleA(NULL);
	wc.lpszClassName = "scene";
	RegisterClassA(&wc);
	// A window behind others gets its frames dropped by macOS: topmost, shown without taking the
	// focus from the user's app, in the bottom-right corner of the main screen. No title bar, and
	// layered and transparent so Wine's Mac driver lets every click through to what is below, except
	// in mouse mode, where the clicks are for the scene: there a titled window, as without one the
	// shown rate under our upscale layer drops to 36 fps.
	RECT work;
	SystemParametersInfoA(SPI_GETWORKAREA, 0, &work, 0);
	DWORD style = marking ? WS_OVERLAPPEDWINDOW : WS_POPUP;
	RECT rect = { 0, 0, 1280, 720 };
	AdjustWindowRect(&rect, style, FALSE);
	int w = rect.right - rect.left, h = rect.bottom - rect.top;
	HWND window = CreateWindowExA(WS_EX_TOPMOST | WS_EX_NOACTIVATE | (marking ? 0 : WS_EX_LAYERED | WS_EX_TRANSPARENT), "scene",
	                              "Cartouche Frame Gen D3D11 Scene", style, work.right - w, work.bottom - h, w, h, NULL,
	                              NULL, wc.hInstance, NULL);
	if (!marking)
		SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA);
	ShowWindow(window, SW_SHOWNOACTIVATE);

	DXGI_SWAP_CHAIN_DESC sd = { 0 };
	sd.BufferDesc.Width = width;
	sd.BufferDesc.Height = height;
	sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
	sd.SampleDesc.Count = 1;
	sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
	sd.BufferCount = 2;
	sd.OutputWindow = window;
	sd.Windowed = TRUE;
	sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
	IDXGISwapChain *chain;
	ID3D11Device *device;
	ID3D11DeviceContext *context;
	if (FAILED(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &sd,
	                                         &chain, &device, NULL, &context))) {
		fputs("scene: no D3D11 device\n", stderr);
		return 1;
	}
	ID3D11Texture2D *back;
	IDXGISwapChain_GetBuffer(chain, 0, &IID_ID3D11Texture2D, (void **)&back);
	ID3D11RenderTargetView *target;
	ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back, NULL, &target);
	D3D11_TEXTURE2D_DESC dd = { rw, rh, 1, 1, DXGI_FORMAT_R32_TYPELESS, { 1, 0 }, D3D11_USAGE_DEFAULT,
	                            D3D11_BIND_DEPTH_STENCIL | D3D11_BIND_SHADER_RESOURCE, 0, 0 };
	ID3D11Texture2D *depth;
	ID3D11Device_CreateTexture2D(device, &dd, NULL, &depth);
	D3D11_DEPTH_STENCIL_VIEW_DESC dvd = { 0 };
	dvd.Format = DXGI_FORMAT_D32_FLOAT;
	dvd.ViewDimension = D3D11_DSV_DIMENSION_TEXTURE2D;
	ID3D11DepthStencilView *depthView;
	ID3D11Device_CreateDepthStencilView(device, (ID3D11Resource *)depth, &dvd, &depthView);

	// The DLSS path's own targets: the scene's colour and motion, and the full-size output
	ID3D11Texture2D *sceneColor = NULL, *motion = NULL, *upscaled = NULL;
	ID3D11RenderTargetView *sceneTargets[2] = { target, NULL };
	Params *params = NULL;
	unsigned int *feature = NULL;
	NgxEvaluate evaluate = NULL;
	if (low) {
		D3D11_TEXTURE2D_DESC td = { rw, rh, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 }, D3D11_USAGE_DEFAULT,
		                            D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE, 0, 0 };
		ID3D11Device_CreateTexture2D(device, &td, NULL, &sceneColor);
		td.Format = DXGI_FORMAT_R16G16_FLOAT;
		ID3D11Device_CreateTexture2D(device, &td, NULL, &motion);
		td.Width = width;
		td.Height = height;
		td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
		td.BindFlags = D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE;
		ID3D11Device_CreateTexture2D(device, &td, NULL, &upscaled);
		ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)sceneColor, NULL, &sceneTargets[0]);
		ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)motion, NULL, &sceneTargets[1]);
	}
	// The Metal textures behind the scene's own, and a fence to order the library's work
	MetalExt *ext = NULL;
	ID3D11Fence *fence = NULL;
	ID3D11DeviceContext4 *context4 = NULL;
	UINT64 fenceValue = 0;
	FGBridgeMetal metal = { 0 };
	if (mfx || probes > 0) {
		ID3D11Device5 *device5 = NULL;
		if (FAILED(ID3D11Device_QueryInterface(device, &IID_MetalExt, (void **)&ext))) {
			fputs("scene: no IMTLD3D11DeviceExt1 (DXMT without the GetMetalTexture patch)\n", stderr);
			return 4;
		}
		if (FAILED(ID3D11Device_QueryInterface(device, &IID_ID3D11Device5, (void **)&device5)) ||
		    FAILED(ID3D11Device5_CreateFence(device5, 0, 0, &IID_ID3D11Fence, (void **)&fence)) ||
		    FAILED(ID3D11DeviceContext_QueryInterface(context, &IID_ID3D11DeviceContext4, (void **)&context4))) {
			fputs("scene: no D3D11 fence\n", stderr);
			return 4;
		}
		ID3D11Resource *resources[fg_metal_textures] = { (ID3D11Resource *)sceneColor, (ID3D11Resource *)depth,
			                                             (ID3D11Resource *)motion, (ID3D11Resource *)upscaled };
		for (int i = 0; i < fg_metal_textures; i++)
			if (FAILED(ext->table->GetMetalTexture(ext, resources[i], &metal.texture[i]))) {
				fprintf(stderr, "scene: GetMetalTexture failed on texture %d\n", i);
				return 4;
			}
		if (FAILED(ext->table->GetMetalSharedEvent(ext, fence, &metal.event))) {
			fputs("scene: GetMetalSharedEvent failed\n", stderr);
			return 4;
		}
		ID3D11Buffer *buffer = NULL;
		D3D11_BUFFER_DESC plain = { 64, D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0 };
		ID3D11Device_CreateBuffer(device, &plain, NULL, &buffer);
		UINT64 none = 1;
		HRESULT refused = ext->table->GetMetalTexture(ext, (ID3D11Resource *)buffer, &none);
		printf("metal handles color=0x%llx depth=0x%llx motion=0x%llx output=0x%llx event=0x%llx buffer=0x%lx/%llu\n",
		       metal.texture[0], metal.texture[1], metal.texture[2], metal.texture[3], metal.event,
		       (unsigned long)refused, none);
		fflush(stdout);
		ID3D11Buffer_Release(buffer);
		ID3D11Device5_Release(device5);
	}
	if (dlss) {
		HMODULE ngx = LoadLibraryA("nvngx.dll");
		NgxInit init = ngx ? (NgxInit)(void *)GetProcAddress(ngx, "NVSDK_NGX_D3D11_Init") : NULL;
		NgxAllocate allocate = ngx ? (NgxAllocate)(void *)GetProcAddress(ngx, "NVSDK_NGX_D3D11_AllocateParameters") : NULL;
		NgxCreate create = ngx ? (NgxCreate)(void *)GetProcAddress(ngx, "NVSDK_NGX_D3D11_CreateFeature") : NULL;
		evaluate = ngx ? (NgxEvaluate)(void *)GetProcAddress(ngx, "NVSDK_NGX_D3D11_EvaluateFeature") : NULL;
		if (init == NULL || allocate == NULL || create == NULL || evaluate == NULL) {
			fputs("scene: no nvngx.dll with DLSS (DXMT_ENABLE_NVEXT=1 on DXMT)\n", stderr);
			return 3;
		}
		init(0x43617274, L".", device, NULL, 0x15);
		allocate(&params);
		params->table->setUint(params, "Width", rw);
		params->table->setUint(params, "Height", rh);
		params->table->setUint(params, "OutWidth", width);
		params->table->setUint(params, "OutHeight", height);
		params->table->setInt(params, "PerfQualityValue", 2);
		params->table->setInt(params, "DLSS.Feature.Create.Flags", 1 << 1);
		unsigned int result = create(context, 1, params, &feature);
		if (result != 1) {
			fprintf(stderr, "scene: DLSS feature refused (0x%x)\n", result);
			return 3;
		}
		fputs("scene: DLSS on\n", stderr);
	}
	D3D11_DEPTH_STENCIL_DESC ds = { 0 };
	ds.DepthEnable = TRUE;
	ds.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
	ds.DepthFunc = D3D11_COMPARISON_LESS;
	ID3D11DepthStencilState *depthOn, *depthOff;
	ID3D11Device_CreateDepthStencilState(device, &ds, &depthOn);
	ds.DepthEnable = FALSE;
	ID3D11Device_CreateDepthStencilState(device, &ds, &depthOff);
	D3D11_RASTERIZER_DESC rd = { 0 };
	rd.FillMode = D3D11_FILL_SOLID;
	rd.CullMode = D3D11_CULL_NONE;
	rd.DepthClipEnable = TRUE;
	ID3D11RasterizerState *raster;
	ID3D11Device_CreateRasterizerState(device, &rd, &raster);

	ID3DBlob *cubeCode = compile("cube", "vs_5_0"), *groundCode = compile("ground", "vs_5_0");
	ID3DBlob *litCode = compile("lit", "ps_5_0"), *hudCode = compile("hud", "vs_5_0"), *hudFCode = compile("hud_f", "ps_5_0");
	ID3DBlob *markCode = compile("mark", "vs_5_0"), *markFCode = compile("mark_f", "ps_5_0");
	ID3D11VertexShader *cubeVS, *groundVS, *hudVS, *markVS;
	ID3D11PixelShader *litPS, *hudPS, *markPS;
	ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(cubeCode), ID3D10Blob_GetBufferSize(cubeCode), NULL, &cubeVS);
	ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(groundCode), ID3D10Blob_GetBufferSize(groundCode), NULL, &groundVS);
	ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(hudCode), ID3D10Blob_GetBufferSize(hudCode), NULL, &hudVS);
	ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(litCode), ID3D10Blob_GetBufferSize(litCode), NULL, &litPS);
	ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(hudFCode), ID3D10Blob_GetBufferSize(hudFCode), NULL, &hudPS);
	ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(markCode), ID3D10Blob_GetBufferSize(markCode), NULL, &markVS);
	ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(markFCode), ID3D10Blob_GetBufferSize(markFCode), NULL, &markPS);
	D3D11_BUFFER_DESC md = { sizeof(markAt), D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0 };
	ID3D11Buffer *markBuffer;
	ID3D11Device_CreateBuffer(device, &md, NULL, &markBuffer);

	D3D11_BUFFER_DESC bd = { sizeof(Frame), D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0 };
	ID3D11Buffer *frameBuffer;
	ID3D11Device_CreateBuffer(device, &bd, NULL, &frameBuffer);

	LARGE_INTEGER frequency, start, now;
	QueryPerformanceFrequency(&frequency);
	QueryPerformanceCounter(&start);
	double next = 0, period = 1.0 / fps;
	long rendered = 0;
	srand(7);
	D3D11_VIEWPORT viewport = { 0, 0, (float)width, (float)height, 0, 1 }, render = { 0, 0, (float)rw, (float)rh, 0, 1 };
	while (running) {
		MSG message;
		while (PeekMessageA(&message, NULL, 0, 0, PM_REMOVE)) {
			TranslateMessage(&message);
			DispatchMessageA(&message);
		}
		QueryPerformanceCounter(&now);
		double elapsed = (double)(now.QuadPart - start.QuadPart) / (double)frequency.QuadPart;
		if (elapsed >= seconds && rendered >= due)
			break;
		if (elapsed < next) {
			DWORD wait = (DWORD)((next - elapsed) * 1000);
			if (wait > 1)
				Sleep(wait - 1);
			continue;
		}
		next += period;
		if (next < elapsed)
			next = elapsed + period;

		// Scene time advances by whole frames, so a capped rate shows even steps
		float t = 10.0f + (float)rendered * (float)period;
		Frame frame;
		camera(t, (float)width / height, frame.viewProj);
		camera(t - (float)period, (float)width / height, frame.prevViewProj);
		frame.time = t;
		frame.dist = 960.0f * t / 60.0f;
		frame.prevTime = t - (float)period;
		frame.prevDist = 960.0f * frame.prevTime / 60.0f;
		frame.size[0] = (float)rw;
		frame.size[1] = (float)rh;
		frame.load = jitter > 0 ? (float)(200.0 * jitter * rand() / RAND_MAX) : 0;
		// 16 phases cover a 1.5x upscale's pixel well; in render pixels, y down
		frame.jx = (dlss && jitters) || mfx ? halton(rendered % 16 + 1, 2) - 0.5f : 0;
		frame.jy = (dlss && jitters) || mfx ? halton(rendered % 16 + 1, 3) - 0.5f : 0;
		D3D11_MAPPED_SUBRESOURCE mapped;
		ID3D11DeviceContext_Map(context, (ID3D11Resource *)frameBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
		memcpy(mapped.pData, &frame, sizeof(frame));
		ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)frameBuffer, 0);

		const float clear[4] = { 0.11f, 0.115f, 0.14f, 1 }, still[4] = { 0 };
		ID3D11DeviceContext_ClearRenderTargetView(context, sceneTargets[0], clear);
		if (low)
			ID3D11DeviceContext_ClearRenderTargetView(context, sceneTargets[1], still);
		ID3D11DeviceContext_ClearDepthStencilView(context, depthView, D3D11_CLEAR_DEPTH, 1, 0);
		ID3D11DeviceContext_OMSetRenderTargets(context, low ? 2 : 1, sceneTargets, depthView);
		ID3D11DeviceContext_RSSetViewports(context, 1, &render);
		ID3D11DeviceContext_RSSetState(context, raster);
		ID3D11DeviceContext_IASetInputLayout(context, NULL);
		ID3D11DeviceContext_VSSetConstantBuffers(context, 0, 1, &frameBuffer);
		ID3D11DeviceContext_PSSetConstantBuffers(context, 0, 1, &frameBuffer);
		ID3D11DeviceContext_OMSetDepthStencilState(context, depthOn, 0);
		ID3D11DeviceContext_PSSetShader(context, litPS, NULL, 0);
		ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
		ID3D11DeviceContext_VSSetShader(context, groundVS, NULL, 0);
		ID3D11DeviceContext_Draw(context, 4, 0);
		ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
		ID3D11DeviceContext_VSSetShader(context, cubeVS, NULL, 0);
		ID3D11DeviceContext_DrawInstanced(context, 36, 8 * 32, 0, 0);
		if (dlss) {
			ID3D11DeviceContext_OMSetRenderTargets(context, 0, NULL, NULL);
			params->table->set11(params, "Color", (ID3D11Resource *)sceneColor);
			params->table->set11(params, "Output", (ID3D11Resource *)upscaled);
			params->table->set11(params, "Depth", (ID3D11Resource *)depth);
			params->table->set11(params, "MotionVectors", (ID3D11Resource *)motion);
			params->table->setUint(params, "DLSS.Render.Subrect.Dimensions.Width", rw);
			params->table->setUint(params, "DLSS.Render.Subrect.Dimensions.Height", rh);
			params->table->setFloat(params, "Jitter.Offset.X", jsign[0] * frame.jx);
			params->table->setFloat(params, "Jitter.Offset.Y", jsign[1] * frame.jy);
			params->table->setFloat(params, "MV.Scale.X", 1);
			params->table->setFloat(params, "MV.Scale.Y", 1);
			params->table->setFloat(params, "DLSS.Pre.Exposure", 1);
			params->table->setInt(params, "Reset", rendered == 0);
			evaluate(context, feature, params, NULL);
			ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)back, (ID3D11Resource *)upscaled);
			ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target, NULL);
		}
		if (mfx || rendered < probes) {
			ID3D11DeviceContext_OMSetRenderTargets(context, 0, NULL, NULL);
			metal.op = rendered < probes ? fg_metal_probe : fg_metal_upscale;
			metal.reset = rendered == 0;
			metal.jitter[0] = jsign[0] * frame.jx;
			metal.jitter[1] = jsign[1] * frame.jy;
			metal.motion_scale[0] = msign[0];
			metal.motion_scale[1] = msign[1];
			metal.sharpness = sharpness;
			ID3D11DeviceContext4_Signal(context4, fence, ++fenceValue);
			metal.wait = fenceValue;
			metal.signal = ++fenceValue;
			if (bridge.metal(&metal) != 0 || metal.status != 0)
				metal.signal = fenceValue = metal.wait, probe.failed++;
			ID3D11DeviceContext4_Wait(context4, fence, fenceValue);
			if (metal.op == fg_metal_probe)
				check_probe(device, context, &metal, (ID3D11Texture2D *[]){ sceneColor, depth, motion, upscaled });
			if (metal.op == fg_metal_upscale)
				probe.gpu_ms += metal.gpu_ms, probe.upscaled++;
			if (mfx)
				ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)back, (ID3D11Resource *)upscaled);
			ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target, NULL);
		}
		if (capture && capture_count > 0 && rendered >= capture_at && rendered < capture_at + capture_count) {
			char path[MAX_PATH];
			snprintf(path, sizeof(path), "%s-%ld.ppm", capture, rendered - capture_at);
			write_ppm(device, context, low ? upscaled : back, path);
		} else if (capture && rendered == capture_at) {
			char path[MAX_PATH];
			snprintf(path, sizeof(path), "%s.ppm", capture);
			write_ppm(device, context, low ? upscaled : back, path);
			if (low) {
				snprintf(path, sizeof(path), "%s-low.ppm", capture);
				write_ppm(device, context, sceneColor, path);
			}
		}
		ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);
		ID3D11DeviceContext_OMSetDepthStencilState(context, depthOff, 0);
		ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
		ID3D11DeviceContext_VSSetShader(context, hudVS, NULL, 0);
		ID3D11DeviceContext_PSSetShader(context, hudPS, NULL, 0);
		ID3D11DeviceContext_Draw(context, 4, 0);
		if (markCount > 0) {
			ID3D11DeviceContext_Map(context, (ID3D11Resource *)markBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
			memcpy(mapped.pData, markAt, sizeof(markAt));
			ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)markBuffer, 0);
			ID3D11DeviceContext_VSSetConstantBuffers(context, 1, 1, &markBuffer);
			ID3D11DeviceContext_VSSetShader(context, markVS, NULL, 0);
			ID3D11DeviceContext_PSSetShader(context, markPS, NULL, 0);
			ID3D11DeviceContext_DrawInstanced(context, 4, (UINT)markCount, 0, 0);
		}
		IDXGISwapChain_Present(chain, 0, 0);
		rendered++;
		if (bridge.frames > 0) {
			// rdtsc counts nanoseconds under Rosetta
			UINT64 before = __rdtsc();
			if (bridge.frame((UINT64)rendered) != 0)
				bridge.failed++;
			bridge.call_us[bridged++] = (double)(__rdtsc() - before) / 1000.0;
			if (bridged == bridge.frames)
				break;
		}
	}
	QueryPerformanceCounter(&now);
	double total = (double)(now.QuadPart - start.QuadPart) / (double)frequency.QuadPart;
	printf("rendered %ld frame_ms=%.3f\n", rendered, rendered ? total * 1000.0 / rendered : 0);
	if (probes > 0)
		printf("metal probe frames=%ld color=%ld depth=%ld motion=%ld output=%ld failed=%ld\n", probe.frames,
		       probe.same[0], probe.same[1], probe.same[2], probe.same[3], probe.failed);
	if (mfx)
		printf("metal upscale frames=%ld gpu_ms=%.3f failed=%ld\n", probe.upscaled,
		       probe.upscaled ? probe.gpu_ms / probe.upscaled : 0, probe.failed);
	if (bridge.frames > 0)
		report_bridge(bridged);
	fflush(stdout);
	return 0;
}
