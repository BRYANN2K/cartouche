// The unix half of the FFX proxy, loaded by Wine's ntdll next to the proxy DLL. It passes the
// proxy's log lines and copied frames to the frame generation library when the game runs with
// it, and prints the lines itself when it does not.
#include <dlfcn.h>
#include <stdio.h>

#include "fg_proxy.h"

typedef int32_t NTSTATUS;
typedef NTSTATUS (*unixlib_entry_t)(void *args);

#define STATUS_SUCCESS ((NTSTATUS)0)
#define STATUS_DLL_NOT_FOUND ((NTSTATUS)0xC0000135)

static void (*library_log)(const char *);
static void (*library_frame)(FGProxyFrame *);

// args: where the proxy wants the shared block, NULL when there is no library
static NTSTATUS attach(void *args)
{
	FGProxyShared *(*shared)(void) = (FGProxyShared * (*)(void)) dlsym(RTLD_DEFAULT, FG_PROXY_SHARED);
	if (args != NULL)
		*(FGProxyShared **)args = shared != NULL ? shared() : NULL;
	library_log = (void (*)(const char *))dlsym(RTLD_DEFAULT, FG_PROXY_LOG);
	library_frame = (void (*)(FGProxyFrame *))dlsym(RTLD_DEFAULT, FG_PROXY_FRAME);
	return STATUS_SUCCESS;
}

static NTSTATUS log_line(void *args)
{
	if (library_log != NULL)
		library_log(args);
	else
		fprintf(stderr, "ffx: %s\n", (const char *)args);
	return STATUS_SUCCESS;
}

static NTSTATUS frame(void *args)
{
	if (library_frame == NULL)
		return STATUS_DLL_NOT_FOUND;
	library_frame(args);
	return STATUS_SUCCESS;
}

__attribute__((visibility("default"))) const unixlib_entry_t __wine_unix_call_funcs[] = { attach, log_line, frame };
