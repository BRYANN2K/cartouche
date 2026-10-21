// Owned-library export WebUI service. The page sends its owned-games list and
// this writes steam-library.json into the app's support folder. The route is
// only reachable through the client's own WebUI transport, and the request has
// to carry the per-launch token only the injected library page knows.
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>
#include <sys/stat.h>

#include "libexport.h"
#include "webui.h"
#include "../resolver/anchor.h"
#include "../util/file.h"
#include "../util/log.h"
#include "../../vendor/cJSON.h"

// Route names carry the interface version the page asks for.
#define ROUTE_EXPORT_OWNED "Cartouche.ExportOwnedGames#1"

// The client's transport self-check messages carry an arbitrary bytes field, so
// the export payload borrows them instead of needing a new message type.
#define TYPE_EXPORT_REQUEST  "46CTransportValidation_CountOrderedBytes_Request"
#define TYPE_EXPORT_RESPONSE "47CTransportValidation_CountOrderedBytes_Response"

// CTransportValidation_CountOrderedBytes_Request. A bytes field is a libc++
// std::string behind an arena pointer (bit 0 tags arena ownership).
#define REQ_BYTES_OFF 24

// CTransportValidation_CountOrderedBytes_Response.
#define RESP_BYTE_COUNT 1

#define RESULT_OK   1
#define RESULT_FAIL 2

#define NP_TOKEN_BYTES 16
#define NP_TOKEN_LEN   (NP_TOKEN_BYTES * 2)

// The page sends a few hundred KB for a large library; four times the largest
// plausible one still fits comfortably.
#define NP_EXPORT_MAX (4u * 1024u * 1024u)
#define NP_NAME_MAX   256
#define NP_APPS_MAX   65536
#define NP_COLS_MAX   1024

#define NP_EXPORT_FILE "steam-library.json"

static char g_token[NP_TOKEN_LEN + 1];
static pthread_once_t g_token_once = PTHREAD_ONCE_INIT;
static int g_routes = NP_LIBEXPORT_UNTRIED;

static void make_token(void) {
    uint8_t raw[NP_TOKEN_BYTES];
    arc4random_buf(raw, sizeof raw);
    for (int i = 0; i < NP_TOKEN_BYTES; i++)
        snprintf(g_token + 2 * i, 3, "%02x", raw[i]);
}

const char *np_libexport_token(void) {
    pthread_once(&g_token_once, make_token);
    return g_token;
}

int np_libexport_routes(void) {
    return g_routes;
}

// libc++ std::string: byte 23 is the size for short strings, or the high byte
// of capacity with the top bit set marking the long form whose data is indirect.
static const uint8_t *bytes_field(uintptr_t field, size_t *out_len) {
    uintptr_t str = *(const uintptr_t *)field & ~(uintptr_t)1;
    *out_len = 0;
    if (!str) return NULL;
    const uint8_t *s = (const uint8_t *)str;
    if ((int8_t)s[23] >= 0) { *out_len = s[23]; return s; }
    const uint8_t *data = *(const uint8_t *const *)s;
    size_t len = *(const size_t *)(s + 8);
    if (!data || len > NP_EXPORT_MAX + NP_TOKEN_LEN + 1) return NULL;
    *out_len = len;
    return data;
}

static void pb_varint(uint8_t **p, uint64_t v) {
    while (v >= 0x80) { *(*p)++ = (uint8_t)(v | 0x80); v >>= 7; }
    *(*p)++ = (uint8_t)v;
}

typedef struct { const uint8_t *p, *end; } np_vdf_t;

// One token per call: '{' or '}' for braces, 's' for a quoted string in out.
static int vdf_next(np_vdf_t *v, char *out, size_t cap) {
    while (v->p < v->end) {
        uint8_t c = *v->p;
        if (c == '{' || c == '}') { v->p++; return c; }
        if (c == '"') {
            v->p++;
            size_t n = 0;
            while (v->p < v->end && *v->p != '"') {
                if (n + 1 < cap) out[n++] = (char)*v->p;
                v->p++;
            }
            if (v->p < v->end) v->p++;
            out[n] = '\0';
            return 's';
        }
        v->p++;
    }
    return 0;
}

static int decimal(const char *s, size_t max) {
    size_t n = strlen(s);
    if (!n || n > max) return 0;
    for (size_t i = 0; i < n; i++)
        if (s[i] < '0' || s[i] > '9') return 0;
    return 1;
}

// The steamid64 of the account loginusers.vdf marks most recent, falling back
// to the highest timestamp when nothing is marked. NULL when no account shows.
static char *loginusers_steamid(const char *home) {
    char path[1200];
    snprintf(path, sizeof path,
             "%s/Library/Application Support/Steam/config/loginusers.vdf", home);
    size_t len = 0;
    uint8_t *buf = np_read_whole_file(path, &len);
    if (!buf) return NULL;
    np_vdf_t v = { buf, buf + len };
    char name[64], cur[32] = "", pick[32] = "";
    uint64_t cur_ts = 0, pick_ts = 0;
    int cur_recent = 0, pick_recent = 0, depth = 0, tok;
    while ((tok = vdf_next(&v, name, sizeof name))) {
        if (tok == '{') { depth++; continue; }
        if (tok == '}') {
            if (depth == 2 && decimal(cur, 20)) {
                if (cur_recent || (!pick_recent && cur_ts > pick_ts)) {
                    strncpy(pick, cur, sizeof pick - 1);
                    pick[sizeof pick - 1] = '\0';
                    pick_ts = cur_ts;
                    pick_recent = cur_recent;
                }
                cur[0] = '\0'; cur_ts = 0; cur_recent = 0;
            }
            if (depth > 0) depth--;
            continue;
        }
        if (depth == 1) {
            strncpy(cur, name, sizeof cur - 1);
            cur[sizeof cur - 1] = '\0';
            cur_ts = 0; cur_recent = 0;
            continue;
        }
        if (depth == 2) {
            char val[64];
            int t2 = vdf_next(&v, val, sizeof val);
            if (t2 == '{') { depth++; continue; }
            if (t2 != 's') continue;
            if (strcmp(name, "MostRecent") == 0) cur_recent = strcmp(val, "1") == 0;
            else if (strcmp(name, "Timestamp") == 0) cur_ts = strtoull(val, NULL, 10);
        }
    }
    free(buf);
    return pick[0] ? strdup(pick) : NULL;
}

static int uint_field(const cJSON *obj, const char *key, double *out) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!cJSON_IsNumber(v)) return 0;
    double d = v->valuedouble;
    if (d < 0 || d > 4294967295.0 || d != floor(d)) return 0;
    *out = d;
    return 1;
}

// Copies a validated request into a fresh tree, dropping every unknown key.
static cJSON *validate_export(const uint8_t *json, size_t len, const char *account,
                              int *out_apps) {
    cJSON *root = cJSON_ParseWithLength((const char *)json, len);
    if (!cJSON_IsObject(root)) { cJSON_Delete(root); return NULL; }
    cJSON *out = NULL;
    do {
        double version;
        const cJSON *generated = cJSON_GetObjectItemCaseSensitive(root, "generated");
        const cJSON *steamid = cJSON_GetObjectItemCaseSensitive(root, "steamid");
        const cJSON *apps = cJSON_GetObjectItemCaseSensitive(root, "apps");
        if (!uint_field(root, "version", &version) || version != 1) break;
        if (!cJSON_IsNumber(generated) || generated->valuedouble < 0 ||
            generated->valuedouble != floor(generated->valuedouble)) break;
        if (!cJSON_IsString(steamid) || !decimal(steamid->valuestring, 20)) break;
        if (account && strcmp(steamid->valuestring, account)) {
            NP_WARN("libexport: payload is for %s, not this client account %s",
                    steamid->valuestring, account);
            break;
        }
        if (!cJSON_IsArray(apps) || cJSON_GetArraySize(apps) > NP_APPS_MAX) break;

        out = cJSON_CreateObject();
        if (!out) break;
        cJSON_AddNumberToObject(out, "version", 1);
        cJSON_AddNumberToObject(out, "generated", generated->valuedouble);
        cJSON_AddStringToObject(out, "steamid", steamid->valuestring);
        cJSON *clean_apps = cJSON_AddArrayToObject(out, "apps");
        const cJSON *a;
        int ok = clean_apps != NULL;
        cJSON_ArrayForEach(a, apps) {
            if (!ok || !cJSON_IsObject(a)) { ok = 0; break; }
            double appid, played, playtime;
            const cJSON *name = cJSON_GetObjectItemCaseSensitive(a, "name");
            const cJSON *installed = cJSON_GetObjectItemCaseSensitive(a, "installed");
            const cJSON *hidden = cJSON_GetObjectItemCaseSensitive(a, "hidden");
            if (!uint_field(a, "appid", &appid) || appid < 1 ||
                !cJSON_IsString(name) || strlen(name->valuestring) > NP_NAME_MAX * 4 ||
                !cJSON_IsBool(installed)) { ok = 0; break; }
            cJSON *o = cJSON_CreateObject();
            if (!o) { ok = 0; break; }
            cJSON_AddNumberToObject(o, "appid", appid);
            cJSON_AddStringToObject(o, "name", name->valuestring);
            cJSON_AddBoolToObject(o, "installed", cJSON_IsTrue(installed));
            const cJSON *lp = cJSON_GetObjectItemCaseSensitive(a, "last_played");
            if (lp) {
                if (!uint_field(a, "last_played", &played)) { cJSON_Delete(o); ok = 0; break; }
                cJSON_AddNumberToObject(o, "last_played", played);
            }
            const cJSON *pt = cJSON_GetObjectItemCaseSensitive(a, "playtime");
            if (pt) {
                if (!uint_field(a, "playtime", &playtime)) { cJSON_Delete(o); ok = 0; break; }
                cJSON_AddNumberToObject(o, "playtime", playtime);
            }
            if (hidden) {
                if (!cJSON_IsBool(hidden)) { cJSON_Delete(o); ok = 0; break; }
                cJSON_AddBoolToObject(o, "hidden", cJSON_IsTrue(hidden));
            }
            cJSON_AddItemToArray(clean_apps, o);
        }
        *out_apps = cJSON_GetArraySize(clean_apps);
        const cJSON *cols = cJSON_GetObjectItemCaseSensitive(root, "collections");
        if (ok && cols) {
            if (!cJSON_IsArray(cols) || cJSON_GetArraySize(cols) > NP_COLS_MAX) ok = 0;
            else {
                cJSON *out_cols = cJSON_AddArrayToObject(out, "collections");
                const cJSON *c;
                cJSON_ArrayForEach(c, cols) {
                    const cJSON *cid = cJSON_GetObjectItemCaseSensitive(c, "id");
                    const cJSON *cname = cJSON_GetObjectItemCaseSensitive(c, "name");
                    const cJSON *capps = cJSON_GetObjectItemCaseSensitive(c, "apps");
                    if (!ok || !cJSON_IsObject(c) || !cJSON_IsString(cid) ||
                        strlen(cid->valuestring) > 128 || !cJSON_IsString(cname) ||
                        strlen(cname->valuestring) > NP_NAME_MAX * 4 ||
                        !cJSON_IsArray(capps)) { ok = 0; break; }
                    cJSON *o = cJSON_CreateObject();
                    cJSON *oapps = o ? cJSON_AddArrayToObject(o, "apps") : NULL;
                    if (!o || !oapps) { cJSON_Delete(o); ok = 0; break; }
                    cJSON_AddStringToObject(o, "id", cid->valuestring);
                    cJSON_AddStringToObject(o, "name", cname->valuestring);
                    const cJSON *cap;
                    cJSON_ArrayForEach(cap, capps) {
                        if (!cJSON_IsNumber(cap) || cap->valuedouble < 1 ||
                            cap->valuedouble > 4294967295.0 ||
                            cap->valuedouble != floor(cap->valuedouble)) { ok = 0; break; }
                        cJSON_AddItemToArray(oapps, cJSON_CreateNumber(cap->valuedouble));
                    }
                    if (!ok) { cJSON_Delete(o); break; }
                    cJSON_AddItemToArray(out_cols, o);
                }
            }
        }
        if (!ok) { cJSON_Delete(out); out = NULL; }
    } while (0);
    cJSON_Delete(root);
    return out;
}

// Creates the support folder level by level; each level has to be a real
// directory or be creatable, so nothing under a symlink gets written into.
static int ensure_support_dir(const char *home, char *dir, size_t dsz) {
    np_support_path(dir, dsz, home, NULL);
    if (strlen(dir) <= strlen(home) + 1) return -1;
    struct stat st;
    for (char *p = dir + strlen(home) + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        int ok = lstat(dir, &st) == 0
            ? S_ISDIR(st.st_mode)
            : (errno == ENOENT && mkdir(dir, 0755) == 0);
        *p = '/';
        if (!ok) return -1;
    }
    return lstat(dir, &st) == 0
        ? (S_ISDIR(st.st_mode) ? 0 : -1)
        : (errno == ENOENT && mkdir(dir, 0755) == 0 ? 0 : -1);
}

// The page fetches the launch token from the loopback host instead of carrying
// one baked into the patched JavaScript, so a cached page always presents this
// launch's token. The bytes are served through a rewound anonymous fd.
int np_libexport_open_token(void) {
    const char *home = np_home_dir();
    if (!home) return -1;
    char dir[1200], tmpl[1400];
    if (ensure_support_dir(home, dir, sizeof dir) != 0) return -1;
    snprintf(tmpl, sizeof tmpl, "%s/libexport-token.XXXXXX", dir);
    int fd = mkstemp(tmpl);
    if (fd < 0) return -1;
    unlink(tmpl);

    const char *token = np_libexport_token();
    int ok = 1;
    for (size_t off = 0; ok && off < NP_TOKEN_LEN; ) {
        ssize_t w = write(fd, token + off, NP_TOKEN_LEN - off);
        if (w <= 0) ok = 0;
        else off += (size_t)w;
    }
    if (ok) ok = lseek(fd, 0, SEEK_SET) == 0;
    if (!ok) { close(fd); return -1; }
    return fd;
}

// Replaces the export through a temp file in the same directory so a reader
// never sees a partial file. Refuses a symlinked directory or target.
static int write_export(const char *home, const char *bytes, size_t len) {
    char dir[1200], file[1400], tmp[1500];
    if (ensure_support_dir(home, dir, sizeof dir) != 0) return -1;
    np_support_path(file, sizeof file, home, NP_EXPORT_FILE);
    struct stat st;
    if (lstat(file, &st) == 0 && !S_ISREG(st.st_mode)) return -1;
    snprintf(tmp, sizeof tmp, "%s.XXXXXX", file);
    int fd = mkstemp(tmp);
    if (fd < 0) return -1;
    int ok = fchmod(fd, 0600) == 0;
    for (size_t off = 0; ok && off < len; ) {
        ssize_t w = write(fd, bytes + off, len - off);
        if (w <= 0) ok = 0;
        else off += (size_t)w;
    }
    if (ok) ok = fsync(fd) == 0;
    if (close(fd) != 0) ok = 0;
    if (!ok || rename(tmp, file) != 0) { unlink(tmp); return -1; }
    int dfd = open(dir, O_RDONLY | O_DIRECTORY);
    if (dfd >= 0) { fsync(dfd); close(dfd); }
    return 0;
}

static int export_owned_games(uintptr_t request, uintptr_t response) {
    size_t len = 0;
    const uint8_t *data = bytes_field(request + REQ_BYTES_OFF, &len);
    if (len < NP_TOKEN_LEN + 2 || len > NP_EXPORT_MAX + NP_TOKEN_LEN + 1) {
        NP_WARN("libexport: request payload is %zu bytes, outside the %u limit",
                len, NP_EXPORT_MAX);
        return RESULT_FAIL;
    }
    if (!data || memcmp(data, np_libexport_token(), NP_TOKEN_LEN) ||
        data[NP_TOKEN_LEN] != '\n') {
        // A page cached from an earlier launch keeps asking with the old
        // token; say so once, at warn level, then keep quiet about it.
        static int refused;
        if (!refused) {
            refused = 1;
            NP_WARN("libexport: request without this launch's token refused");
        } else {
            NP_DBG("libexport: request without this launch's token refused");
        }
        return RESULT_FAIL;
    }
    const char *home = np_home_dir();
    if (!home) return RESULT_FAIL;
    char *account = loginusers_steamid(home);
    int napps = 0;
    cJSON *clean = validate_export(data + NP_TOKEN_LEN + 1,
                                   len - NP_TOKEN_LEN - 1, account, &napps);
    free(account);
    if (!clean) {
        NP_WARN("libexport: request payload failed validation");
        return RESULT_FAIL;
    }
    char *out = cJSON_PrintUnformatted(clean);
    int ok = out && write_export(home, out, strlen(out)) == 0;
    if (ok) {
        NP_LOG("libexport: wrote %d owned app(s) for account %s", napps,
               cJSON_GetObjectItemCaseSensitive(clean, "steamid")->valuestring);
        uint8_t resp[16], *p = resp;
        *p++ = RESP_BYTE_COUNT << 3;
        pb_varint(&p, (uint64_t)napps);
        np_webui_parse_into(response, resp, (uint32_t)(p - resp));
    }
    cJSON_free(out);
    cJSON_Delete(clean);
    return ok ? RESULT_OK : RESULT_FAIL;
}

void np_libexport_register(const struct mach_header_64 *mh, intptr_t slide,
                           uintptr_t text_base, size_t text_size) {
    if (g_routes != NP_LIBEXPORT_UNTRIED || !np_webui_registry()) return;

    uintptr_t request = np_rtti_vptr(mh, slide, text_base, text_size,
                                     TYPE_EXPORT_REQUEST);
    uintptr_t response = np_rtti_vptr(mh, slide, text_base, text_size,
                                      TYPE_EXPORT_RESPONSE);
    if (!request || !response) {
        g_routes = NP_LIBEXPORT_ABSENT;
        NP_LOG("libexport: the client has no message types for %s",
               ROUTE_EXPORT_OWNED);
        return;
    }
    np_webui_register_route(ROUTE_EXPORT_OWNED, request, response,
                            export_owned_games);
    g_routes = NP_LIBEXPORT_READY;
}
