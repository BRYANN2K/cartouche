// Byte patterns come from the signature database the dylib loads at start.
#include "fuzz.h"
#include "../dylib/resolver/aob.c"

int   np_log_level = -1;
FILE *np_log_file  = NULL;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // The first half is the pattern, the rest the memory it is scanned over
    size_t cut = size / 2;
    char *hex = fz_cstr(data, cut);
    np_byte_pattern_t pat;
    if (np_compile_pattern(hex, &pat) == 0) {
        uint8_t *mem = malloc(size - cut + 1);
        memcpy(mem, data + cut, size - cut);
        np_scan_sole_match((uintptr_t)mem, size - cut, &pat);
        free(mem);
        np_release_pattern(&pat);
    }
    free(hex);
    return 0;
}
