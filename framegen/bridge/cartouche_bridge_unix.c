// The unix half of the Wine bridge, loaded by Wine's ntdll next to cartouche_bridge.dll. It
// runs in the game's process, so the frame generation library is one dlsym away.
#include <dlfcn.h>
#include <os/lock.h>
#include <os/os_sync_wait_on_address.h>

#include "fg_bridge.h"

typedef int32_t NTSTATUS;
typedef NTSTATUS (*unixlib_entry_t)(void *args);

#define STATUS_SUCCESS ((NTSTATUS)0)
#define STATUS_BUFFER_OVERFLOW ((NTSTATUS)0x80000005)
#define STATUS_DLL_NOT_FOUND ((NTSTATUS)0xC0000135)

static FGBridgeRing *ring;
static os_unfair_lock push_lock = OS_UNFAIR_LOCK_INIT;

static NTSTATUS attach(void *args)
{
	(void)args;
	FGBridgeRing *(*get)(void) = (FGBridgeRing * (*)(void)) dlsym(RTLD_DEFAULT, FG_BRIDGE_RING);
	ring = get != NULL ? get() : NULL;
	return ring != NULL ? STATUS_SUCCESS : STATUS_DLL_NOT_FOUND;
}

static NTSTATUS frame(void *args)
{
	if (ring == NULL)
		return STATUS_DLL_NOT_FOUND;
	os_unfair_lock_lock(&push_lock);
	uint64_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
	if (head - atomic_load(&ring->tail) >= fg_bridge_slots) {
		os_unfair_lock_unlock(&push_lock);
		atomic_fetch_add(&ring->full, 1);
		return STATUS_BUFFER_OVERFLOW;
	}
	ring->slots[head % fg_bridge_slots] = *(const FGBridgeMessage *)args;
	atomic_store(&ring->head, head + 1);
	os_unfair_lock_unlock(&push_lock);
	if (atomic_load(&ring->waiting))
		os_sync_wake_by_address_any(&ring->head, sizeof(uint64_t), OS_SYNC_WAKE_BY_ADDRESS_NONE);
	return STATUS_SUCCESS;
}

static NTSTATUS stats(void *args)
{
	void (*get)(FGBridgeStats *) = (void (*)(FGBridgeStats *))dlsym(RTLD_DEFAULT, FG_BRIDGE_STATS);
	if (get == NULL)
		return STATUS_DLL_NOT_FOUND;
	get(args);
	return STATUS_SUCCESS;
}

static NTSTATUS metal(void *args)
{
	static int32_t (*call)(FGBridgeMetal *);
	if (call == NULL)
		call = (int32_t(*)(FGBridgeMetal *))dlsym(RTLD_DEFAULT, FG_BRIDGE_METAL);
	return call != NULL ? call(args) : STATUS_DLL_NOT_FOUND;
}

__attribute__((visibility("default"))) const unixlib_entry_t __wine_unix_call_funcs[] = { attach, frame, stats, metal };
