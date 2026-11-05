// The appinfo helper parses Steam's appinfo.vdf and prints two id lists, which the dylib
// turns into JavaScript for the library page. Its output is fuzzed in place of the helper:
// the function-like macro renames the spawning definition away and points its one call here.
#include "fuzz.h"

static char *fuzz_helper(void);
#define run_helper(x) fuzz_helper##x()
#include "../dylib/feats/nativeplatform.c"
#undef run_helper

int   np_log_level = -1;
FILE *np_log_file  = NULL;

static const uint8_t *g_data;
static size_t g_size;

static char *fuzz_helper(void) {
    return fz_cstr(g_data, g_size);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    g_data = data;
    g_size = size;
    char *js = np_nativeplatform_javascript();
    if (js) {
        // Only digits and commas may reach the page from the helper
        const char *set = strstr(js, "new Set([");
        if (!set) abort();
        for (const char *p = set + 9; *p && *p != ']'; p++)
            if (!(*p >= '0' && *p <= '9') && *p != ',') abort();
        free(js);
    }
    return 0;
}
