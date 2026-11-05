// Every process Steam starts goes through the spawn hooks, which rewrite its environment
// and look at its path. The input is the path, then the environment, one entry per line.
#include "fuzz.h"
#include "../dylib/hooks/hook_spawn.c"

int   np_log_level = -1;
FILE *np_log_file  = NULL;

int DobbyHook(void *address, void *replace_call, void **origin_call) { return -1; }
void *DobbySymbolResolver(const char *image_name, const char *symbol_name) { return NULL; }
int np_hooks_env_lists_label(const char *var, const char *label) { return 0; }

static size_t count(char *const *env) {
    size_t n = 0;
    while (env && env[n]) n++;
    return n;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    char *text = fz_cstr(data, size);
    char *envp[64];
    size_t n = 0;
    char *save = NULL;
    char *path = strtok_r(text, "\n", &save);
    for (char *e = strtok_r(NULL, "\n", &save); e && n < 63; e = strtok_r(NULL, "\n", &save))
        envp[n++] = e;
    envp[n] = NULL;

    np_target_keeps_insert(path);

    char **stripped = np_without_insert(envp);
    if (stripped) {
        if (count(stripped) > n) abort();
        for (size_t i = 0; stripped[i]; i++)
            if (np_is_steam_only(stripped[i])) abort();
        free(stripped);
    }

    np_insert_entry = "DYLD_INSERT_LIBRARIES=/x/cartouche.dylib";
    char **full = np_with_insert(envp);
    if (full) {
        if (count(full) != n + 1 || full[n] != np_insert_entry) abort();
        free(full);
    }
    np_insert_entry = NULL;
    free(text);
    return 0;
}
