// Compat tool hooks
#include "hooks.h"
#include "../feats/compat.h"
#include "../feats/compatsvc.h"
#include "../feats/usershortcuts.h"
#include "../util/ptr.h"
#include "../util/log.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdbool.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

// Steam's allocator, for the strings written into a tool entry Steam owns and frees.
typedef void *(*fn_PlatAlloc)(unsigned long size);
typedef void  (*fn_PlatFree)(void *ptr);
static fn_PlatAlloc g_plat_alloc;
static fn_PlatFree  g_plat_free;

static void *orig_CCompatManager_Init = NULL;
typedef void *(*fn_CCompatManager_Init)(void *self, void *arg1);

// A failed DobbyHook leaves the target patched with no original. Every hook
// below gives up its feature on NULL rather than fault, for safety.
static void *hook_CCompatManager_Init(void *self, void *arg1) {
    fn_CCompatManager_Init orig = (fn_CCompatManager_Init)orig_CCompatManager_Init;
    if (!orig) {
        NP_ERR("hook_CCompatManager_Init: no original, cannot initialize the manager");
        return NULL;
    }
    void *ret = orig(self, arg1);

    np_compat_force_enable(self);

    return ret;
}

static void *orig_CCompatManager_BIsEnabled = NULL;
typedef bool (*fn_CCompatManager_BIsEnabled)(void *self, uint32_t appid);

// Runs on every compat query, forcing the global switch on. Native Mac
// apps are not routed through a compatibility tool.
static bool hook_CCompatManager_BIsEnabled(void *self, uint32_t appid) {
    fn_CCompatManager_BIsEnabled orig = (fn_CCompatManager_BIsEnabled)orig_CCompatManager_BIsEnabled;
    if (!orig) {
        NP_ERR("hook_CCompatManager_BIsEnabled: no original, reporting compat disabled");
        return false;
    }
    np_compat_force_enable(self);
    int added = np_compat_register_crossover(self);
    // A game's tool chosen in Cartouche, or tools that just appeared, so
    // Properties > Compatibility picks the change up without a reload.
    if (added > 0 || np_compat_apply_requests(self) > 0)
        np_compatsvc_state_changed();
    return orig(self, appid);
}

void np_hooks_compat_set_helpers(uintptr_t yld_register_tool,
                                 uintptr_t get_valid_platforms,
                                 uintptr_t find_tool_for_target_app,
                                 uintptr_t set_compat_tool_mapping,
                                 uintptr_t find_mapping,
                                 uintptr_t get_wildcard_mapping) {
    np_compat_set_register_fn(yld_register_tool);
    np_compat_set_valid_platforms_fn(get_valid_platforms);
    np_compat_set_find_tool_fn(find_tool_for_target_app);
    np_compat_set_mapping_fn(set_compat_tool_mapping);
    np_compat_set_app_mapping_fn(find_mapping);
    np_compat_set_wildcard_fn(get_wildcard_mapping);

    g_plat_alloc = (fn_PlatAlloc)dlsym(RTLD_DEFAULT, "Plat_Alloc");
    g_plat_free  = (fn_PlatFree)dlsym(RTLD_DEFAULT, "Plat_Free");
    if (!g_plat_alloc)
        NP_WARN("np_hooks_compat_set_helpers: Plat_Alloc unresolved, the local tool "
                "redirect stores Cartouche's own strings in Steam's tool entry");
}

static void *orig_FindToolForTargetApp = NULL;
typedef void *(*fn_FindToolForTargetApp)(void *self, uint32_t appid);

// An unmapped windows-only app resolves to no tool ("Install on Windows").
// Those are defaulted to CrossOver for quality UX.
static void *hook_FindToolForTargetApp(void *self, uint32_t appid) {
    fn_FindToolForTargetApp orig = (fn_FindToolForTargetApp)orig_FindToolForTargetApp;
    if (!orig) {
        NP_ERR("hook_FindToolForTargetApp: no original, resolving no tool for appID %u",
               appid);
        return NULL;
    }
    void *tool = orig(self, appid);

    if (tool || appid == 0)
        return tool;

    // The NP_COMPAT_TOOL_NONE sentinel is honored as an explicit refusal.
    const char *mapping = np_compat_app_mapping(self, appid);
    if (mapping && strcmp(mapping, NP_COMPAT_TOOL_NONE) == 0)
        return NULL;

    if (!np_compat_would_force(self, appid))
        return NULL;

    void *crossover = np_compat_registered_tool(self);
    if (crossover)
        NP_DBG("hook_FindToolForTargetApp: appID %u is windows-only, defaulting to CrossOver tool",
               appid);
    return crossover;
}

static void *orig_WindowsOnlyLookup = NULL;
// Returns a bool, but the whole register is passed through in case this resolves
// to the wrong function.
typedef uint64_t (*fn_WindowsOnlyLookup)(const void *map, const uint32_t *appid,
                                         const uint8_t *fallback);

static uint64_t hook_WindowsOnlyLookup(const void *map, const uint32_t *appid,
                                       const uint8_t *fallback) {
    fn_WindowsOnlyLookup orig = (fn_WindowsOnlyLookup)orig_WindowsOnlyLookup;
    if (!orig) {
        static const char once = 0;
        if (np_log_first_hit(&once, 0))
            NP_ERR("hook_WindowsOnlyLookup: no original, reporting every key missing");
        return fallback ? *fallback : 0;
    }
    uint64_t found = orig(map, appid, fallback);
    if ((uint32_t)found || !appid)
        return found;
    void *mgr = np_compat_manager();
    if (!np_compat_is_windows_only_table(mgr, map))
        return found;
    return np_usershortcuts_runs_exe(np_compat_user(mgr), *appid);
}

static void *orig_InternalSpecifyCompatTool = NULL;
typedef uint64_t (*fn_InternalSpecifyCompatTool)(void *self, uint64_t appid,
                                                 const char *name, void *config,
                                                 int priority);

// Every mapping change arrives here (global default/per-app), so this is
// where the page is notified.
static uint64_t hook_InternalSpecifyCompatTool(void *self, uint64_t appid,
                                               const char *name, void *config,
                                               int priority) {
    fn_InternalSpecifyCompatTool orig =
        (fn_InternalSpecifyCompatTool)orig_InternalSpecifyCompatTool;
    if (!orig) {
        NP_ERR("hook_InternalSpecifyCompatTool: no original, so appID %u keeps the "
               "mapping it had", (uint32_t)appid);
        return 0;
    }

    uint64_t result = orig(self, appid, name, config, priority);
    np_compatsvc_state_changed();
    return result;
}

// The trampoline is the client's own resolution without the CrossOver default.
void np_hooks_compat_publish_originals(void) {
    np_compat_set_chosen_tool_fn((uintptr_t)orig_FindToolForTargetApp);
}

// Proton converts is only for Linux, so the oslist match fails on macOS and the
// app shows "Install on Windows". Forcing x0 non-zero takes the from_oslist
// write path.
static void instrument_oslist_override_gate(void *address, void *ctx_) {
    (void)address;
    np_arm64_ctx_t *ctx = (np_arm64_ctx_t *)ctx_;
    if (ctx->general.x[0] != 0)
        return;
    ctx->general.x[0] = 1;
    uint64_t tool = ctx->general.x[21];
    uint32_t appid = (tool && np_plausible_ptr(tool) && np_compat_tool_layout_ok())
                     ? *(uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_APPID_OFF)) : 0;
    NP_LOG("instrument_oslist_override_gate: appid=%u install platform forced to tool from_oslist", appid);
}

//
#define TOOL_VERSION_OFF      0x04
#define TOOL_COMMANDLINE_OFF  0x18
#define TOOL_DEPENDENCY_OFF   0x20

// Proton targets linux with no macOS depot, so the depot lookup fails. Rewriting
// the tool to appid zero points the launch builder at the local CrossOver
// directory.
static void instrument_resolver_local_redirect(void *address, void *ctx_) {
    (void)address;
    np_arm64_ctx_t *ctx = (np_arm64_ctx_t *)ctx_;

    uint64_t tool = ctx->general.x[0];
    if (!tool || !np_plausible_ptr(tool) || !np_compat_tool_layout_ok())
        return;

    uint32_t tool_appid = *(uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_APPID_OFF));
    if (tool_appid == 0)
        return;

    const char *tool_dir = np_compat_tool_dir();
    if (!tool_dir)
        return;

    // Steam treats both fields as its own heap strings and may Plat_Free them, so they
    // get copies from its allocator. Whether x0 is a per-call copy or the manager's
    // own entry is not known here, so the old strings are left alone (a small leak)
    // rather than freed under something else that may still point at them.
    const char *install = tool_dir;
    const char *commandline = np_compat_tool_commandline();
    if (g_plat_alloc) {
        size_t dir_len = strlen(tool_dir) + 1;
        size_t cmd_len = strlen(commandline) + 1;
        char *dir_copy = g_plat_alloc((unsigned long)dir_len);
        char *cmd_copy = dir_copy ? g_plat_alloc((unsigned long)cmd_len) : NULL;
        if (!cmd_copy) {
            if (dir_copy && g_plat_free) g_plat_free(dir_copy);
            NP_ERR("instrument_resolver_local_redirect: no memory for tool %u's strings, "
                   "not redirected", tool_appid);
            return;
        }
        memcpy(dir_copy, tool_dir, dir_len);
        memcpy(cmd_copy, commandline, cmd_len);
        install = dir_copy;
        commandline = cmd_copy;
    }

    *(uint32_t *)(tool + TOOL_VERSION_OFF)     = 2;
    *(uint32_t *)(tool + TOOL_DEPENDENCY_OFF)  = 0;
    *(uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_APPID_OFF)) = 0;
    *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_INSTALL_OFF)) = install;
    *(const char **)(tool + TOOL_COMMANDLINE_OFF) = commandline;

    NP_LOG("instrument_resolver_local_redirect: tool %u routed to local CrossOver tool at %s",
           tool_appid, tool_dir);
}

static void *orig_TerminateProcessByPid = NULL;
typedef int (*fn_TerminateProcessByPid)(int pid);

// The process image of a run script is the shell, so the script is read from its
// arguments: argv[1] when the kernel ran the script, or the -c command when a shell
// was asked to. Anything else is not a pid this signals.
static int runs_tool_script(int pid) {
    int mib[3] = { CTL_KERN, KERN_ARGMAX, 0 };
    int argmax = 0;
    size_t size = sizeof argmax;
    if (sysctl(mib, 2, &argmax, &size, NULL, 0) != 0 || argmax <= 0) return 0;

    char *buf = malloc((size_t)argmax);
    if (!buf) return 0;
    mib[1] = KERN_PROCARGS2;
    mib[2] = pid;
    size = (size_t)argmax;
    int found = 0;
    if (sysctl(mib, 3, buf, &size, NULL, 0) == 0 && size > sizeof(int)) {
        // argc, the exec path, NUL padding, then argv.
        int argc;
        memcpy(&argc, buf, sizeof argc);
        const char *p = buf + sizeof argc, *end = buf + size;
        const char *nul = memchr(p, '\0', (size_t)(end - p));
        p = nul ? nul : end;
        while (p < end && !*p) p++;
        const char *argv[3] = { NULL, NULL, NULL };
        for (int i = 0; i < argc && i < 3 && p < end; i++) {
            nul = memchr(p, '\0', (size_t)(end - p));
            if (!nul) break;
            argv[i] = p;
            p = nul + 1;
        }
        // hook_launch hands tool launches to "/bin/sh -c <cmd>" or to
        // STEAM_GAME_LAUNCH_SHELL <cmd>; a shell that execs the script leaves its path.
        if (argv[1] && argv[1][0] == '-')
            found = np_compat_runs_tool(argv[2]);
        else
            found = np_compat_is_tool_run_path(argv[1]) || np_compat_runs_tool(argv[1]);
    }
    free(buf);
    return found;
}

static int hook_TerminateProcessByPid(int pid) {
    fn_TerminateProcessByPid orig = (fn_TerminateProcessByPid)orig_TerminateProcessByPid;
    int ret = orig ? orig(pid) : 0;
    if (!orig)
        NP_ERR("hook_TerminateProcessByPid: no original, signalling pid %d directly", pid);
    if (ret == 0 && pid > 0) {
        if (!runs_tool_script(pid)) {
            NP_WARN("hook_TerminateProcessByPid: pid %d is not a Cartouche tool's run "
                    "script, so it is not signalled", pid);
            return ret;
        }
        if (kill(pid, SIGTERM) == 0) {
            NP_LOG("hook_TerminateProcessByPid: pid %d has no running application, "
                   "sent SIGTERM to run script for prefix teardown", pid);
            return 1;
        }
    }
    return ret;
}

static np_patch_entry_t g_hooks[] = {
    {
        .label    = "CCompatManager::Init",
        .signature = "CCompatManager::Init",
        .entry    = (void *)hook_CCompatManager_Init,
        .trampoline = &orig_CCompatManager_Init,
    },
    {
        .label    = "CCompatManager::BIsCompatibilityToolEnabled",
        .signature = "CCompatManager::BIsCompatibilityToolEnabled",
        .entry    = (void *)hook_CCompatManager_BIsEnabled,
        .trampoline = &orig_CCompatManager_BIsEnabled,
    },
    {
        .label    = "CCompatManager::FindToolForTargetApp",
        .signature = "CCompatManager::FindToolForTargetApp",
        .entry    = (void *)hook_FindToolForTargetApp,
        .trampoline = &orig_FindToolForTargetApp,
    },
    {
        .label    = "CCompatManager::WindowsOnlyLookup",
        .signature = "CCompatManager::WindowsOnlyLookup",
        .entry    = (void *)hook_WindowsOnlyLookup,
        .trampoline = &orig_WindowsOnlyLookup,
    },
    {
        .label    = "CCompatManager::InternalSpecifyCompatTool",
        .signature = "CCompatManager::InternalSpecifyCompatTool",
        .entry    = (void *)hook_InternalSpecifyCompatTool,
        .trampoline = &orig_InternalSpecifyCompatTool,
    },
    {
        .label    = "CCompatManager::GetOSListOverrideForApp.oslist_gate",
        .signature = "CCompatManager::GetOSListOverrideForApp.oslist_gate",
        .entry    = (void *)instrument_oslist_override_gate,
        .trampoline = NULL,
        .mode     = NP_PATCH_PREHOOK,
    },
    {
        .label    = "CCompatManager::ResolveCompatToolForApp.local_redirect",
        .signature = "CCompatManager::ResolveCompatToolForApp.local_redirect",
        .entry    = (void *)instrument_resolver_local_redirect,
        .trampoline = NULL,
        .mode     = NP_PATCH_PREHOOK,
    },
    {
        .label    = "CAppManager::TerminateProcessByPid",
        .signature = "CAppManager::TerminateProcessByPid",
        .entry    = (void *)hook_TerminateProcessByPid,
        .trampoline = &orig_TerminateProcessByPid,
    },
};

int np_hooks_compat_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

np_patch_entry_t *np_hooks_compat_defs(void) {
    return g_hooks;
}
