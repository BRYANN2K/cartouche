// The game's half of the Wine bridge to the frame generation library. Built with mingw and
// marked as a Wine builtin, so ntdll pairs it with cartouche_bridge.so, its unix half, and
// hands out the handle __wine_unix_call needs. Built without the mark (CARTOUCHE_BRIDGE_KIND
// "native"), it stands for a game's own DLL of the same name.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <x86intrin.h>

#include "fg_bridge.h"

#ifndef CARTOUCHE_BRIDGE_KIND
#define CARTOUCHE_BRIDGE_KIND "builtin"
#endif

// Wine's own: the information class that returns a builtin's unix call table
enum { memory_wine_unix_funcs = 1000 };

typedef UINT64 unixlib_handle_t;
typedef NTSTATUS(WINAPI *query_memory_t)(HANDLE, void *, ULONG, void *, SIZE_T, SIZE_T *);
typedef NTSTATUS(WINAPI *dispatcher_t)(unixlib_handle_t, unsigned int, void *);

static HMODULE self;
static unixlib_handle_t handle;
static dispatcher_t dispatcher;

__declspec(dllexport) const char *cartouche_bridge_kind(void)
{
	return CARTOUCHE_BRIDGE_KIND;
}

// 0 once the unix half has found the library
__declspec(dllexport) NTSTATUS cartouche_bridge_open(void)
{
	HMODULE ntdll = GetModuleHandleA("ntdll.dll");
	query_memory_t query = (query_memory_t)(void *)GetProcAddress(ntdll, "NtQueryVirtualMemory");
	dispatcher_t *entry = (dispatcher_t *)(void *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher");
	if (query == NULL || entry == NULL)
		return STATUS_ENTRYPOINT_NOT_FOUND;
	NTSTATUS status = query(GetCurrentProcess(), self, memory_wine_unix_funcs, &handle, sizeof(handle), NULL);
	if (status != 0)
		return status;
	dispatcher = *entry;
	return dispatcher(handle, fg_bridge_attach, NULL);
}

__declspec(dllexport) NTSTATUS cartouche_bridge_frame(UINT64 frame)
{
	if (dispatcher == NULL)
		return STATUS_INVALID_HANDLE;
	FGBridgeMessage message = { frame, __rdtsc() };
	return dispatcher(handle, fg_bridge_frame, &message);
}

__declspec(dllexport) NTSTATUS cartouche_bridge_stats(FGBridgeStats *stats)
{
	if (dispatcher == NULL)
		return STATUS_INVALID_HANDLE;
	return dispatcher(handle, fg_bridge_stats, stats);
}

__declspec(dllexport) NTSTATUS cartouche_bridge_metal(FGBridgeMetal *metal)
{
	if (dispatcher == NULL)
		return STATUS_INVALID_HANDLE;
	return dispatcher(handle, fg_bridge_metal, metal);
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
	(void)reserved;
	if (reason == DLL_PROCESS_ATTACH) {
		self = instance;
		DisableThreadLibraryCalls(instance);
	}
	return TRUE;
}
