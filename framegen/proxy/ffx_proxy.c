// The game's FFX DLL as a Wine builtin found through WINEDLLPATH: AMD's own DLL loaded from a copy,
// the five calls forwarded unchanged and logged, and with CARTOUCHE_FFX_COPY each frame's depth and
// motion copied for the library. Written from AMD's MIT headers only (framegen/proxy/ffx).
// Variables and limits: docs/FRAME-GENERATION.md, FFX proxy.
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#include <windows.h>
#include <winternl.h>
#include <initguid.h>
#include <d3d12.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ffx/framegeneration/include/dx12/ffx_api_framegeneration_dx12.h"
#include "ffx/framegeneration/include/ffx_framegeneration.h"
#include "ffx/upscalers/include/ffx_upscale.h"
#include "fg_proxy.h"

// Wine's own: the information class that returns a builtin's unix call table
enum { memory_wine_unix_funcs = 1000 };

typedef UINT64 unixlib_handle_t;
typedef NTSTATUS(WINAPI *query_memory_t)(HANDLE, void *, ULONG, void *, SIZE_T, SIZE_T *);
typedef NTSTATUS(WINAPI *dispatcher_t)(unixlib_handle_t, unsigned int, void *);

static HMODULE self, real;
static unixlib_handle_t handle;
static dispatcher_t dispatcher;
static PfnFfxCreateContext real_create;
static PfnFfxDestroyContext real_destroy;
static PfnFfxConfigure real_configure;
static PfnFfxQuery real_query;
static PfnFfxDispatch real_dispatch;
static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
static FGProxyShared *shared;
static CRITICAL_SECTION lock;
static int log_all, copy_wanted, ui_wanted;
// CARTOUCHE_FFX_FG: game (AMD's when the game wants it), ours (never AMD's), force (always AMD's)
static enum { fg_game, fg_ours, fg_force } fg_mode;

static void say(const char *format, ...)
{
	char line[1024];
	va_list args;
	va_start(args, format);
	vsnprintf(line, sizeof(line), format, args);
	va_end(args);
	if (dispatcher == NULL || dispatcher(handle, fg_proxy_log, line) != 0)
		fprintf(stderr, "ffx: %s\n", line);
}

static int flag(const char *name)
{
	char value[8];
	DWORD n = GetEnvironmentVariableA(name, value, sizeof(value));
	return n > 0 && n < sizeof(value) && value[0] == '1';
}

static void attach_unix(void)
{
	HMODULE ntdll = GetModuleHandleA("ntdll.dll");
	query_memory_t query = (query_memory_t)(void *)GetProcAddress(ntdll, "NtQueryVirtualMemory");
	dispatcher_t *entry = (dispatcher_t *)(void *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher");
	if (query == NULL || entry == NULL ||
	    query(GetCurrentProcess(), self, memory_wine_unix_funcs, &handle, sizeof(handle), NULL) != 0)
		return;
	dispatcher = *entry;
	if (dispatcher(handle, fg_proxy_attach, &shared) != 0)
		dispatcher = NULL;
}

// Wine says the builtin lives where the game's own DLL is, or in system32 when the game has none.
// A copy with another name escapes the =b load order that brought this one in.
static BOOL CALLBACK load_real(INIT_ONCE *init, void *param, void **context)
{
	(void)init;
	(void)param;
	(void)context;
	attach_unix();
	log_all = flag("CARTOUCHE_FFX_LOG_ALL");
	char mode[8] = "";
	GetEnvironmentVariableA("CARTOUCHE_FFX_FG", mode, sizeof(mode));
	fg_mode = strcmp(mode, "ours") == 0 ? fg_ours : strcmp(mode, "force") == 0 ? fg_force : fg_game;
	ui_wanted = flag("CARTOUCHE_FFX_UI");
	char wanted[8];
	DWORD c = GetEnvironmentVariableA("CARTOUCHE_FFX_COPY", wanted, sizeof(wanted));
	copy_wanted = c > 0 && c < sizeof(wanted) ? atoi(wanted) : 0;
	WCHAR path[MAX_PATH], system[MAX_PATH], copy[MAX_PATH + 64];
	DWORD n = GetEnvironmentVariableW(L"CARTOUCHE_FFX_REAL", path, MAX_PATH);
	if (n == 0 || n >= MAX_PATH) {
		n = GetModuleFileNameW(self, path, MAX_PATH);
		UINT s = GetSystemDirectoryW(system, MAX_PATH);
		if (n == 0 || n >= MAX_PATH || (s > 0 && _wcsnicmp(path, system, s) == 0)) {
			say("ffx no game DLL behind %ls", n > 0 ? path : L"?");
			return TRUE;
		}
	}
	const WCHAR *name = wcsrchr(path, L'\\') ? wcsrchr(path, L'\\') + 1 : path;
	DWORD t = GetTempPathW(MAX_PATH, copy);
	if (t == 0 || t >= MAX_PATH)
		return TRUE;
	_snwprintf(copy + t, 64, L"cartouche-ffx-%lu", GetCurrentProcessId());
	CreateDirectoryW(copy, NULL);
	size_t at = wcslen(copy);
	_snwprintf(copy + at, MAX_PATH + 64 - at, L"\\%.*ls.real.dll", (int)(wcslen(name) - 4), name);
	if (!CopyFileW(path, copy, FALSE) || (real = LoadLibraryW(copy)) == NULL) {
		say("ffx cannot load %ls (error %lu)", copy, GetLastError());
		return TRUE;
	}
	real_create = (PfnFfxCreateContext)(void *)GetProcAddress(real, "ffxCreateContext");
	real_destroy = (PfnFfxDestroyContext)(void *)GetProcAddress(real, "ffxDestroyContext");
	real_configure = (PfnFfxConfigure)(void *)GetProcAddress(real, "ffxConfigure");
	real_query = (PfnFfxQuery)(void *)GetProcAddress(real, "ffxQuery");
	real_dispatch = (PfnFfxDispatch)(void *)GetProcAddress(real, "ffxDispatch");
	say("ffx proxy loaded %ls from %ls copy=%d", name, path, copy_wanted);
	return TRUE;
}

static BOOL ready(void)
{
	InitOnceExecuteOnce(&once, load_real, NULL, NULL);
	return real_dispatch != NULL;
}

// The first few calls of each type, then one in 600, unless CARTOUCHE_FFX_LOG_ALL=1
static BOOL worth_logging(uint64_t type)
{
	static struct {
		uint64_t type, count;
	} seen[64];
	if (log_all)
		return TRUE;
	EnterCriticalSection(&lock);
	uint64_t count = 0;
	for (int i = 0; i < 64; i++)
		if (seen[i].type == type || seen[i].count == 0) {
			seen[i].type = type;
			count = ++seen[i].count;
			break;
		}
	LeaveCriticalSection(&lock);
	return count != 0 && (count <= 3 || count % 600 == 0);
}

static const char *resource(char *out, size_t size, const struct FfxApiResource *r)
{
	if (r->resource == NULL)
		snprintf(out, size, "none");
	else
		snprintf(out, size, "%ux%u/f%u/s0x%x", r->description.width, r->description.height, r->description.format,
		         r->state);
	return out;
}

static void chain(char *out, size_t size, const ffxApiHeader *header)
{
	size_t at = 0;
	out[0] = 0;
	for (; header != NULL && at + 12 < size; header = header->pNext)
		at += snprintf(out + at, size - at, "%s0x%llx", at ? "," : "", (unsigned long long)header->type);
}

// What the copies need: the device and the upscaler's motion vector size
static ID3D12Device *device;
static uint32_t upscale_flags;

static void tell_create(const ffxApiHeader *desc, ffxContext context, ffxReturnCode_t status)
{
	char types[256];
	chain(types, sizeof(types), desc);
	say("ffx create ctx=%p types=%s ret=%u", context, types, status);
	for (const ffxApiHeader *h = desc; h != NULL; h = h->pNext)
		switch (h->type) {
		case FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE: {
			const struct ffxCreateContextDescUpscale *d = (const void *)h;
			upscale_flags = d->flags;
			say("ffx   upscale flags=0x%x maxRender=%ux%u maxUpscale=%ux%u", d->flags, d->maxRenderSize.width,
			    d->maxRenderSize.height, d->maxUpscaleSize.width, d->maxUpscaleSize.height);
			break;
		}
		case FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE_VERSION:
			say("ffx   upscale version=0x%x", ((const struct ffxCreateContextDescUpscaleVersion *)(const void *)h)->version);
			break;
		case FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12: {
			ID3D12Device *given = ((const struct ffxCreateBackendDX12Desc *)(const void *)h)->device;
			say("ffx   backend dx12 device=%p", (void *)given);
			EnterCriticalSection(&lock);
			if (device == NULL && given != NULL && status == FFX_API_RETURN_OK) {
				device = given;
				ID3D12Device_AddRef(device);
			}
			LeaveCriticalSection(&lock);
			break;
		}
		case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION: {
			const struct ffxCreateContextDescFrameGeneration *d = (const void *)h;
			say("ffx   framegen flags=0x%x display=%ux%u maxRender=%ux%u backbuffer=f%u", d->flags, d->displaySize.width,
			    d->displaySize.height, d->maxRenderSize.width, d->maxRenderSize.height, d->backBufferFormat);
			break;
		}
		case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION_HUDLESS:
			say("ffx   framegen hudless=f%u",
			    ((const struct ffxCreateContextDescFrameGenerationHudless *)(const void *)h)->hudlessBackBufferFormat);
			break;
		case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_WRAP_DX12:
			say("ffx   swapchain wrap queue=%p",
			    (void *)((const struct ffxCreateContextDescFrameGenerationSwapChainWrapDX12 *)(const void *)h)->gameQueue);
			break;
		case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_NEW_DX12:
			say("ffx   swapchain new queue=%p",
			    (void *)((const struct ffxCreateContextDescFrameGenerationSwapChainNewDX12 *)(const void *)h)->gameQueue);
			break;
		case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_FOR_HWND_DX12: {
			const struct ffxCreateContextDescFrameGenerationSwapChainForHwndDX12 *d = (const void *)h;
			say("ffx   swapchain hwnd %ux%u f%u buffers=%u queue=%p", d->desc ? d->desc->Width : 0,
			    d->desc ? d->desc->Height : 0, d->desc ? (unsigned)d->desc->Format : 0,
			    d->desc ? d->desc->BufferCount : 0, (void *)d->gameQueue);
			break;
		}
		case FFX_API_DESC_TYPE_OVERRIDE_VERSION:
			say("ffx   override version=0x%llx", (unsigned long long)((const struct ffxOverrideVersion *)(const void *)h)->versionId);
			break;
		}
}

static void tell_configure(ffxContext context, const ffxApiHeader *desc, ffxReturnCode_t status)
{
	if (!worth_logging(desc->type | 1ull << 40))
		return;
	char types[256], hudless[64];
	chain(types, sizeof(types), desc);
	switch (desc->type) {
	case FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATION: {
		const struct ffxConfigureDescFrameGeneration *d = (const void *)desc;
		say("ffx configure ctx=%p framegen enabled=%d async=%d hudless=%s flags=0x%x frame=%llu present=%p generate=%p ret=%u",
		    context, d->frameGenerationEnabled, d->allowAsyncWorkloads, resource(hudless, sizeof(hudless), &d->HUDLessColor),
		    d->flags, (unsigned long long)d->frameID, (void *)d->presentCallback, (void *)d->frameGenerationCallback, status);
		break;
	}
	case FFX_API_CONFIGURE_DESC_TYPE_UPSCALE_KEYVALUE: {
		const struct ffxConfigureDescUpscaleKeyValue *d = (const void *)desc;
		say("ffx configure ctx=%p upscale key=%llu u64=%llu ret=%u", context, (unsigned long long)d->key,
		    (unsigned long long)d->u64, status);
		break;
	}
	case FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_REGISTERUIRESOURCE_DX12: {
		const struct ffxConfigureDescFrameGenerationSwapChainRegisterUiResourceDX12 *d = (const void *)desc;
		say("ffx configure ctx=%p ui=%s flags=0x%x ret=%u", context, resource(hudless, sizeof(hudless), &d->uiResource),
		    d->flags, status);
		break;
	}
	default:
		say("ffx configure ctx=%p types=%s ret=%u", context, types, status);
	}
}

static void tell_query(ffxContext context, const ffxApiHeader *desc, ffxReturnCode_t status)
{
	if (!worth_logging(desc->type | 2ull << 40))
		return;
	char types[256];
	chain(types, sizeof(types), desc);
	switch (desc->type) {
	case FFX_API_QUERY_DESC_TYPE_GET_VERSIONS: {
		const struct ffxQueryDescGetVersions *d = (const void *)desc;
		say("ffx query ctx=%p versions of 0x%llx count=%llu first=%s ret=%u", context,
		    (unsigned long long)d->createDescType, d->outputCount ? (unsigned long long)*d->outputCount : 0ull,
		    d->versionNames && d->outputCount && *d->outputCount ? d->versionNames[0] : "-", status);
		break;
	}
	case FFX_API_QUERY_DESC_TYPE_UPSCALE_GETRENDERRESOLUTIONFROMQUALITYMODE: {
		const struct ffxQueryDescUpscaleGetRenderResolutionFromQualityMode *d = (const void *)desc;
		say("ffx query ctx=%p render size for %ux%u mode %u = %ux%u ret=%u", context, d->displayWidth, d->displayHeight,
		    d->qualityMode, d->pOutRenderWidth ? *d->pOutRenderWidth : 0, d->pOutRenderHeight ? *d->pOutRenderHeight : 0,
		    status);
		break;
	}
	case FFX_API_QUERY_DESC_TYPE_GET_PROVIDER_VERSION: {
		const struct ffxQueryGetProviderVersion *d = (const void *)desc;
		say("ffx query ctx=%p provider 0x%llx %s ret=%u", context, (unsigned long long)d->versionId,
		    d->versionName ? d->versionName : "-", status);
		break;
	}
	default:
		say("ffx query ctx=%p types=%s ret=%u", context, types, status);
	}
}

static void tell_dispatch(ffxContext context, const ffxApiHeader *desc, ffxReturnCode_t status, uint64_t frame)
{
	if (!worth_logging(desc->type | 3ull << 40))
		return;
	char types[256], a[64], b[64], c[64], d4[64];
	chain(types, sizeof(types), desc);
	switch (desc->type) {
	case FFX_API_DISPATCH_DESC_TYPE_UPSCALE: {
		const struct ffxDispatchDescUpscale *d = (const void *)desc;
		say("ffx dispatch ctx=%p upscale #%llu render=%ux%u upscale=%ux%u jitter=%.3f,%.3f mvscale=%.1f,%.1f reset=%d "
		    "dt=%.2fms near=%.3g far=%.3g fov=%.3f exposure=%.2f flags=0x%x color=%s depth=%s motion=%s output=%s ret=%u",
		    context, (unsigned long long)frame, d->renderSize.width, d->renderSize.height, d->upscaleSize.width,
		    d->upscaleSize.height, d->jitterOffset.x, d->jitterOffset.y, d->motionVectorScale.x, d->motionVectorScale.y,
		    d->reset, d->frameTimeDelta, d->cameraNear, d->cameraFar, d->cameraFovAngleVertical, d->preExposure, d->flags,
		    resource(a, sizeof(a), &d->color), resource(b, sizeof(b), &d->depth), resource(c, sizeof(c), &d->motionVectors),
		    resource(d4, sizeof(d4), &d->output), status);
		break;
	}
	case FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE_V2: {
		const struct ffxDispatchDescFrameGenerationPrepareV2 *d = (const void *)desc;
		say("ffx dispatch ctx=%p prepare frame=%llu render=%ux%u jitter=%.3f,%.3f mvscale=%.1f,%.1f reset=%d dt=%.2fms "
		    "flags=0x%x depth=%s motion=%s ret=%u",
		    context, (unsigned long long)d->frameID, d->renderSize.width, d->renderSize.height, d->jitterOffset.x,
		    d->jitterOffset.y, d->motionVectorScale.x, d->motionVectorScale.y, d->reset, d->frameTimeDelta, d->flags,
		    resource(a, sizeof(a), &d->depth), resource(b, sizeof(b), &d->motionVectors), status);
		break;
	}
	default:
		say("ffx dispatch ctx=%p types=%s ret=%u", context, types, status);
	}
}

// Copies. Three readback slots, each with depth then motion, and three for the UI tests; the
// queue that runs a list holding a copy signals our fence after it, and a thread hands the slot
// to the library.
enum { vector_slots = 3, slots_count = 6, slot_free = 0, slot_recorded, slot_submitted };

typedef struct {
	ID3D12Resource *buffer;
	UINT64 size;
	D3D12_PLACED_SUBRESOURCE_FOOTPRINT depth, motion, color, final;
	BOOL has_color, ui;
	ID3D12CommandList *list;
	UINT64 fence;
	volatile LONG state;
	FGProxyFrame frame;
} Slot;

static Slot slots[slots_count];
static ID3D12Fence *fence;
static UINT64 fence_value;
static HANDLE wake, done;
static uint64_t copies, skipped, recycled, dropped, frames_seen, latency_n, ui_copies, ui_skipped, ui_bytes;
static double record_us, wait_us, wait_max_us, library_us, latency_us[512];
static uint64_t bytes;
static LARGE_INTEGER frequency;

typedef void(STDMETHODCALLTYPE *execute_t)(ID3D12CommandQueue *, UINT, ID3D12CommandList *const *);
static execute_t next_execute;

static double ticks_us(LONGLONG ticks)
{
	return (double)ticks * 1e6 / (double)frequency.QuadPart;
}

static LONGLONG ticks(void)
{
	LARGE_INTEGER t;
	QueryPerformanceCounter(&t);
	return t.QuadPart;
}

static void STDMETHODCALLTYPE hook_execute(ID3D12CommandQueue *queue, UINT count, ID3D12CommandList *const *lists)
{
	next_execute(queue, count, lists);
	EnterCriticalSection(&lock);
	for (int s = 0; s < slots_count; s++) {
		if (slots[s].state != slot_recorded)
			continue;
		for (UINT i = 0; i < count; i++)
			if (lists[i] == slots[s].list) {
				slots[s].fence = ++fence_value;
				ID3D12CommandQueue_Signal(queue, fence, slots[s].fence);
				slots[s].state = slot_submitted;
				if (shared != NULL && !slots[s].ui)
					InterlockedExchange64((volatile LONG64 *)&shared->signaled, (LONG64)slots[s].frame.frame);
				SetEvent(wake);
				break;
			}
	}
	LeaveCriticalSection(&lock);
}

static void print_stats(void)
{
	double sorted[512];
	uint64_t n = latency_n < 512 ? latency_n : 512;
	memcpy(sorted, latency_us, n * sizeof(double));
	for (uint64_t i = 1; i < n; i++)
		for (uint64_t j = i; j > 0 && sorted[j - 1] > sorted[j]; j--) {
			double t = sorted[j];
			sorted[j] = sorted[j - 1];
			sorted[j - 1] = t;
		}
	uint64_t done_n = copies > 0 ? copies : 1;
	say("ffx copy stats frames=%llu copies=%llu skipped=%llu recycled=%llu dropped=%llu record_avg_us=%.1f "
	    "fence_wait_avg_us=%.1f fence_wait_max_us=%.1f gpu_latency_p50_us=%.0f "
	    "gpu_latency_p99_us=%.0f library_copy_avg_us=%.1f bytes_per_frame=%llu",
	    (unsigned long long)frames_seen, (unsigned long long)copies, (unsigned long long)skipped,
	    (unsigned long long)recycled, (unsigned long long)dropped,
	    record_us / (double)(frames_seen ? frames_seen : 1), wait_us / (double)done_n,
	    wait_max_us, n ? sorted[n / 2] : 0, n ? sorted[n * 99 / 100] : 0, library_us / (double)done_n,
	    (unsigned long long)(bytes / done_n));
}

// The latency samples are the last 512: from the copy's recording to its fence
static DWORD WINAPI deliver(void *unused)
{
	(void)unused;
	for (;;) {
		WaitForSingleObject(wake, INFINITE);
		for (;;) {
			Slot *next = NULL;
			EnterCriticalSection(&lock);
			for (int s = 0; s < slots_count; s++)
				if (slots[s].state == slot_submitted && (next == NULL || slots[s].fence < next->fence))
					next = &slots[s];
			LeaveCriticalSection(&lock);
			if (next == NULL)
				break;
			LONGLONG t0 = ticks();
			if (ID3D12Fence_GetCompletedValue(fence) < next->fence) {
				ID3D12Fence_SetEventOnCompletion(fence, next->fence, done);
				WaitForSingleObject(done, 2000);
			}
			// A copy not done in 2 s is never handed over half written
			if (ID3D12Fence_GetCompletedValue(fence) < next->fence) {
				EnterCriticalSection(&lock);
				dropped++;
				next->state = slot_free;
				LeaveCriticalSection(&lock);
				continue;
			}
			LONGLONG t1 = ticks();
			next->frame.completed = t1;
			void *data = NULL;
			D3D12_RANGE read = { 0, (SIZE_T)next->size }, written = { 0, 0 };
			if (SUCCEEDED(ID3D12Resource_Map(next->buffer, 0, &read, &data))) {
				next->frame.depth.data = next->ui ? NULL : (const char *)data + next->depth.Offset;
				next->frame.motion.data = next->ui ? NULL : (const char *)data + next->motion.Offset;
				next->frame.color.data = next->has_color ? (const char *)data + next->color.Offset : NULL;
				next->frame.final.data = next->ui ? (const char *)data + next->final.Offset : NULL;
				next->frame.copy_us = 0;
				if (dispatcher != NULL)
					dispatcher(handle, fg_proxy_frame, &next->frame);
				ID3D12Resource_Unmap(next->buffer, 0, &written);
			}
			EnterCriticalSection(&lock);
			if (next->ui) {
				ui_copies++;
				ui_bytes += (uint64_t)next->color.Footprint.RowPitch * next->color.Footprint.Height * 2;
				next->state = slot_free;
				BOOL report = ui_copies % 120 == 0;
				LeaveCriticalSection(&lock);
				if (report)
					say("ffx ui copies=%llu skipped=%llu bytes_per_frame=%llu", (unsigned long long)ui_copies,
					    (unsigned long long)ui_skipped, (unsigned long long)(ui_bytes / ui_copies));
				continue;
			}
			double wait = ticks_us(t1 - t0);
			wait_us += wait;
			wait_max_us = wait > wait_max_us ? wait : wait_max_us;
			latency_us[latency_n++ % 512] = ticks_us(t1 - next->frame.recorded);
			library_us += next->frame.copy_us;
			bytes += (uint64_t)next->depth.Footprint.RowPitch * next->depth.Footprint.Height +
			         (uint64_t)next->motion.Footprint.RowPitch * next->motion.Footprint.Height +
			         (next->has_color ? (uint64_t)next->color.Footprint.RowPitch * next->color.Footprint.Height : 0);
			copies++;
			next->state = slot_free;
			BOOL report = copies % 120 == 0;
			LeaveCriticalSection(&lock);
			if (report)
				print_stats();
		}
	}
	return 0;
}

// The queue's vtable is shared by every queue of the device: a queue of our own finds it
static BOOL start_copies(void)
{
	static int started;
	if (started)
		return started > 0;
	started = -1;
	D3D12_COMMAND_QUEUE_DESC desc = { D3D12_COMMAND_LIST_TYPE_DIRECT, 0, D3D12_COMMAND_QUEUE_FLAG_NONE, 0 };
	ID3D12CommandQueue *queue = NULL;
	if (FAILED(ID3D12Device_CreateCommandQueue(device, &desc, &IID_ID3D12CommandQueue, (void **)&queue)) ||
	    FAILED(ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence))) {
		say("ffx copies off: no queue or fence");
		return FALSE;
	}
	void **slot = (void **)&queue->lpVtbl->ExecuteCommandLists;
	DWORD old;
	if (!VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &old)) {
		say("ffx copies off: queue vtable read-only (error %lu)", GetLastError());
		return FALSE;
	}
	next_execute = (execute_t)*slot;
	*slot = (void *)hook_execute;
	VirtualProtect(slot, sizeof(void *), old, &old);
	ID3D12CommandQueue_Release(queue);
	QueryPerformanceFrequency(&frequency);
	wake = CreateEventW(NULL, FALSE, FALSE, NULL);
	done = CreateEventW(NULL, FALSE, FALSE, NULL);
	HANDLE thread = CreateThread(NULL, 0, deliver, NULL, 0, NULL);
	if (thread == NULL)
		return FALSE;
	CloseHandle(thread);
	started = 1;
	say("ffx copies on");
	return TRUE;
}

static D3D12_RESOURCE_STATES d3d12_state(uint32_t state)
{
	D3D12_RESOURCE_STATES out = D3D12_RESOURCE_STATE_COMMON;
	if (state & FFX_API_RESOURCE_STATE_UNORDERED_ACCESS)
		out |= D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
	if (state & FFX_API_RESOURCE_STATE_COMPUTE_READ)
		out |= D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
	if (state & FFX_API_RESOURCE_STATE_PIXEL_READ)
		out |= D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
	if (state & FFX_API_RESOURCE_STATE_COPY_SRC)
		out |= D3D12_RESOURCE_STATE_COPY_SOURCE;
	if (state & FFX_API_RESOURCE_STATE_COPY_DEST)
		out |= D3D12_RESOURCE_STATE_COPY_DEST;
	if (state & FFX_API_RESOURCE_STATE_RENDER_TARGET)
		out |= D3D12_RESOURCE_STATE_RENDER_TARGET;
	if (state & FFX_API_RESOURCE_STATE_DEPTH_ATTACHMENT)
		out |= D3D12_RESOURCE_STATE_DEPTH_WRITE;
	return out;
}

static void transition(ID3D12GraphicsCommandList *list, ID3D12Resource *r, D3D12_RESOURCE_STATES from,
                       D3D12_RESOURCE_STATES to)
{
	D3D12_RESOURCE_BARRIER b = { .Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION };
	b.Transition.pResource = r;
	b.Transition.Subresource = 0;
	b.Transition.StateBefore = from;
	b.Transition.StateAfter = to;
	ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}

static UINT plane_size(D3D12_RESOURCE_DESC *desc, D3D12_PLACED_SUBRESOURCE_FOOTPRINT *fp, UINT64 offset, UINT64 *end)
{
	UINT rows;
	UINT64 row_bytes, total;
	ID3D12Device_GetCopyableFootprints(device, desc, 0, 1, offset, fp, &rows, &row_bytes, &total);
	*end = fp->Offset + total;
	return rows;
}

// Recorded in the game's list before AMD's dispatch, while the resources are in the stated states
// Returns the slot, for the output's copy after AMD's pass
static Slot *record_copy(void *list_pointer, const struct FfxApiResource *depth, const struct FfxApiResource *motion,
                         const struct FfxApiResource *output, struct FfxApiDimensions2D render,
                         struct FfxApiDimensions2D upscale, struct FfxApiFloatCoords2D scale,
                         struct FfxApiFloatCoords2D jitter, bool reset)
{
	if (!copy_wanted || device == NULL || list_pointer == NULL || depth->resource == NULL || motion->resource == NULL ||
	    !start_copies())
		return NULL;
	LONGLONG t0 = ticks();
	frames_seen++;
	Slot *slot = &slots[frames_seen % vector_slots];
	// The game's thread never waits: a slot still in flight skips this frame's copy, and one whose
	// list was recorded but never ran for two rounds is taken back
	EnterCriticalSection(&lock);
	if (slot->state == slot_recorded && slot->frame.frame + 2 * vector_slots <= frames_seen) {
		slot->state = slot_free;
		recycled++;
	}
	BOOL busy = slot->state != slot_free;
	skipped += busy;
	LeaveCriticalSection(&lock);
	if (busy)
		return NULL;
	ID3D12Resource *dr = depth->resource, *mr = motion->resource;
	D3D12_RESOURCE_DESC dd = ID3D12Resource_GetDesc(dr), md = ID3D12Resource_GetDesc(mr);
	struct FfxApiDimensions2D mv_size = (upscale_flags & FFX_UPSCALE_ENABLE_DISPLAY_RESOLUTION_MOTION_VECTORS) ? upscale : render;
	dd.Width = render.width < dd.Width ? render.width : dd.Width;
	dd.Height = render.height < dd.Height ? render.height : dd.Height;
	md.Width = mv_size.width && mv_size.width < md.Width ? mv_size.width : md.Width;
	md.Height = mv_size.height && mv_size.height < md.Height ? mv_size.height : md.Height;
	D3D12_PLACED_SUBRESOURCE_FOOTPRINT dfp, mfp;
	UINT64 end;
	UINT drows = plane_size(&dd, &dfp, 0, &end);
	UINT mrows = plane_size(&md, &mfp, (end + 511) & ~(UINT64)511, &end);
	(void)drows;
	(void)mrows;
	D3D12_PLACED_SUBRESOURCE_FOOTPRINT cfp = { 0 };
	D3D12_RESOURCE_DESC cd = { 0 };
	slot->has_color = copy_wanted > 1 && output != NULL && output->resource != NULL;
	if (slot->has_color) {
		cd = ID3D12Resource_GetDesc((ID3D12Resource *)output->resource);
		cd.Width = upscale.width && upscale.width < cd.Width ? upscale.width : cd.Width;
		cd.Height = upscale.height && upscale.height < cd.Height ? upscale.height : cd.Height;
		plane_size(&cd, &cfp, (end + 511) & ~(UINT64)511, &end);
	}
	if (slot->buffer == NULL || slot->size < end) {
		if (slot->buffer != NULL)
			ID3D12Resource_Release(slot->buffer);
		slot->buffer = NULL;
		D3D12_HEAP_PROPERTIES heap = { .Type = D3D12_HEAP_TYPE_READBACK };
		D3D12_RESOURCE_DESC buffer = { .Dimension = D3D12_RESOURCE_DIMENSION_BUFFER, .Width = end, .Height = 1,
			                           .DepthOrArraySize = 1, .MipLevels = 1, .SampleDesc = { 1, 0 },
			                           .Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR };
		if (FAILED(ID3D12Device_CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE, &buffer,
		                                                D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource,
		                                                (void **)&slot->buffer))) {
			skipped++;
			return NULL;
		}
		slot->size = end;
	}
	slot->depth = dfp;
	slot->motion = mfp;
	slot->color = cfp;
	ID3D12GraphicsCommandList *list = list_pointer;
	D3D12_RESOURCE_STATES ds = d3d12_state(depth->state), ms = d3d12_state(motion->state);
	BOOL dmove = !(ds & D3D12_RESOURCE_STATE_COPY_SOURCE), mmove = !(ms & D3D12_RESOURCE_STATE_COPY_SOURCE);
	if (dmove)
		transition(list, dr, ds, D3D12_RESOURCE_STATE_COPY_SOURCE);
	if (mmove)
		transition(list, mr, ms, D3D12_RESOURCE_STATE_COPY_SOURCE);
	D3D12_TEXTURE_COPY_LOCATION dst = { .pResource = slot->buffer, .Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT };
	D3D12_TEXTURE_COPY_LOCATION src = { .Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX };
	D3D12_BOX dbox = { 0, 0, 0, (UINT)dd.Width, dd.Height, 1 }, mbox = { 0, 0, 0, (UINT)md.Width, md.Height, 1 };
	dst.PlacedFootprint = dfp;
	src.pResource = dr;
	ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, &dbox);
	dst.PlacedFootprint = mfp;
	src.pResource = mr;
	ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, &mbox);
	if (dmove)
		transition(list, dr, D3D12_RESOURCE_STATE_COPY_SOURCE, ds);
	if (mmove)
		transition(list, mr, D3D12_RESOURCE_STATE_COPY_SOURCE, ms);
	slot->ui = FALSE;
	slot->frame = (FGProxyFrame){ .frame = frames_seen,
		                          .kind = fg_proxy_vectors,
		                          .depth = { NULL, (uint32_t)dd.Width, dd.Height, dfp.Footprint.RowPitch, dfp.Footprint.Format },
		                          .motion = { NULL, (uint32_t)md.Width, md.Height, mfp.Footprint.RowPitch, mfp.Footprint.Format },
		                          .color = { NULL, (uint32_t)cd.Width, cd.Height, cfp.Footprint.RowPitch, cfp.Footprint.Format },
		                          .motion_scale = { scale.x, scale.y },
		                          .jitter = { jitter.x, jitter.y },
		                          .reset = reset,
		                          .flags = upscale_flags,
		                          .recorded = ticks() };
	EnterCriticalSection(&lock);
	slot->list = (ID3D12CommandList *)list;
	slot->state = slot_recorded;
	LeaveCriticalSection(&lock);
	record_us += ticks_us(ticks() - t0);
	if (frames_seen == 1)
		say("ffx copy depth %llux%u f%u (%u) pitch=%u motion %llux%u f%u (%u) pitch=%u states 0x%x 0x%x",
		    (unsigned long long)dd.Width, dd.Height, (unsigned)dd.Format, (unsigned)dfp.Footprint.Format,
		    dfp.Footprint.RowPitch, (unsigned long long)md.Width, md.Height, (unsigned)md.Format,
		    (unsigned)mfp.Footprint.Format, mfp.Footprint.RowPitch, (unsigned)ds, (unsigned)ms);
	return slot;
}

// Tests only (CARTOUCHE_FFX_COPY=2): the upscaler's output, once AMD's pass wrote it
static void record_output(Slot *slot, void *list_pointer, const struct FfxApiResource *output)
{
	if (slot == NULL || !slot->has_color)
		return;
	ID3D12GraphicsCommandList *list = list_pointer;
	ID3D12Resource *r = output->resource;
	D3D12_RESOURCE_STATES s = d3d12_state(output->state);
	BOOL move = !(s & D3D12_RESOURCE_STATE_COPY_SOURCE);
	if (move)
		transition(list, r, s, D3D12_RESOURCE_STATE_COPY_SOURCE);
	D3D12_TEXTURE_COPY_LOCATION dst = { .pResource = slot->buffer, .Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT };
	D3D12_TEXTURE_COPY_LOCATION src = { .pResource = r, .Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX };
	dst.PlacedFootprint = slot->color;
	D3D12_BOX box = { 0, 0, 0, slot->frame.color.width, slot->frame.color.height, 1 };
	ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, &box);
	if (move)
		transition(list, r, D3D12_RESOURCE_STATE_COPY_SOURCE, s);
}

static FfxApiPresentCallbackFunc game_present;
static void *game_present_context;
static volatile LONG64 present_calls;

// The game's frameID for each frame number, from its prepare dispatches
static struct {
	uint64_t id, frame;
} frame_ids[64];
static uint64_t ui_seen;

static BOOL fit_readback(Slot *slot, UINT64 end)
{
	if (slot->buffer != NULL && slot->size >= end)
		return TRUE;
	if (slot->buffer != NULL)
		ID3D12Resource_Release(slot->buffer);
	slot->buffer = NULL;
	D3D12_HEAP_PROPERTIES heap = { .Type = D3D12_HEAP_TYPE_READBACK };
	D3D12_RESOURCE_DESC buffer = { .Dimension = D3D12_RESOURCE_DIMENSION_BUFFER, .Width = end, .Height = 1,
		                           .DepthOrArraySize = 1, .MipLevels = 1, .SampleDesc = { 1, 0 },
		                           .Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR };
	if (FAILED(ID3D12Device_CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE, &buffer,
	                                                D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource,
	                                                (void **)&slot->buffer)))
		return FALSE;
	slot->size = end;
	return TRUE;
}

static void copy_plane(ID3D12GraphicsCommandList *list, Slot *slot, const struct FfxApiResource *r,
                       const D3D12_PLACED_SUBRESOURCE_FOOTPRINT *fp)
{
	D3D12_RESOURCE_STATES s = d3d12_state(r->state);
	BOOL move = !(s & D3D12_RESOURCE_STATE_COPY_SOURCE);
	if (move)
		transition(list, r->resource, s, D3D12_RESOURCE_STATE_COPY_SOURCE);
	D3D12_TEXTURE_COPY_LOCATION dst = { .pResource = slot->buffer, .Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT };
	D3D12_TEXTURE_COPY_LOCATION src = { .pResource = r->resource, .Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX };
	dst.PlacedFootprint = *fp;
	ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
	if (move)
		transition(list, r->resource, D3D12_RESOURCE_STATE_COPY_SOURCE, s);
}

// Tests only: a real frame's two images, without and with its UI, around the game's callback
static Slot *record_ui(ffxCallbackDescFrameGenerationPresent *params)
{
	if (params->isGeneratedFrame || !copy_wanted || device == NULL || params->commandList == NULL ||
	    params->currentBackBuffer.resource == NULL || params->outputSwapChainBuffer.resource == NULL || !start_copies())
		return NULL;
	Slot *slot = &slots[vector_slots + ui_seen++ % (slots_count - vector_slots)];
	if (slot->state != slot_free) {
		ui_skipped++;
		return NULL;
	}
	D3D12_RESOURCE_DESC back = ID3D12Resource_GetDesc((ID3D12Resource *)params->currentBackBuffer.resource);
	D3D12_RESOURCE_DESC out = ID3D12Resource_GetDesc((ID3D12Resource *)params->outputSwapChainBuffer.resource);
	D3D12_PLACED_SUBRESOURCE_FOOTPRINT bfp, ofp;
	UINT64 end;
	plane_size(&back, &bfp, 0, &end);
	plane_size(&out, &ofp, (end + 511) & ~(UINT64)511, &end);
	if (!fit_readback(slot, end)) {
		ui_skipped++;
		return NULL;
	}
	slot->ui = slot->has_color = TRUE;
	slot->color = bfp;
	slot->final = ofp;
	copy_plane(params->commandList, slot, &params->currentBackBuffer, &bfp);
	uint64_t number = frames_seen;
	EnterCriticalSection(&lock);
	if (frame_ids[params->frameID % 64].id == params->frameID)
		number = frame_ids[params->frameID % 64].frame;
	LeaveCriticalSection(&lock);
	slot->frame = (FGProxyFrame){ .frame = number,
		                          .kind = fg_proxy_ui,
		                          .color = { NULL, (uint32_t)back.Width, back.Height, bfp.Footprint.RowPitch, bfp.Footprint.Format },
		                          .final = { NULL, (uint32_t)out.Width, out.Height, ofp.Footprint.RowPitch, ofp.Footprint.Format },
		                          .recorded = ticks() };
	return slot;
}

static ffxReturnCode_t our_present(ffxCallbackDescFrameGenerationPresent *params, void *context)
{
	(void)context;
	LONG64 n = InterlockedIncrement64(&present_calls);
	char a[64], b[64], c[64];
	if (n <= 3 || n % 600 == 0)
		say("ffx present callback #%lld generated=%d frame=%llu back=%s ui=%s out=%s", (long long)n,
		    params->isGeneratedFrame, (unsigned long long)params->frameID,
		    resource(a, sizeof(a), &params->currentBackBuffer), resource(b, sizeof(b), &params->currentUI),
		    resource(c, sizeof(c), &params->outputSwapChainBuffer));
	Slot *slot = record_ui(params);
	ffxReturnCode_t status = game_present != NULL ? game_present(params, game_present_context) : FFX_API_RETURN_OK;
	if (slot != NULL) {
		copy_plane(params->commandList, slot, &params->outputSwapChainBuffer, &slot->final);
		EnterCriticalSection(&lock);
		slot->list = params->commandList;
		slot->state = slot_recorded;
		LeaveCriticalSection(&lock);
	}
	return status;
}

// The game's frame generation setting goes to the library; the test switches change what AMD gets
static ffxReturnCode_t configure_generation(ffxContext *context, const struct ffxConfigureDescFrameGeneration *given)
{
	static int told = -1;
	struct ffxConfigureDescFrameGeneration d = *given;
	int wanted = d.frameGenerationEnabled, on = fg_mode == fg_force || (fg_mode == fg_game && wanted);
	if (wanted * 2 + on != told) {
		say("ffx game frame generation %s, AMD's %s%s", wanted ? "on" : "off", on ? "on" : "off",
		    fg_mode == fg_ours ? " (ours instead)" : fg_mode == fg_force ? " (forced)" : "");
		told = wanted * 2 + on;
	}
	if (shared != NULL)
		shared->game_generates = on;
	d.frameGenerationEnabled = on;
	if (ui_wanted && d.presentCallback != NULL && d.presentCallback != our_present) {
		game_present = d.presentCallback;
		game_present_context = d.presentCallbackUserContext;
		d.presentCallback = our_present;
		d.presentCallbackUserContext = NULL;
	}
	return real_configure(context, &d.header);
}

ffxReturnCode_t ffxCreateContext(ffxContext *context, ffxCreateContextDescHeader *desc, const ffxAllocationCallbacks *memCb)
{
	if (!ready())
		return FFX_API_RETURN_NO_PROVIDER;
	ffxReturnCode_t status = real_create(context, desc, memCb);
	tell_create(desc, context ? *context : NULL, status);
	return status;
}

ffxReturnCode_t ffxDestroyContext(ffxContext *context, const ffxAllocationCallbacks *memCb)
{
	if (!ready())
		return FFX_API_RETURN_NO_PROVIDER;
	void *was = context ? *context : NULL;
	ffxReturnCode_t status = real_destroy(context, memCb);
	say("ffx destroy ctx=%p ret=%u", was, status);
	if (copies > 0)
		print_stats();
	return status;
}

ffxReturnCode_t ffxConfigure(ffxContext *context, const ffxConfigureDescHeader *desc)
{
	if (!ready())
		return FFX_API_RETURN_NO_PROVIDER;
	ffxReturnCode_t status = desc != NULL && desc->type == FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATION
		? configure_generation(context, (const void *)desc) : real_configure(context, desc);
	if (desc != NULL)
		tell_configure(context ? *context : NULL, desc, status);
	return status;
}

ffxReturnCode_t ffxQuery(ffxContext *context, ffxQueryDescHeader *desc)
{
	if (!ready())
		return FFX_API_RETURN_NO_PROVIDER;
	ffxReturnCode_t status = real_query(context, desc);
	if (desc != NULL)
		tell_query(context ? *context : NULL, desc, status);
	return status;
}

ffxReturnCode_t ffxDispatch(ffxContext *context, const ffxDispatchDescHeader *desc)
{
	static uint64_t upscales;
	if (!ready())
		return FFX_API_RETURN_NO_PROVIDER;
	if (desc != NULL && desc->type == FFX_API_DISPATCH_DESC_TYPE_UPSCALE) {
		const struct ffxDispatchDescUpscale *d = (const void *)desc;
		upscales++;
		Slot *slot = record_copy(d->commandList, &d->depth, &d->motionVectors, &d->output, d->renderSize, d->upscaleSize,
		                         d->motionVectorScale, d->jitterOffset, d->reset);
		ffxReturnCode_t status = real_dispatch(context, desc);
		record_output(slot, d->commandList, &d->output);
		tell_dispatch(context ? *context : NULL, desc, status, upscales);
		return status;
	} else if (desc != NULL && desc->type == FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE_V2) {
		const struct ffxDispatchDescFrameGenerationPrepareV2 *d = (const void *)desc;
		// After the copy, which counts the frame when there is no upscale dispatch
		if (upscales == 0)
			record_copy(d->commandList, &d->depth, &d->motionVectors, NULL, d->renderSize, d->renderSize,
			            d->motionVectorScale, d->jitterOffset, d->reset);
		EnterCriticalSection(&lock);
		frame_ids[d->frameID % 64].id = d->frameID;
		frame_ids[d->frameID % 64].frame = frames_seen;
		LeaveCriticalSection(&lock);
	}
	ffxReturnCode_t status = real_dispatch(context, desc);
	if (desc != NULL)
		tell_dispatch(context ? *context : NULL, desc, status, upscales);
	return status;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
	(void)reserved;
	if (reason == DLL_PROCESS_ATTACH) {
		self = instance;
		InitializeCriticalSection(&lock);
		DisableThreadLibraryCalls(instance);
	}
	return TRUE;
}
