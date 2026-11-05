// Launch options are the user's, the shell comes from STEAM_GAME_LAUNCH_SHELL. Both are
// quoted into one shell command line; unquoting it again must give back what went in.
// The input is the shell, a NUL, then the command (no NUL: no shell).
#include "fuzz.h"
#include "../dylib/hooks/hook_launch.c"

int   np_log_level = -1;
FILE *np_log_file  = NULL;

int np_hooks_env_lists_label(const char *var, const char *label) { return 0; }
int np_compat_runs_tool(const char *cmd) { return 1; }
int np_compat_app_runs_tool(uint32_t appid) { return 1; }
int np_rebind_import(const struct mach_header_64 *mh, intptr_t slide, const char *symbol,
                     void *replacement) { return 0; }

// One single-quoted word at *at, as sh reads it ('\'' included)
static char *unquote(const char **at) {
    const char *p = *at;
    char *out = malloc(strlen(p) + 1);
    size_t n = 0;
    for (;;) {
        if (*p != '\'') abort();
        for (p++; *p != '\''; p++) {
            if (!*p) abort();
            out[n++] = *p;
        }
        p++;
        if (p[0] == '\\' && p[1] == '\'') { out[n++] = '\''; p += 2; continue; }
        break;
    }
    out[n] = '\0';
    *at = p;
    return out;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    const uint8_t *nul = memchr(data, 0, size);
    char *shell = nul ? fz_cstr(data, (size_t)(nul - data)) : NULL;
    char *cmd = nul ? fz_cstr(nul + 1, size - (size_t)(nul - data) - 1) : fz_cstr(data, size);

    char *line = np_launch_shell(cmd, shell, -1, NULL);
    if (!line) abort();
    const char *at = line;
    if (!shell) {
        if (strncmp(at, "/bin/sh -c ", 11) != 0) abort();
        at += 11;
    } else {
        char *got = unquote(&at);
        if (strcmp(got, shell) != 0 || *at++ != ' ') abort();
        free(got);
    }
    char *got = unquote(&at);
    if (strcmp(got, cmd) != 0 || *at) abort();
    free(got);
    free(line);

    // The backslash doubling of game arguments, in a buffer grown as Steam's would be
    size_t len = strlen(cmd), extra = np_count_backslashes(cmd);
    char *buf = malloc(len + extra + 1);
    memcpy(buf, cmd, len + 1);
    np_double_backslashes(buf, len, extra);
    if (strlen(buf) != len + extra) abort();
    free(buf);

    free(shell);
    free(cmd);
    return 0;
}
