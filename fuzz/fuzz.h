// Shared by the libFuzzer harnesses. Each harness includes the unit it fuzzes, the way the
// dylib/tests suites do, so static parsers are reachable without changing the shipped code.
#ifndef CARTOUCHE_FUZZ_H
#define CARTOUCHE_FUZZ_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

// The input as a C string, cut at its first NUL as the parser would see it.
static inline char *fz_cstr(const uint8_t *data, size_t size) {
    char *s = malloc(size + 1);
    if (!s) abort();
    memcpy(s, data, size);
    s[size] = '\0';
    return s;
}

// A scratch directory per process, for parsers that only take a path.
static inline const char *fz_dir(void) {
    static char dir[512];
    if (!dir[0]) {
        const char *tmp = getenv("TMPDIR");
        snprintf(dir, sizeof dir, "%s/cartouche-fuzz-XXXXXX", tmp && *tmp ? tmp : "/tmp");
        if (!mkdtemp(dir)) abort();
    }
    return dir;
}

static inline FILE *fz_create(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    FILE *f = fd < 0 ? NULL : fdopen(fd, "wb");
    if (!f) abort();
    return f;
}

// Writes the input to `name` under the scratch directory and returns the path.
static inline const char *fz_file(const char *name, const uint8_t *data, size_t size) {
    static char path[1024];
    snprintf(path, sizeof path, "%s/%s", fz_dir(), name);
    FILE *f = fz_create(path);
    if (size && fwrite(data, 1, size, f) != size) abort();
    fclose(f);
    return path;
}

#endif
