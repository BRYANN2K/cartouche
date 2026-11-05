// The icon extractor reads any .exe the user adds as a shortcut: a hostile PE header,
// section table or resource tree must not reach outside the mapping.
#include "fuzz.h"
#include "../dylib/util/peicon.c"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    size_t len = 0;
    uint8_t *ico = icon_from_map(data, size, &len);
    if (ico) {
        // Every byte of the icon must be initialised and inside the allocation
        volatile uint8_t sum = 0;
        for (size_t i = 0; i < len; i++) sum ^= ico[i];
        free(ico);
    }
    return 0;
}
