// Both WebUI services register into the one route table the client exposes. The two
// units are linked here as they are in the dylib, so a once-guard that leaks between
// them, a route cap they overflow, or a name they collide on shows up. The registry
// below records what each service asks for.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <mach-o/loader.h>

#include "../feats/webui.h"
#include "../feats/compatsvc.h"
#include "../feats/libexport.h"

#define REG_MAX 8
static char      reg_names[REG_MAX][80];
static uintptr_t reg_reqs[REG_MAX], reg_resps[REG_MAX];
static np_webui_handler_fn reg_handlers[REG_MAX];
static int       reg_count;

uintptr_t np_webui_registry(void) { return 1; }

int np_webui_register_route(const char *name, uintptr_t request_vptr,
                            uintptr_t response_vptr, np_webui_handler_fn handler) {
    if (reg_count < REG_MAX) {
        snprintf(reg_names[reg_count], sizeof reg_names[0], "%s", name);
        reg_reqs[reg_count] = request_vptr;
        reg_resps[reg_count] = response_vptr;
        reg_handlers[reg_count] = handler;
        reg_count++;
    }
    return 1;
}

int np_webui_parse_into(uintptr_t message, const void *bytes, uint32_t len) {
    (void)message; (void)bytes; (void)len;
    return 1;
}

int np_webui_notify(const char *name, uintptr_t message) {
    (void)name; (void)message;
    return 1;
}

uintptr_t np_webui_new_message(uintptr_t vptr) {
    (void)vptr;
    return 1;
}

// Every type resolves, so both services find their message vtables.
uintptr_t np_rtti_vptr(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t text_base, size_t text_size, const char *name) {
    (void)mh; (void)slide; (void)text_base; (void)text_size; (void)name;
    return 1;
}

// Compat layer: only reached once a route handler runs, which this check does not do.
void *np_compat_manager(void) { return NULL; }
uint32_t np_compat_tool_off(uint32_t ref) { return ref; }
size_t np_compat_tool_stride(void) { return 0x130; }
uint32_t np_compat_enabled_off(void) { return 0x7B0; }
uint32_t np_compat_manager_tools_max(void) { return 40; }
uint32_t np_compat_valid_platforms(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid; return 0;
}
bool np_compat_would_force(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid; return false;
}
void *np_compat_tool_for_app(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid; return NULL;
}
void *np_compat_chosen_tool(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid; return NULL;
}
const char *np_compat_app_mapping(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid; return NULL;
}
const char *np_compat_wildcard_mapping(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid; return NULL;
}
void *np_compat_registered_tool(void *mgr) { (void)mgr; return NULL; }
void np_compat_map_tool(void *mgr, uint32_t appid, const char *tool_name) {
    (void)mgr; (void)appid; (void)tool_name;
}

int   np_log_level = -1;
FILE *np_log_file  = NULL;

int np_log_first_hit(const void *anchor, unsigned long tag) {
    (void)anchor; (void)tag;
    return 1;
}

static int failures;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static int route_at(const char *name) {
    for (int i = 0; i < reg_count; i++)
        if (strcmp(reg_names[i], name) == 0) return i;
    return -1;
}

int main(void) {
    // Registration looks under the support dir; keep that in the scratch tree.
    setenv("HOME", "out/services-check-home", 1);

    // CompatSvc first, like hook_webui does it, then the export route on top.
    np_compatsvc_register(NULL, 0, 0, 0);
    np_libexport_register(NULL, 0, 0, 0);

    check(np_compatsvc_routes() == NP_COMPATSVC_READY,
          "compatsvc settles ready with libexport present");
    check(np_libexport_routes() == NP_LIBEXPORT_READY,
          "libexport settles ready after compatsvc");

    check(reg_count == 3, "the two services register three routes in total");

    int get = route_at("CompatManager.GetCompatTools#1");
    int set = route_at("CompatManager.SpecifyCompatTool#1");
    int exp = route_at("Cartouche.ExportOwnedGames#1");
    check(get >= 0 && set >= 0 && exp >= 0,
          "compat tools, specify and owned-export routes all land");

    if (get >= 0 && set >= 0 && exp >= 0) {
        check(reg_handlers[get] && reg_handlers[set] && reg_handlers[exp],
              "every route carries a handler");
        check(reg_handlers[get] != reg_handlers[set]
              && reg_handlers[get] != reg_handlers[exp]
              && reg_handlers[set] != reg_handlers[exp],
              "no two routes share a handler");
        check(reg_reqs[get] && reg_resps[get] && reg_reqs[exp] && reg_resps[exp],
              "every route carries its request and response vtables");
    }

    // A second pass does not duplicate either service's routes.
    np_compatsvc_register(NULL, 0, 0, 0);
    np_libexport_register(NULL, 0, 0, 0);
    check(reg_count == 3, "a second registration pass adds nothing");

    if (failures) {
        printf("==> services: %d check(s) failed\n", failures);
        return 1;
    }
    printf("==> services: compatsvc and libexport register all three routes side by side\n");
    return 0;
}
