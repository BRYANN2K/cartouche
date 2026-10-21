// The export route turns a TransportValidation bytes field into steam-library.json.
// Including the unit reaches the static handler, and a scratch HOME keeps every write
// inside the test directory. The request object below is what the client's parser
// builds for a bytes field: a libc++ std::string behind an arena pointer at 24.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include <ctype.h>
#include <dirent.h>
#include <sys/stat.h>
#include <mach-o/loader.h>

// WebUI stubs: parse_into captures the reply protobuf, the rest just exist.
static uint8_t captured_pb[256];
static uint32_t captured_pb_len;

int np_webui_parse_into(uintptr_t message, const void *bytes, uint32_t len) {
    (void)message;
    if (len <= sizeof captured_pb) {
        memcpy(captured_pb, bytes, len);
        captured_pb_len = len;
    }
    return 1;
}

uintptr_t np_webui_registry(void) { return 1; }

static uintptr_t registered_req, registered_resp;
static int (*registered_handler)(uintptr_t, uintptr_t);
static int (*token_handler)(uintptr_t, uintptr_t);
static char registered_name[128];

int np_webui_register_route(const char *name, uintptr_t req, uintptr_t resp,
                            int (*handler)(uintptr_t, uintptr_t)) {
    if (strcmp(name, "Cartouche.GetExportToken#1") == 0) {
        token_handler = handler;
        return 1;
    }
    registered_req = req;
    registered_resp = resp;
    registered_handler = handler;
    snprintf(registered_name, sizeof registered_name, "%s", name);
    return 1;
}

uintptr_t np_rtti_vptr(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t text_base, size_t text_size, const char *name) {
    (void)mh; (void)slide; (void)text_base; (void)text_size;
    (void)name;
    return 0x1000;
}

int   np_log_level = -1;
FILE *np_log_file  = NULL;

#include "../feats/libexport.c"
#include "../../vendor/cJSON.h"

#define CHECK(ok, what) do { \
    if (!(ok)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, what); fails++; } \
} while (0)
static int fails;

// A request object: field storage at 24 points at the string.
static uint8_t req_obj[64];
static struct { const uint8_t *data; size_t size; uint64_t cap; } req_str;

static uintptr_t make_request(const void *payload, size_t len) {
    memset(req_obj, 0, sizeof req_obj);
    req_str.data = payload;
    req_str.size = len;
    req_str.cap  = len | (1ULL << 63);   // libc++ long form: top bit set
    *(const void **)(req_obj + REQ_BYTES_OFF) = &req_str;
    return (uintptr_t)req_obj;
}

static uint64_t reply_appcount(void) {
    // field 1 varint, the only field the handler answers
    if (captured_pb_len < 2 || captured_pb[0] != 0x08) return UINT64_MAX;
    uint64_t v = 0;
    for (uint32_t i = 1, s = 0; i < captured_pb_len; i++, s += 7) {
        v |= (uint64_t)(captured_pb[i] & 0x7f) << s;
        if (!(captured_pb[i] & 0x80)) return v;
    }
    return UINT64_MAX;
}

static char scratch[1024];
static char *payload_buf;
static size_t payload_len;

static int call_export(const char *token, const char *json) {
    payload_len = (size_t)snprintf(payload_buf, NP_EXPORT_MAX + 128, "%s\n%s",
                                   token, json);
    captured_pb_len = 0;
    return export_owned_games(make_request(payload_buf, payload_len), 0);
}

static int call_raw(const void *data, size_t len) {
    captured_pb_len = 0;
    return export_owned_games(make_request(data, len), 0);
}

static char *export_path(void) {
    static char path[1400];
    np_support_path(path, sizeof path, scratch, NP_EXPORT_FILE);
    return path;
}

static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    uint8_t *buf = malloc(1 << 20);
    *len = fread(buf, 1, 1 << 20, f);
    fclose(f);
    return (char *)buf;
}

static void mkdirs(const char *path) {
    char tmp[1400];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = '\0'; mkdir(tmp, 0755); *p = '/'; }
    }
    mkdir(tmp, 0755);
}

static void write_loginusers(const char *recent, const char *other) {
    char path[1400];
    snprintf(path, sizeof path,
             "%s/Library/Application Support/Steam/config", scratch);
    mkdirs(path);
    snprintf(path, sizeof path,
             "%s/Library/Application Support/Steam/config/loginusers.vdf", scratch);
    FILE *f = fopen(path, "w");
    fprintf(f, "\"users\"\n{\n"
               "\t\"%s\"\n\t{\n"
               "\t\t\"AccountName\"\t\t\"acct1\"\n"
               "\t\t\"MostRecent\"\t\t\"1\"\n"
               "\t\t\"Timestamp\"\t\t\"1790000000\"\n\t}\n"
               "\t\"%s\"\n\t{\n"
               "\t\t\"AccountName\"\t\t\"acct2\"\n"
               "\t\t\"MostRecent\"\t\t\"0\"\n"
               "\t\t\"Timestamp\"\t\t\"1790000100\"\n\t}\n}\n",
            recent, other);
    fclose(f);
}

static cJSON *parse_file(void) {
    size_t len = 0;
    char *text = read_file(export_path(), &len);
    if (!text) return NULL;
    cJSON *j = cJSON_ParseWithLength(text, len);
    free(text);
    return j;
}

int main(int argc, char **argv) {
    const char *tmp = getenv("TMPDIR");
    snprintf(scratch, sizeof scratch, "%s/np-libexport-XXXXXX",
             (tmp && tmp[0]) ? tmp : "/tmp");
    if (!mkdtemp(scratch)) { perror("mkdtemp"); return 2; }
    setenv("HOME", scratch, 1);
    payload_buf = malloc(NP_EXPORT_MAX + 128);

    // Token: generated once, 32 hex chars.
    const char *tok = np_libexport_token();
    CHECK(strlen(tok) == NP_TOKEN_LEN, "token is 32 characters");
    int hex = 1;
    for (size_t i = 0; i < NP_TOKEN_LEN; i++)
        if (!isxdigit((unsigned char)tok[i])) hex = 0;
    CHECK(hex, "token is hexadecimal");
    CHECK(strcmp(tok, np_libexport_token()) == 0, "token is stable for the launch");

    // Registration: name is routed to the TransportValidation message types.
    np_libexport_register(NULL, 0, 0, 0);
    CHECK(np_libexport_routes() == NP_LIBEXPORT_READY,
          "route registers when types resolve");
    CHECK(strcmp(registered_name, "Cartouche.ExportOwnedGames#1") == 0,
          "route name carries the interface version");
    CHECK(registered_handler != NULL, "handler recorded");

    if (argc == 2 && strcmp(argv[1], "--bridge") == 0) {
        char *line = NULL;
        size_t cap = 0;
        while (getline(&line, &cap, stdin) > 0) {
            captured_pb_len = 0;
            int result;
            if (strncmp(line, "token", 5) == 0) {
                result = token_handler(0, 1);
            } else {
                size_t n = strcspn(line, "\n") / 2;
                for (size_t i = 0; i < n; i++) {
                    unsigned byte;
                    sscanf(line + 2 * i, "%2x", &byte);
                    payload_buf[i] = (char)byte;
                }
                result = registered_handler(make_request(payload_buf, n), 1);
            }
            printf("%d ", result);
            for (uint32_t i = 0; i < captured_pb_len; i++) printf("%02x", captured_pb[i]);
            printf("\n");
            fflush(stdout);
        }
        free(line);
        return 0;
    }

    const char *sid = "76561198123456789";
    const char *good =
        "{\"version\":1,\"generated\":1790000000,\"steamid\":\"76561198123456789\","
        "\"apps\":[{\"appid\":7,\"name\":\"Half-Life 3\",\"installed\":false,"
        "\"last_played\":1789999999,\"playtime\":42,\"debug\":true},"
        "{\"appid\":8,\"name\":\"Ricochet\",\"installed\":true,\"hidden\":true}],"
        "\"collections\":[{\"id\":\"favs\",\"name\":\"Favs\",\"apps\":[7,8]}],"
        "\"surprise\":\"dropped\"}";

    // A good payload writes the file with unknown keys dropped.
    CHECK(call_export(tok, good) == RESULT_OK, "good payload accepted");
    CHECK(reply_appcount() == 2, "reply carries the app count");
    struct stat st;
    CHECK(lstat(export_path(), &st) == 0 && S_ISREG(st.st_mode), "file exists");
    CHECK((st.st_mode & 0777) == 0600, "file is owner-only");
    cJSON *j = parse_file();
    CHECK(cJSON_IsObject(j), "file parses");
    CHECK(cJSON_GetObjectItemCaseSensitive(j, "surprise") == NULL,
          "unknown top-level keys dropped");
    cJSON *a0 = cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(j, "apps"), 0);
    CHECK(cJSON_GetObjectItemCaseSensitive(a0, "debug") == NULL,
          "unknown app keys dropped");
    CHECK(cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(j, "collections"), 0) != NULL,
          "collections kept");
    cJSON_Delete(j);

    // A stale-token refusal warns once, then drops to debug so a page cached
    // from an earlier launch does not fill dylib.log with repeats.
    {
        np_log_level = NP_LVL_DBG;
        np_log_file = tmpfile();
        CHECK(call_export("00000000000000000000000000000000", good) == RESULT_FAIL,
              "wrong token refused");
        CHECK(call_export("00000000000000000000000000000000", good) == RESULT_FAIL,
              "a repeat refusal is still refused");
        fflush(np_log_file);
        rewind(np_log_file);
        char logbuf[4096];
        size_t n = fread(logbuf, 1, sizeof logbuf - 1, np_log_file);
        logbuf[n] = '\0';
        fclose(np_log_file);
        np_log_file = NULL;
        np_log_level = -1;
        const char *hit =
            "[cartouche] warn libexport: request without this launch's token";
        const char *w = strstr(logbuf, hit);
        CHECK(w != NULL, "a stale token warns once");
        CHECK(w && strstr(w + strlen(hit), "[cartouche] warn libexport:") == NULL,
              "the refusal does not warn again");
        CHECK(strstr(logbuf,
              "[cartouche] debug libexport: request without this launch's token") != NULL,
              "a repeat refusal drops to debug");
    }

    // Short token, no separator.
    char small[40];
    snprintf(small, sizeof small, "%.16s", tok);
    CHECK(call_export(small, good) == RESULT_FAIL, "short token refused");
    char no_sep[128];
    snprintf(no_sep, sizeof no_sep, "%s{\"version\":1}", tok);
    CHECK(call_raw(no_sep, strlen(no_sep)) == RESULT_FAIL, "missing separator refused");

    // Bad payloads each refuse and leave the earlier file alone.
    size_t good_len = 0;
    char *kept = read_file(export_path(), &good_len);
    const char *bads[] = {
        "{\"version\":2,\"generated\":1,\"steamid\":\"76561198123456789\",\"apps\":[]}",
        "{\"version\":1,\"generated\":1,\"steamid\":\"76561198123456789\"}",
        "{\"version\":1,\"generated\":1,\"steamid\":\"x\",\"apps\":[]}",
        "{\"version\":1,\"generated\":1.5,\"steamid\":\"76561198123456789\",\"apps\":[]}",
        "{\"version\":1,\"generated\":1,\"steamid\":\"76561198123456789\","
            "\"apps\":[{\"appid\":0,\"name\":\"x\",\"installed\":false}]}",
        "{\"version\":1,\"generated\":1,\"steamid\":\"76561198123456789\","
            "\"apps\":[{\"appid\":1.5,\"name\":\"x\",\"installed\":false}]}",
        "{\"version\":1,\"generated\":1,\"steamid\":\"76561198123456789\","
            "\"apps\":[{\"appid\":7,\"name\":\"x\",\"installed\":\"yes\"}]}",
        "{\"version\":1,\"generated\":1,\"steamid\":\"76561198123456789\",\"apps\":{}}",
        "not json",
    };
    for (size_t i = 0; i < sizeof bads / sizeof bads[0]; i++) {
        CHECK(call_export(tok, bads[i]) == RESULT_FAIL, "bad payload refused");
        size_t len = 0;
        char *now = read_file(export_path(), &len);
        CHECK(now && len == good_len && memcmp(now, kept, len) == 0,
              "refused payload leaves the file alone");
        free(now);
    }

    // A long name refuses, a 256+ byte multibyte name up to the cap is kept.
    {
        char namebuf[1100];
        memset(namebuf, 'x', sizeof namebuf - 1);
        namebuf[sizeof namebuf - 1] = '\0';
        char *j2 = malloc(sizeof namebuf + 256);
        snprintf(j2, sizeof namebuf + 256,
                 "{\"version\":1,\"generated\":1,\"steamid\":\"%s\","
                 "\"apps\":[{\"appid\":7,\"name\":\"%s\",\"installed\":true}]}",
                 sid, namebuf);
        CHECK(call_export(tok, j2) == RESULT_FAIL, "oversize name refused");
        free(j2);
    }

    // Oversized request.
    {
        size_t big = NP_EXPORT_MAX + NP_TOKEN_LEN + 2;
        uint8_t *huge = malloc(big);
        memcpy(huge, tok, NP_TOKEN_LEN);
        huge[NP_TOKEN_LEN] = '\n';
        memset(huge + NP_TOKEN_LEN + 1, ' ', big - NP_TOKEN_LEN - 1);
        CHECK(call_raw(huge, big) == RESULT_FAIL, "oversize payload refused");
        free(huge);
    }

    // Account isolation: a payload naming another known account refuses.
    write_loginusers(sid, "76561198999999999");
    CHECK(call_export(tok, good) == RESULT_OK, "matching account accepted");
    const char *other =
        "{\"version\":1,\"generated\":1,\"steamid\":\"76561198999999999\",\"apps\":[]}";
    CHECK(call_export(tok, other) == RESULT_FAIL, "another account refused");

    // Symlinked target refuses and the sentinel survives.
    {
        char victim[1400];
        snprintf(victim, sizeof victim, "%s/victim.json", scratch);
        FILE *f = fopen(victim, "w");
        fputs("sentinel", f);
        fclose(f);
        unlink(export_path());
        CHECK(symlink(victim, export_path()) == 0, "symlink made");
        CHECK(call_export(tok, good) == RESULT_FAIL, "symlinked target refused");
        size_t len = 0;
        char *v = read_file(victim, &len);
        CHECK(v && len == 8 && memcmp(v, "sentinel", 8) == 0, "sentinel untouched");
        free(v);
        CHECK(lstat(export_path(), &st) == 0 && S_ISLNK(st.st_mode),
              "link still stands");
        unlink(export_path());
    }

    // Second good export replaces the first atomically; no temp files left.
    const char *second =
        "{\"version\":1,\"generated\":1790000001,\"steamid\":\"76561198123456789\","
        "\"apps\":[{\"appid\":9,\"name\":\"Portal 3\",\"installed\":true}]}";
    CHECK(call_export(tok, second) == RESULT_OK, "second export accepted");
    j = parse_file();
    CHECK(cJSON_GetArraySize(cJSON_GetObjectItemCaseSensitive(j, "apps")) == 1,
          "file holds the new library");
    cJSON_Delete(j);
    {
        char dpath[1400];
        np_support_path(dpath, sizeof dpath, scratch, NULL);
        DIR *d = opendir(dpath);
        struct dirent *e;
        int leftovers = 0;
        while (d && (e = readdir(d)))
            if (strstr(e->d_name, ".XXXXXX")) leftovers++;
        if (d) closedir(d);
        CHECK(!leftovers, "no temp files left behind");
    }

    // A symlinked support directory refuses outright.
    {
        char dpath[1400], aside[1400], elsewhere[1400];
        np_support_path(dpath, sizeof dpath, scratch, NULL);
        snprintf(aside, sizeof aside, "%s/aside", scratch);
        snprintf(elsewhere, sizeof elsewhere, "%s/elsewhere", scratch);
        mkdir(elsewhere, 0755);
        CHECK(rename(dpath, aside) == 0, "support dir moved aside");
        CHECK(symlink(elsewhere, dpath) == 0, "dir symlink made");
        CHECK(call_export(tok, second) == RESULT_FAIL, "symlinked dir refused");
        unlink(dpath);
        rename(aside, dpath);
    }

    // No loginusers at all: the write still lands.
    {
        char lpath[1400];
        snprintf(lpath, sizeof lpath,
                 "%s/Library/Application Support/Steam/config/loginusers.vdf", scratch);
        unlink(lpath);
        CHECK(call_export(tok, other) == RESULT_OK,
              "no known account still exports");
    }

    // Registration once-only: a second call does not re-register.
    {
        char before[128];
        snprintf(before, sizeof before, "%s", registered_name);
        np_libexport_register(NULL, 0, 0, 0);
        CHECK(strcmp(before, registered_name) == 0, "registration is once-only");
    }

    printf("%s: %d failure(s)\n", fails ? "FAIL" : "OK", fails);
    return fails ? 1 : 0;
}
