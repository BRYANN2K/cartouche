// The signature database is JSON in the support folder, so anything that can write
// there chooses what the loader parses.
#include "fuzz.h"
#include "../dylib/resolver/sigdb.c"

int   np_log_level = -1;
FILE *np_log_file  = NULL;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    np_sigdb_t db;
    if (np_load_profile(fz_file("profile.json", data, size), &db) == 0)
        np_free_profile(&db);
    return 0;
}
