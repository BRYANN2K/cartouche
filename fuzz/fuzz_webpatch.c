// The webpatch rewrites the JavaScript chunks Steam serves its UI from, on every open of a
// steamui path. The chunk is Valve's and changes with each client update.
//
// Built with -DFZ_SEED_MAIN it writes seeds made from the gate table itself, with each
// capture filled by an identifier: fuzz_webpatch <dir>. No Steam code goes in the corpus.
#include "fuzz.h"
#include "cartouche_identity.h"
#include "../dylib/feats/webpatch.c"

int   np_log_level = -1;
FILE *np_log_file  = NULL;

static int g_platform_js;

char *np_nativeplatform_javascript(void) {
    return g_platform_js ? strdup("window.__CARTOUCHE_NATIVE_PLATFORM__={};\n") : NULL;
}

static void setup(void) {
    static const char *const fex[] = { CARTOUCHE_TOOL_PREFIX "-fex", CARTOUCHE_TOOL_PREFIX "-fex2" };
    np_webpatch_set_steam_root("/Users/u/Library/Application Support/Steam");
    np_webpatch_set_fallback_tool(CARTOUCHE_TOOL_PREFIX);
    np_webpatch_set_fex_tools(fex, 2);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    setup();
    g_platform_js = size && (data[0] & 1);
    size_t out_len = 0;
    const char *shape = NULL;
    char *out = np_webpatch_transform(data, size, &out_len, &shape);
    if (out) {
        if (out[out_len] != '\0') abort();
        free(out);
    }

    char *path = fz_cstr(data, size < 1024 ? size : 1024);
    np_webpatch_should_patch(path);
    np_webpatch_is_download_commands(path);
    free(path);
    return 0;
}

#ifdef FZ_SEED_MAIN
static void put_find(FILE *f, const char *find) {
    for (const char *c = find; *c; c++) {
        const char *text = marker_text(*c);
        int ci = cap_index((unsigned char)*c);
        if (text) fputs(text, f);
        else if (ci >= 0) fprintf(f, "q%c", 'a' + ci);
        else fputc(*c, f);
    }
}

static void put_gates(FILE *f, const np_gate_t *gates, size_t count) {
    for (size_t g = 0; g < count; g++) {
        for (int n = 0; n < gates[g].expect; n++) {
            put_find(f, gates[g].find);
            fputs(";\n", f);
        }
    }
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    setup();
    char path[1024];
    for (size_t i = 0; i < NP_SHAPE_COUNT; i++) {
        snprintf(path, sizeof path, "%s/shape-%s.js", argv[1], g_shapes[i].name);
        FILE *f = fopen(path, "w");
        if (!f) return 1;
        fprintf(f, "\"%s\";\n", g_shapes[i].probe);
        put_gates(f, g_shapes[i].gates, g_shapes[i].count);
        fclose(f);
    }
    snprintf(path, sizeof path, "%s/fixes-library.js", argv[1]);
    FILE *f = fopen(path, "w");
    if (!f) return 1;
    put_gates(f, g_fixes, NP_FIX_COUNT);
    put_gates(f, g_library_filters, NP_LIBRARY_FILTER_COUNT);
    fclose(f);
    return 0;
}
#endif
