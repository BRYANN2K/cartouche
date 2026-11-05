// The compat layer reads three files from the app's support folder while Steam runs: the
// runner tool list, the backend tool list and the per-game tool requests. The first input
// byte picks the file, the rest is its content.
#include "fuzz.h"
#include <mach-o/loader.h>

#include "../dylib/feats/compat.c"

int   np_log_level = -1;
FILE *np_log_file  = NULL;

int np_log_first_hit(const void *anchor, unsigned long tag) {
    (void)anchor; (void)tag;
    return 1;
}

const char *np_home_dir(void) { return "/nonexistent"; }

int np_get_section_containing(const struct mach_header_64 *mh, intptr_t slide,
                              uintptr_t addr, uintptr_t *out_base, size_t *out_size) {
    (void)mh; (void)slide; (void)addr; (void)out_base; (void)out_size;
    return -1;
}

uintptr_t np_rtti_vptr(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t text_base, size_t text_size, const char *type_name) {
    (void)mh; (void)slide; (void)text_base; (void)text_size; (void)type_name;
    return 0;
}

// Stands in for CCompatManager::SetCompatToolMapping: a request reaching the client must
// name one of Cartouche's tools, or nothing to clear the choice.
static void fake_set_mapping(void *mgr, uint32_t appid, const char *tool, const char *config,
                             uint32_t priority) {
    (void)mgr; (void)appid; (void)config; (void)priority;
    if (*tool && !is_tool_name(tool)) abort();
}

// Retired lists are kept for the process's life by design; a fuzzing process would
// keep every one of them, so they are dropped between inputs here.
static void drop_lists(void) {
    for (int i = 0; i < g_retired_count; i++) free(g_retired[i]);
    free(g_retired);
    g_retired = NULL;
    g_retired_count = 0;
    free(g_tools);
    g_tools = NULL;
    g_tool_count = g_tool_cap = 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 1) return 0;
    char tools_dir[600];
    snprintf(tools_dir, sizeof tools_dir, "%s/compatibilitytools.d", fz_dir());
    static char fake_manager[64];

    switch (data[0] % 3) {
    case 0:
        np_compat_load_tool_list(fz_file("tools", data + 1, size - 1), tools_dir);
        break;
    case 1: {
        static const char runner[] = CARTOUCHE_TOOL_PREFIX "-a\tb1\tfex\tRunner A\n";
        np_compat_load_tool_list(fz_file("tools", (const uint8_t *)runner, sizeof runner - 1),
                                 tools_dir);
        np_compat_load_backend_tool_list(fz_file("backends", data + 1, size - 1), tools_dir);
        break;
    }
    default:
        np_compat_set_mapping_fn((uintptr_t)fake_set_mapping);
        np_compat_apply_requests_from(fake_manager, fz_file("requests", data + 1, size - 1));
        break;
    }

    // Every kept entry is what the webpatch and the registration read back: valid names
    pthread_mutex_lock(&g_tools_lock);
    for (int i = 0; i < g_tool_count; i++) {
        if (!is_tool_name(g_tools[i].name) || !is_display(g_tools[i].display)) abort();
        if (strlen(g_tools[i].dir) >= sizeof g_tools[i].dir) abort();
    }
    pthread_mutex_unlock(&g_tools_lock);
    drop_lists();
    return 0;
}
