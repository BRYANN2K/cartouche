// The library export reads two things it does not write: loginusers.vdf, which Steam
// writes, and the owned-games JSON the library page sends over the WebUI transport.
// The first input byte picks which one the rest is.
#include "fuzz.h"
#include <sys/stat.h>
#include <mach-o/loader.h>

int np_webui_parse_into(uintptr_t message, const void *bytes, uint32_t len) {
    (void)message; (void)bytes; (void)len;
    return 1;
}
uintptr_t np_webui_registry(void) { return 1; }
int np_webui_register_route(const char *name, uintptr_t req, uintptr_t resp,
                            int (*handler)(uintptr_t, uintptr_t)) {
    (void)name; (void)req; (void)resp; (void)handler;
    return 1;
}
uintptr_t np_rtti_vptr(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t text_base, size_t text_size, const char *name) {
    (void)mh; (void)slide; (void)text_base; (void)text_size; (void)name;
    return 0;
}

int   np_log_level = -1;
FILE *np_log_file  = NULL;

#include "../dylib/feats/libexport.c"

static const char *steam_home(void) {
    static char home[600];
    if (!home[0]) {
        char path[700];
        snprintf(home, sizeof home, "%s/home", fz_dir());
        const char *parts[] = { "", "/Library", "/Library/Application Support",
                                "/Library/Application Support/Steam",
                                "/Library/Application Support/Steam/config" };
        for (size_t i = 0; i < sizeof parts / sizeof parts[0]; i++) {
            snprintf(path, sizeof path, "%s%s", home, parts[i]);
            mkdir(path, 0700);
        }
    }
    return home;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 1) return 0;
    if (data[0] & 1) {
        char path[800];
        snprintf(path, sizeof path, "%s/Library/Application Support/Steam/config/loginusers.vdf",
                 steam_home());
        FILE *f = fz_create(path);
        fwrite(data + 1, 1, size - 1, f);
        fclose(f);
        free(loginusers_steamid(steam_home()));
    } else {
        int apps = 0;
        const char *account = (data[0] & 2) ? "76561197960287930" : NULL;
        cJSON *out = validate_export(data + 1, size - 1, account, &apps);
        if (out) {
            char *text = cJSON_PrintUnformatted(out);
            free(text);
            cJSON_Delete(out);
        }
    }
    return 0;
}
