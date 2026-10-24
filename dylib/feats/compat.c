// Compatibility tool support
#include "compat.h"
#include "../util/log.h"
#include "../util/file.h"
#include "cartouche_identity.h"
#include "../util/a64.h"
#include "../util/ptr.h"

#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// The client maps Cloud's Windows path roots into the compat prefix only when
// the tool's name contains "proton" so without a match every AutoCloud rule silently
// skips the app.
#define TOOL_DIR_NAME CARTOUCHE_TOOL_PREFIX
#define TOOL_RUN      "/run"

#define COMPAT_MANAGER_ENABLED_OFF  0x7B0
#define COMPAT_MANAGER_USER_OFF     0x300  // CUser *
#define COMPAT_TOOL_STRIDE          0x130
#define COMPAT_TOOL_FLAGS_OFF       0x28  // bit 0: tool needs no downloaded app
#define COMPAT_TOOL_FLAG_NO_APP     0x1
#define COMPAT_TOOL_FROM_OSLIST_OFF 0x70
#define COMPAT_TOOL_TO_OSLIST_OFF   0x78
// Highest CUtlString YldRegisterTool fills in the caller's entry (see free_tool_paths).
#define COMPAT_TOOL_LAST_PATH_OFF   0x118

// A registration entry is built in a buffer this much past the reference stride. A
// probed shift past it would have the client copy, and free_tool_paths free, memory
// beyond the buffer, so such a layout is refused instead.
#define COMPAT_TOOL_HEADROOM        64
#define COMPAT_TOOL_BUFFER          (COMPAT_TOOL_STRIDE + COMPAT_TOOL_HEADROOM)
#define COMPAT_TOOL_SHIFT_MAX       COMPAT_TOOL_HEADROOM
_Static_assert(COMPAT_TOOL_LAST_PATH_OFF + 8 + COMPAT_TOOL_SHIFT_MAX <= COMPAT_TOOL_BUFFER,
               "every shifted field has to fit the registration buffer");

#define COMPAT_MAPPING_PRIORITY_GLOBAL 75
#define COMPAT_MAPPING_PRIORITY_APP    250

static const char TOOL_MANIFEST[] =
    "\"manifest\"\n"
    "{\n"
    "  \"version\" \"2\"\n"
    "  \"commandline\" \"" TOOL_RUN " %verb%\"\n"
    "}\n";

// Steam's compatibilitytools.d scanner registers a tool when this file is present
// in the tool subdirectory. install_path is "." because the manifest lives inside
// the tool directory. to_oslist is macos
static const char TOOL_DECLARATION_FMT[] =
    "\"compatibilitytools\"\n"
    "{\n"
    "  \"compat_tools\"\n"
    "  {\n"
    "    \"%s\"\n"
    "    {\n"
    "      \"install_path\" \".\"\n"
    "      \"display_name\" \"%s\"\n"
    "      \"from_oslist\" \"windows\"\n"
    "      \"to_oslist\" \"macos\"\n"
    "    }\n"
    "  }\n"
    "}\n";

#include "compat_run.h"  // RUN_SCRIPT, generated from compat_run.sh

static int same_content(const char *path, const char *content, size_t len) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char buf[4096];
    size_t at = 0, got;
    int same = 1;
    while (same && (got = fread(buf, 1, sizeof buf, f)) > 0) {
        same = at + got <= len && memcmp(buf, content + at, got) == 0;
        at += got;
    }
    fclose(f);
    return same && at == len;
}

// Steam can read these while they change, so each is replaced whole: written to a temp
// file beside it, given its mode, synced and renamed over. Content already in place is
// left alone. Returns 1 when written, 0 when already current, -1 on failure.
static int write_file(const char *path, const char *content, int executable) {
    mode_t mode = executable ? 0755 : 0644;
    size_t len = strlen(content);
    struct stat st;
    if (lstat(path, &st) == 0 && S_ISREG(st.st_mode) && (size_t)st.st_size == len &&
        (st.st_mode & 0777) == mode && same_content(path, content, len))
        return 0;

    char tmp[800];
    if ((size_t)snprintf(tmp, sizeof tmp, "%s.XXXXXX", path) >= sizeof tmp) return -1;
    int fd = mkstemp(tmp);
    if (fd < 0) return -1;
    int ok = fchmod(fd, mode) == 0;
    for (size_t off = 0; ok && off < len; ) {
        ssize_t n = write(fd, content + off, len - off);
        if (n <= 0) ok = 0;
        else off += (size_t)n;
    }
    if (ok) ok = fsync(fd) == 0;
    if (close(fd) != 0) ok = 0;
    if (!ok || rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 1;
}

// Steam Helper processes load this dylib too and reach the tool list through the
// WebUI file interpose. Only steam_osx writes or removes tool files, so two processes
// never rewrite them at once.
static int g_owns_tool_files = -1;

static int owns_tool_files(void) {
    if (g_owns_tool_files < 0) {
        const char *pn = getprogname();
        g_owns_tool_files = pn && strcmp(pn, "steam_osx") == 0;
    }
    return g_owns_tool_files;
}

static int ensure_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0)
        return S_ISDIR(st.st_mode) ? 0 : -1;
    return mkdir(path, 0755);
}

static int32_t g_tool_shift;
// Set when the probed layout does not fit what this builds, which turns off every
// read and write of tool entries.
static int g_tool_layout_refused;

// LDR Wt,[X0,#imm]. Writes the byte offset and destination register.
static int ldr32_from_x0(uint32_t w, uint32_t *off, uint32_t *rt) {
    if ((w & 0xFFC003E0u) != 0xB9400000u) return 0;
    *rt  = w & 0x1Fu;
    *off = ((w >> 10) & 0xFFFu) * 4u;
    return 1;
}

// LDR Xt,[Xn,#imm] for a named base register.
static int ldr64_from(uint32_t w, uint32_t base, uint32_t *off) {
    if ((w & 0xFFC00000u) != 0xF9400000u) return 0;
    if (((w >> 5) & 0x1Fu) != base) return 0;
    *off = ((w >> 10) & 0xFFFu) * 8u;
    return 1;
}

static int ldr64_from_x0(uint32_t w, uint32_t *off) {
    return ldr64_from(w, 0, off);
}

// LDRB Wt,[Xn,#imm] for a named base register.
static int ldrb_from(uint32_t w, uint32_t base, uint32_t *off) {
    if ((w & 0xFFC00000u) != 0x39400000u) return 0;
    if (((w >> 5) & 0x1Fu) != base) return 0;
    *off = (w >> 10) & 0xFFFu;
    return 1;
}

// MOV Xd,X0, which assembles as ORR Xd,XZR,X0. Writes the destination register.
static int mov_from_x0(uint32_t w, uint32_t *rd) {
    if ((w & 0xFFFFFFE0u) != 0xAA0003E0u) return 0;
    *rd = w & 0x1Fu;
    return 1;
}

// CBZ Wt. Writes the branch target.
static int cbz32(uintptr_t pc, uint32_t w, uint32_t rt, uintptr_t *target) {
    if ((w & 0xFF000000u) != 0x34000000u) return 0;
    if ((w & 0x1Fu) != rt) return 0;
    int32_t imm = (int32_t)((w >> 5) & 0x7FFFFu);
    imm = (imm << 13) >> 13;
    *target = pc + (uintptr_t)(imm * 4);
    return 1;
}

// The oslist gate compares both oslist strings, so its two loads sit at the far
// end of the struct and corroborate a shift derived at the near end. The base
// register is whatever the compiler picked, so a build that stops using the one
// seen here yields nothing and the shift stands on the near-end pair alone.
// Returns the number of offsets written.
static int probe_oslist_offsets(uintptr_t oslist_gate, uint32_t base,
                                uint32_t *from_off, uint32_t *to_off) {
    if (!oslist_gate) return 0;

    uint32_t seen[2];
    int n = 0;
    for (uintptr_t pc = oslist_gate - 0x40; pc <= oslist_gate + 0x20; pc += 4) {
        uint32_t off;
        if (!ldr64_from(*(const uint32_t *)pc, base, &off)) continue;
        if (n > 0 && seen[0] == off) continue;
        if (n > 1 && seen[1] == off) continue;
        if (n == 2) return 0;
        seen[n++] = off;
    }
    if (n != 2) return 0;

    // to_oslist sits above from_oslist in the struct, whichever order the
    // comparison happens to load them in.
    *to_off   = seen[0] > seen[1] ? seen[0] : seen[1];
    *from_off = seen[0] > seen[1] ? seen[1] : seen[0];
    return 2;
}

int np_compat_probe_tool_layout(uintptr_t appid_gate, uintptr_t oslist_gate) {
    if (!appid_gate) return 0;

    uint32_t appid_off, rt;
    if (!ldr32_from_x0(*(const uint32_t *)appid_gate, &appid_off, &rt)) {
        NP_WARN("np_compat_probe_tool_layout: 0x%lx is not the appid load",
                (unsigned long)appid_gate);
        return 0;
    }

    uintptr_t local_path;
    if (!cbz32(appid_gate + 4, *(const uint32_t *)(appid_gate + 4), rt, &local_path)) {
        NP_WARN("np_compat_probe_tool_layout: no appid branch after 0x%lx",
                (unsigned long)appid_gate);
        return 0;
    }

    // The install field is the first thing the local path wants, within a few
    // instructions of the branch landing.
    uint32_t install_off = 0;
    for (uintptr_t pc = local_path; pc < local_path + 0x20; pc += 4) {
        if (ldr64_from_x0(*(const uint32_t *)pc, &install_off)) break;
    }
    if (!install_off) {
        NP_WARN("np_compat_probe_tool_layout: no install load at 0x%lx",
                (unsigned long)local_path);
        return 0;
    }

    int32_t by_appid   = (int32_t)appid_off   - COMPAT_TOOL_APPID_OFF;
    int32_t by_install = (int32_t)install_off - COMPAT_TOOL_INSTALL_OFF;
    if (by_appid != by_install) {
        NP_ERR("np_compat_probe_tool_layout: appid moved %+d but install moved %+d; "
               "the tool layout no longer shifts as one block",
               by_appid, by_install);
        return 0;
    }

    // COMPAT_TOOL_TO_OSLIST_OFF is the highest field written into a registration,
    // so agreement there means the shift holds across every field in use rather
    // than only the two it was read from.
    uint32_t from_off = 0, to_off = 0;
    if (probe_oslist_offsets(oslist_gate, 21, &from_off, &to_off) == 2) {
        int32_t by_from = (int32_t)from_off - COMPAT_TOOL_FROM_OSLIST_OFF;
        int32_t by_to   = (int32_t)to_off   - COMPAT_TOOL_TO_OSLIST_OFF;
        if (by_from != by_appid || by_to != by_appid) {
            NP_ERR("np_compat_probe_tool_layout: near fields moved %+d but oslist "
                   "moved %+d/%+d; the tool layout no longer shifts as one block",
                   by_appid, by_from, by_to);
            return 0;
        }
        NP_DBG("np_compat_probe_tool_layout: oslist offsets 0x%x/0x%x agree on %+d",
               from_off, to_off, by_appid);
    }

    // Fields only move down past the insertion point. A negative shift would put
    // install on top of the fixed fields, a large one past the registration buffer.
    if (by_appid < 0 || by_appid > COMPAT_TOOL_SHIFT_MAX) {
        g_tool_layout_refused = 1;
        NP_ERR("np_compat_probe_tool_layout: tool fields moved %+d, outside the 0..%+d "
               "this can build; tool registration and lookups are off for this client",
               by_appid, COMPAT_TOOL_SHIFT_MAX);
        return 0;
    }

    g_tool_layout_refused = 0;
    g_tool_shift = by_appid;
    if (g_tool_shift)
        NP_LOG("np_compat_probe_tool_layout: tool fields from install onward are "
               "%+d from the baseline (appid 0x%x, install 0x%x)",
               g_tool_shift, appid_off, install_off);
    return 1;
}

// The manager is a much larger object than a tool entry and grows in the middle,
// so a single distance does not describe it the way one does for the tool tail:
// the tool array and its count sit below the growth and do not move, while the
// enabled flag sits above it and does. Reading the flag's own offset back keeps
// the two independent.
static uint32_t g_enabled_off = COMPAT_MANAGER_ENABLED_OFF;

int np_compat_probe_enabled_off(uintptr_t bis_enabled) {
    if (!bis_enabled) return 0;

    // this arrives in X0 and is parked in a callee-saved register before the
    // profiling call clobbers it, so the flag is read through that register.
    uint32_t base = 0;
    int have_base = 0;
    for (uintptr_t pc = bis_enabled; pc < bis_enabled + 0x40; pc += 4) {
        if (mov_from_x0(*(const uint32_t *)pc, &base)) { have_base = 1; break; }
    }
    if (!have_base) {
        NP_WARN("np_compat_probe_enabled_off: this is never parked in a register "
                "at 0x%lx", (unsigned long)bis_enabled);
        return 0;
    }

    // The flag is the first thing the body tests, ahead of any other byte read
    // through that register.
    uint32_t off = 0;
    int found = 0;
    for (uintptr_t pc = bis_enabled; pc < bis_enabled + 0x80; pc += 4) {
        if (ldrb_from(*(const uint32_t *)pc, base, &off)) { found = 1; break; }
    }
    if (!found) {
        NP_WARN("np_compat_probe_enabled_off: no flag load through x%u at 0x%lx",
                base, (unsigned long)bis_enabled);
        return 0;
    }

    // A tiny offset would mean the match landed on some unrelated early byte
    // read rather than on the flag, which sits far into the object.
    if (off < 0x100) {
        NP_ERR("np_compat_probe_enabled_off: 0x%x is too low to be the enabled "
               "flag; refusing to write it", off);
        return 0;
    }

    if (off != g_enabled_off)
        NP_LOG("np_compat_probe_enabled_off: enabled flag at 0x%x, %+d from the "
               "baseline", off, (int32_t)off - COMPAT_MANAGER_ENABLED_OFF);
    g_enabled_off = off;
    return 1;
}

uint32_t np_compat_enabled_off(void) {
    return g_enabled_off;
}

static uint32_t g_windows_only_off;

int np_compat_probe_windows_only_off(uintptr_t get_wildcard_mapping, uintptr_t lookup) {
    if (!get_wildcard_mapping || !lookup) return 0;

    // The offset only exists in the code. Right before calling the lookup,
    // GetWildcardMapping puts manager + offset in x0. An x0 built from SP is a
    // local variable.
    for (uintptr_t pc = get_wildcard_mapping; pc < get_wildcard_mapping + 0x100; pc += 4) {
        uintptr_t target;
        if (!a64_bl(pc, *(const uint32_t *)pc, &target) || target != lookup) continue;

        for (int back = 1; back <= 4 && pc - 4u * back >= get_wildcard_mapping; back++) {
            uint32_t rd, rn, imm;
            if (a64_add_imm(*(const uint32_t *)(pc - 4u * back), &rd, &rn, &imm) &&
                rd == 0 && rn != A64_SP) {
                g_windows_only_off = imm;
                NP_LOG("np_compat_probe_windows_only_off: windows-only table at 0x%x", imm);
                return 1;
            }
        }
        break;
    }
    NP_WARN("np_compat_probe_windows_only_off: no table argument for 0x%lx in 0x%lx",
            (unsigned long)lookup, (unsigned long)get_wildcard_mapping);
    return 0;
}

bool np_compat_is_windows_only_table(const void *compat_mgr, const void *map) {
    return compat_mgr && g_windows_only_off &&
           map == (const uint8_t *)compat_mgr + g_windows_only_off;
}

void *np_compat_user(const void *compat_mgr) {
    if (!compat_mgr) return NULL;
    uint64_t user = *(const uint64_t *)((const uint8_t *)compat_mgr + COMPAT_MANAGER_USER_OFF);
    return np_plausible_ptr(user) ? (void *)(uintptr_t)user : NULL;
}

uint32_t np_compat_tool_off(uint32_t reference_off) {
    if (reference_off < COMPAT_TOOL_INSTALL_OFF) return reference_off;
    return (uint32_t)((int32_t)reference_off + g_tool_shift);
}

bool np_compat_tool_layout_ok(void) {
    return !g_tool_layout_refused;
}

size_t np_compat_tool_stride(void) {
    return (size_t)((int32_t)COMPAT_TOOL_STRIDE + g_tool_shift);
}

// The compatibility tool needs to go in the folder Steam normally (on Linux)
// scans for compatibility tools. So the tool is shoved into
// ~/Library/Application Support/Steam/compatibilitytools.d and
// STEAM_EXTRA_COMPAT_TOOLS_PATHS points there.
void np_compat_export_tools_path(void) {
    const char *home = np_home_dir();
    if (!home) return;
    if (getenv("STEAM_EXTRA_COMPAT_TOOLS_PATHS")) return;

    char tools_dir[512];
    snprintf(tools_dir, sizeof(tools_dir),
             "%s/Library/Application Support/Steam/compatibilitytools.d", home);

    setenv("STEAM_EXTRA_COMPAT_TOOLS_PATHS", tools_dir, 1);
    NP_LOG("np_compat_export_tools_path: set STEAM_EXTRA_COMPAT_TOOLS_PATHS=%s",
           tools_dir);
}

typedef struct {
    char name[64];
    char build[64];
    char flavor[16];
    // Empty for a runner tool, else the graphics backend the run script forces
    char backend[16];
    char display[96];
    char dir[640];
} tool_entry_t;

// Steam keeps pointers into g_tools.
static tool_entry_t *g_tools;
static int g_tool_count;
static int g_tool_cap;
static int g_tool_list_present;

static int is_name_char(char c, const char *extra) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return 1;
    return c && strchr(extra, c);
}

static int is_token(const char *s, const char *extra) {
    if (!*s) return 0;
    for (; *s; s++)
        if (!is_name_char(*s, extra)) return 0;
    return 1;
}

static int is_tool_name(const char *s) {
    return s && strncmp(s, TOOL_DIR_NAME, strlen(TOOL_DIR_NAME)) == 0 && is_token(s, "._-");
}

static int is_display(const char *s) {
    if (!*s) return 0;
    for (; *s; s++)
        if (*s == '"' || *s == '\\' || (unsigned char)*s < 0x20) return 0;
    return 1;
}

static int is_backend(const char *s) {
    static const char *const names[] = { "d3dmetal", "dxmt", "dxvk", "wined3d" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        if (strcmp(s, names[i]) == 0) return 1;
    return 0;
}

// name, build, flavor, display; a backend list line has the backend before display
static int parse_tool_line(char *line, tool_entry_t *out, int with_backend) {
    char *field[5];
    int want = with_backend ? 5 : 4;
    int n = 0;
    char *save = NULL;
    for (char *tok = strtok_r(line, "\t", &save); tok && n < want;
         tok = strtok_r(NULL, "\t", &save))
        field[n++] = tok;
    if (n != want) return 0;
    const char *display = field[want - 1];

    // Build ids may contain an underscore, as in wine-stable-11.0_1.
    if (!is_tool_name(field[0]) || !is_token(field[1], "._-")
        || (strcmp(field[2], "fex") != 0 && strcmp(field[2], "rosetta") != 0)
        || (with_backend && !is_backend(field[3]))
        || !is_display(display))
        return 0;
    if (strlen(field[0]) >= sizeof(out->name) || strlen(field[1]) >= sizeof(out->build)
        || strlen(display) >= sizeof(out->display))
        return 0;

    snprintf(out->name, sizeof(out->name), "%s", field[0]);
    snprintf(out->build, sizeof(out->build), "%s", field[1]);
    snprintf(out->flavor, sizeof(out->flavor), "%s", field[2]);
    snprintf(out->backend, sizeof(out->backend), "%s", with_backend ? field[3] : "");
    snprintf(out->display, sizeof(out->display), "%s", display);
    return 1;
}

// Every read and write of the list happens under this lock, because the WebUI file
// server, the compat hooks and the loader can be running at the same time.
static pthread_mutex_t g_tools_lock = PTHREAD_MUTEX_INITIALIZER;

// A list a newer one replaced is retired, never freed: names and dirs handed out
// before the swap (the fallback name, the FEX names) stay valid for the process's life.
static tool_entry_t **g_retired;
static int g_retired_count;

static void retire_tools(tool_entry_t *old) {
    if (!old) return;
    tool_entry_t **grown = realloc(g_retired,
                                   (size_t)(g_retired_count + 1) * sizeof(*grown));
    if (!grown) return;
    g_retired = grown;
    g_retired[g_retired_count++] = old;
}

static uint32_t manager_tools_max_locked(void) {
    return COMPAT_MANAGER_TOOLS_HEADROOM + (uint32_t)g_tool_count;
}

static int read_tool_list_into(const char *path, const char *tools_dir, int with_backend,
                               tool_entry_t **list, int *count, int *cap) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int added = 0;

    char line[512];
    int lineno = 0;
    while (fgets(line, sizeof(line), f)) {
        lineno++;
        line[strcspn(line, "\r\n")] = '\0';
        if (!line[0]) continue;

        tool_entry_t entry;
        if (!parse_tool_line(line, &entry, with_backend)) {
            NP_WARN("np_compat_load_tool_list: %s line %d is not a tool, skipped",
                    path, lineno);
            continue;
        }

        int taken = 0;
        for (int i = 0; i < *count; i++)
            taken |= strcmp((*list)[i].name, entry.name) == 0;
        if (taken) {
            NP_WARN("np_compat_load_tool_list: %s is listed twice, the later line "
                    "(build %s) is skipped", entry.name, entry.build);
            continue;
        }
        if (*count == *cap) {
            int grown_cap = *cap ? *cap * 2 : 8;
            tool_entry_t *grown = realloc(*list, (size_t)grown_cap * sizeof(*grown));
            if (!grown) {
                NP_WARN("np_compat_load_tool_list: out of memory at %s, the rest is skipped",
                        entry.name);
                break;
            }
            *list = grown;
            *cap = grown_cap;
        }

        snprintf(entry.dir, sizeof(entry.dir), "%s/%s", tools_dir, entry.name);
        (*list)[(*count)++] = entry;
        added++;
    }
    fclose(f);
    return added;
}

// Caller holds g_tools_lock. Rebuilds the list from the runner tool file, with the
// backend pairs behind it. Returns the runner tools kept.
static int load_lists_locked(const char *tools_path, const char *backend_path,
                             const char *tools_dir) {
    FILE *f = fopen(tools_path, "r");
    if (!f) {
        NP_WARN("np_compat_load_tool_list: %s is missing, so no build has a tool "
                "until Cartouche sets one up", tools_path);
        retire_tools(g_tools);
        g_tools = NULL;
        g_tool_count = 0;
        g_tool_cap = 0;
        g_tool_list_present = 0;
        return 0;
    }
    fclose(f);

    tool_entry_t *fresh = NULL;
    int count = 0, cap = 0;
    int kept = read_tool_list_into(tools_path, tools_dir, 0, &fresh, &count, &cap);
    if (backend_path) {
        f = fopen(backend_path, "r");
        if (f) {
            fclose(f);
            read_tool_list_into(backend_path, tools_dir, 1, &fresh, &count, &cap);
        } else {
            NP_LOG("np_compat_load_backend_tool_list: %s is missing, so no tool "
                   "forces a graphics backend", backend_path);
        }
    }

    retire_tools(g_tools);
    g_tools = fresh;
    g_tool_count = count;
    g_tool_cap = cap;
    g_tool_list_present = 1;
    return kept;
}

int np_compat_load_tool_list(const char *path, const char *tools_dir) {
    pthread_mutex_lock(&g_tools_lock);
    int kept = load_lists_locked(path, NULL, tools_dir);
    pthread_mutex_unlock(&g_tools_lock);
    return kept;
}

// Appends the runner and backend pairs after the runner tools, which keep their order
// and so stay the defaults. A missing list is a Cartouche without backend tools yet.
int np_compat_load_backend_tool_list(const char *path, const char *tools_dir) {
    FILE *f = fopen(path, "r");
    if (!f) {
        NP_LOG("np_compat_load_backend_tool_list: %s is missing, so no tool forces a "
               "graphics backend", path);
        return 0;
    }
    fclose(f);

    pthread_mutex_lock(&g_tools_lock);
    int cap = g_tool_count > 8 ? g_tool_count : 8;
    int count = g_tool_count;
    tool_entry_t *fresh = malloc((size_t)cap * sizeof(*fresh));
    int added = 0;
    if (fresh) {
        memcpy(fresh, g_tools, (size_t)count * sizeof(*fresh));
        added = read_tool_list_into(path, tools_dir, 1, &fresh, &count, &cap);
        retire_tools(g_tools);
        g_tools = fresh;
        g_tool_count = count;
        g_tool_cap = cap;
    }
    pthread_mutex_unlock(&g_tools_lock);
    return added;
}

static int tools_dir_path(char *out, size_t size) {
    const char *home = np_home_dir();
    if (!home) return -1;
    snprintf(out, size, "%s/Library/Application Support/Steam/compatibilitytools.d", home);
    return 0;
}

typedef struct {
    int      present;
    uint64_t ino;
    int64_t  sec;
    int64_t  size;
} file_sig_t;

static file_sig_t file_sig(const char *path) {
    struct stat st;
    file_sig_t sig = { 0 };
    if (stat(path, &st) == 0) {
        sig.present = 1;
        sig.ino  = (uint64_t)st.st_ino;
        sig.sec  = (int64_t)st.st_mtime;
        sig.size = (int64_t)st.st_size;
    }
    return sig;
}

static int ensure_tool_manifest_locked(void);

// The app rewrites its lists while Steam runs, e.g. when a runner is set up mid
// session. The files are looked at no more than once a second and rebuilt when
// they changed, so a tool that appears late still registers into the manager.
static int g_lists_loaded;
static file_sig_t g_sig[2];
_Atomic int64_t g_tools_next_check;

static void refresh_tool_list_locked(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return;
    int64_t ms = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;

    if (g_lists_loaded) {
        int64_t due = atomic_load(&g_tools_next_check);
        if (ms < due ||
            !atomic_compare_exchange_strong(&g_tools_next_check, &due, ms + 1000))
            return;
    }

    const char *home = np_home_dir();
    char tools_dir[512];
    if (!home || tools_dir_path(tools_dir, sizeof tools_dir) != 0) return;

    char tools_path[512], backend_path[512];
    snprintf(tools_path, sizeof tools_path,
             "%s/" CARTOUCHE_SUPPORT_DIR "/tools", home);
    snprintf(backend_path, sizeof backend_path,
             "%s/" CARTOUCHE_SUPPORT_DIR "/" CARTOUCHE_BACKEND_TOOL_LIST, home);

    if (!g_lists_loaded) {
        g_lists_loaded = 1;
        atomic_store(&g_tools_next_check, ms + 1000);
        load_lists_locked(tools_path, backend_path, tools_dir);
        g_sig[0] = file_sig(tools_path);
        g_sig[1] = file_sig(backend_path);
        return;
    }

    file_sig_t now_sig[2] = { file_sig(tools_path), file_sig(backend_path) };
    if (memcmp(now_sig, g_sig, sizeof now_sig) == 0) return;
    memcpy(g_sig, now_sig, sizeof g_sig);

    int was = g_tool_count;
    load_lists_locked(tools_path, backend_path, tools_dir);
    if (g_tool_count != was)
        NP_LOG("compat: the tool list changed under Steam, now %d tool(s)",
               g_tool_count);
    ensure_tool_manifest_locked();
}

uint32_t np_compat_manager_tools_max(void) {
    pthread_mutex_lock(&g_tools_lock);
    refresh_tool_list_locked();
    uint32_t max = manager_tools_max_locked();
    pthread_mutex_unlock(&g_tools_lock);
    return max;
}

static void put_tool_file(const char *path, const char *content, int executable,
                          int *wrote) {
    int rc = write_file(path, content, executable);
    if (rc > 0) (*wrote)++;
    else if (rc < 0) NP_WARN("np_compat_ensure_tool_manifest: failed to write %s", path);
}

static int write_tool(const tool_entry_t *tool) {
    if (ensure_dir(tool->dir) != 0) {
        NP_WARN("np_compat_ensure_tool_manifest: cannot create %s", tool->dir);
        return -1;
    }

    char declaration[512];
    snprintf(declaration, sizeof(declaration), TOOL_DECLARATION_FMT,
             tool->name, tool->display);

    char path[768];
    int wrote = 0;

    // Checked every launch so field changes take effect. A rescan replaces it in
    // place rather than adding a second copy.
    snprintf(path, sizeof(path), "%s/compatibilitytool.vdf", tool->dir);
    put_tool_file(path, declaration, 0, &wrote);

    snprintf(path, sizeof(path), "%s/toolmanifest.vdf", tool->dir);
    if (access(path, F_OK) != 0)
        put_tool_file(path, TOOL_MANIFEST, 0, &wrote);

    // The run script is the shim this project owns and updates, so it is checked
    // every launch rather than leaving a stale copy behind.
    snprintf(path, sizeof(path), "%s/run", tool->dir);
    put_tool_file(path, RUN_SCRIPT, 1, &wrote);

    char line[80];
    snprintf(line, sizeof(line), "%s\n", tool->flavor);
    snprintf(path, sizeof(path), "%s/flavor", tool->dir);
    put_tool_file(path, line, 0, &wrote);

    snprintf(line, sizeof(line), "%s\n", tool->build);
    snprintf(path, sizeof(path), "%s/build", tool->dir);
    put_tool_file(path, line, 0, &wrote);

    // The run script forces this backend. A runner tool has none, and loses a stale one.
    snprintf(path, sizeof(path), "%s/backend", tool->dir);
    if (tool->backend[0]) {
        snprintf(line, sizeof(line), "%s\n", tool->backend);
        put_tool_file(path, line, 0, &wrote);
    } else {
        unlink(path);
    }

    if (wrote > 0)
        NP_LOG("np_compat_ensure_tool_manifest: wrote %d file(s) to %s", wrote, tool->dir);

    return 0;
}

#define RUN_SCRIPT_MARK "\n# " CARTOUCHE_STEAM_PREFIX " CrossOver compatibility tool shim\n"

static int written_here(const char *tool_dir) {
    char path[768];
    snprintf(path, sizeof(path), "%s/flavor", tool_dir);
    if (access(path, F_OK) == 0) return 1;

    snprintf(path, sizeof(path), "%s/run", tool_dir);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char head[128];
    size_t got = fread(head, 1, sizeof(head) - 1, f);
    fclose(f);
    head[got] = '\0';
    return strstr(head, RUN_SCRIPT_MARK) != NULL;
}

static void remove_tool(const char *tools_dir, const char *name) {
    char tool_dir[640];
    snprintf(tool_dir, sizeof(tool_dir), "%s/%s", tools_dir, name);
    if (!written_here(tool_dir)) return;

    char path[768];

    static const char *const files[] = {
        "compatibilitytool.vdf", "toolmanifest.vdf", "run", "flavor", "build", "backend",
    };

    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        snprintf(path, sizeof(path), "%s/%s", tool_dir, files[i]);
        unlink(path);
    }

    if (rmdir(tool_dir) == 0)
        NP_LOG("np_compat_ensure_tool_manifest: removed %s", tool_dir);
    else
        NP_WARN("np_compat_ensure_tool_manifest: %s holds files this did not write, "
                "so it stays", tool_dir);
}

static int is_listed(const char *name) {
    for (int i = 0; i < g_tool_count; i++)
        if (strcmp(g_tools[i].name, name) == 0) return 1;
    return 0;
}

static void remove_unlisted_tools(const char *tools_dir) {
    DIR *dir = opendir(tools_dir);
    if (!dir) return;

    struct dirent *e;
    while ((e = readdir(dir)) != NULL) {
        if (strncmp(e->d_name, TOOL_DIR_NAME, strlen(TOOL_DIR_NAME)) != 0) continue;
        if (is_listed(e->d_name)) continue;
        remove_tool(tools_dir, e->d_name);
    }
    closedir(dir);
}

static int ensure_tool_manifest_locked(void) {
    if (!owns_tool_files()) return 0;

    char tools_dir[512];
    if (tools_dir_path(tools_dir, sizeof(tools_dir)) != 0) return -1;

    if (ensure_dir(tools_dir) != 0) {
        NP_WARN("np_compat_ensure_tool_manifest: cannot create %s", tools_dir);
        return -1;
    }

    if (!g_tool_list_present) return 0;

    int failed = 0;
    for (int i = 0; i < g_tool_count; i++)
        failed |= write_tool(&g_tools[i]) != 0;

    remove_unlisted_tools(tools_dir);
    return failed ? -1 : 0;
}

int np_compat_ensure_tool_manifest(void) {
    pthread_mutex_lock(&g_tools_lock);
    refresh_tool_list_locked();
    int rc = ensure_tool_manifest_locked();
    pthread_mutex_unlock(&g_tools_lock);
    return rc;
}

// Written once under g_tools_lock and never again, so the pointer stays stable.
static char g_default_tool_dir[640];

// The first tool's dir lives in its list, which is retired rather than freed when a
// newer list replaces it, so the pointer stays valid after the lock is dropped.
const char *np_compat_tool_dir(void) {
    pthread_mutex_lock(&g_tools_lock);
    refresh_tool_list_locked();
    const char *dir = NULL;
    if (g_tool_count > 0) {
        dir = g_tools[0].dir;
    } else {
        char tools_dir[512];
        if (!g_default_tool_dir[0] && tools_dir_path(tools_dir, sizeof(tools_dir)) == 0)
            snprintf(g_default_tool_dir, sizeof(g_default_tool_dir), "%s/%s",
                     tools_dir, TOOL_DIR_NAME);
        dir = g_default_tool_dir[0] ? g_default_tool_dir : NULL;
    }
    pthread_mutex_unlock(&g_tools_lock);
    return dir;
}

int np_compat_runs_tool(const char *cmd) {
    static const char lead[]    = "/compatibilitytools.d/" TOOL_DIR_NAME;
    static const char run[]     = "'" TOOL_RUN " ";
    static const char run_dot[] = "/.'" TOOL_RUN " ";
    if (!cmd) return 0;

    for (const char *at = strstr(cmd, lead); at; at = strstr(at + 1, lead)) {
        const char *p = at + sizeof(lead) - 1;
        while (is_name_char(*p, "._-"))
            p++;
        if (strncmp(p, run, sizeof(run) - 1) == 0 || strncmp(p, run_dot, sizeof(run_dot) - 1) == 0)
            return 1;
    }
    return 0;
}

int np_compat_is_tool_run_path(const char *path) {
    static const char lead[] = "/compatibilitytools.d/" TOOL_DIR_NAME;
    if (!path || path[0] != '/') return 0;

    const char *at = strstr(path, lead);
    if (!at || strstr(at + 1, lead)) return 0;
    const char *p = at + sizeof(lead) - 1;
    while (is_name_char(*p, "._-"))
        p++;
    if (strncmp(p, "/./", 3) == 0)
        p += 2;
    return strcmp(p, TOOL_RUN) == 0;
}

const char *np_compat_tool_commandline(void) {
    return TOOL_RUN " %verb%";
}

void np_compat_force_enable(void *compat_mgr) {
    if (!compat_mgr) return;

    uint8_t *base = (uint8_t *)compat_mgr;
    uint32_t off = np_compat_enabled_off();
    uint8_t prev = base[off];
    base[off] = 1;

    // Steam polls compat state frequently. Only log the one transition.
    if (!prev)
        NP_LOG("np_compat_force_enable: compat layer force-enabled (this+0x%X: 0 -> 1)",
               off);
}

typedef uint32_t (*fn_GetValidPlatforms)(void *compat_mgr, uint32_t appid);
static fn_GetValidPlatforms g_get_valid_platforms;

void np_compat_set_valid_platforms_fn(uintptr_t get_valid_platforms) {
    g_get_valid_platforms = (fn_GetValidPlatforms)get_valid_platforms;
}

uint32_t np_compat_valid_platforms(void *compat_mgr, uint32_t appid) {
    if (!g_get_valid_platforms || !compat_mgr)
        return 0;
    return g_get_valid_platforms(compat_mgr, appid);
}

typedef void *(*fn_FindToolForTargetApp)(void *compat_mgr, uint32_t appid);
static fn_FindToolForTargetApp g_find_tool_for_app;

void np_compat_set_find_tool_fn(uintptr_t find_tool_for_target_app) {
    g_find_tool_for_app = (fn_FindToolForTargetApp)find_tool_for_target_app;
}

void *np_compat_tool_for_app(void *compat_mgr, uint32_t appid) {
    if (!g_find_tool_for_app || !compat_mgr)
        return NULL;
    return g_find_tool_for_app(compat_mgr, appid);
}

// The config argument is a tool-specific string the dropdown has no way to set, and
// the client passes it empty from its own handler.
static fn_FindToolForTargetApp g_chosen_tool;

void np_compat_set_chosen_tool_fn(uintptr_t find_tool_for_target_app) {
    g_chosen_tool = (fn_FindToolForTargetApp)find_tool_for_target_app;
}

void *np_compat_chosen_tool(void *compat_mgr, uint32_t appid) {
    if (!g_chosen_tool || !compat_mgr)
        return NULL;
    return g_chosen_tool(compat_mgr, appid);
}

bool np_compat_would_force(void *compat_mgr, uint32_t appid) {
    if (!compat_mgr || !appid)
        return false;
    uint32_t platforms = np_compat_valid_platforms(compat_mgr, appid);
    return (platforms & COMPAT_PLATFORM_WINDOWS) && !(platforms & COMPAT_PLATFORM_MACOS);
}

typedef void *(*fn_FindMapping)(void *compat_mgr, uint32_t appid);
static fn_FindMapping g_find_mapping;

void np_compat_set_app_mapping_fn(uintptr_t find_mapping) {
    g_find_mapping = (fn_FindMapping)find_mapping;
}

// { const char *name; const char *config; int32_t priority }, owned by the client.
static const char *mapping_name(const void *mapping) {
    const char *const *entry = (const char *const *)mapping;
    if (!entry || !entry[0] || !entry[0][0])
        return NULL;
    return entry[0];
}

const char *np_compat_app_mapping(void *compat_mgr, uint32_t appid) {
    if (!g_find_mapping || !compat_mgr || !appid)
        return NULL;
    return mapping_name(g_find_mapping(compat_mgr, appid));
}

static fn_FindMapping g_get_wildcard;

void np_compat_set_wildcard_fn(uintptr_t get_wildcard_mapping) {
    g_get_wildcard = (fn_FindMapping)get_wildcard_mapping;
}

const char *np_compat_wildcard_mapping(void *compat_mgr, uint32_t appid) {
    if (!g_get_wildcard || !compat_mgr || !appid)
        return NULL;
    return mapping_name(g_get_wildcard(compat_mgr, appid));
}

typedef void (*fn_SetCompatToolMapping)(void *compat_mgr, uint32_t appid,
                                        const char *tool_name, const char *config,
                                        uint32_t priority);
static fn_SetCompatToolMapping g_set_mapping;

void np_compat_set_mapping_fn(uintptr_t set_compat_tool_mapping) {
    g_set_mapping = (fn_SetCompatToolMapping)set_compat_tool_mapping;
}

void np_compat_map_tool(void *compat_mgr, uint32_t appid, const char *tool_name) {
    if (!g_set_mapping || !compat_mgr || !tool_name) {
        NP_ERR("np_compat_map_tool: app %u cannot be mapped to %s", appid,
               tool_name ? tool_name : "no tool");
        return;
    }
    g_set_mapping(compat_mgr, appid, tool_name, "",
                  appid ? COMPAT_MAPPING_PRIORITY_APP
                        : COMPAT_MAPPING_PRIORITY_GLOBAL);
}

// Cartouche asks for a game's tool by leaving "appid<TAB>tool" lines in its data folder,
// an empty tool clearing the choice. The file is renamed before it is read, so a request
// the app writes meanwhile waits for the next pass instead of being lost.
#define REQUESTS_MAX_BYTES (64 * 1024)

static int apply_taken_requests(void *compat_mgr, const char *path, const char *taken);

int np_compat_apply_requests_from(void *compat_mgr, const char *path) {
    // Without the client's mapping function the requests wait for a build that has it
    if (!compat_mgr || !path || !g_set_mapping) return 0;
    char taken[600];
    snprintf(taken, sizeof(taken), "%s.applying", path);
    int applied = 0;
    // A crash between rename and unlink leaves a taken file holding requests that
    // were never applied. They go first, both because they are older and because the
    // rename below would otherwise replace them unread.
    if (access(taken, F_OK) == 0)
        applied += apply_taken_requests(compat_mgr, path, taken);
    if (rename(path, taken) == 0)
        applied += apply_taken_requests(compat_mgr, path, taken);
    return applied;
}

static int apply_taken_requests(void *compat_mgr, const char *path, const char *taken) {
    FILE *f = fopen(taken, "r");
    if (!f) {
        unlink(taken);
        return 0;
    }
    int applied = 0;
    size_t read_bytes = 0;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        read_bytes += strlen(line);
        if (read_bytes > REQUESTS_MAX_BYTES) {
            NP_WARN("np_compat_apply_requests: %s is over %d bytes, the rest is skipped",
                    path, REQUESTS_MAX_BYTES);
            break;
        }
        line[strcspn(line, "\r\n")] = '\0';
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = '\0';
        const char *tool = tab + 1;
        char *end = NULL;
        unsigned long appid = strtoul(line, &end, 10);
        if (!line[0] || *end || appid > UINT32_MAX || strlen(line) > 10) {
            NP_WARN("np_compat_apply_requests: \"%s\" is not an app, skipped", line);
            continue;
        }
        // App 0 is Steam's tool for every other Windows game, which is never cleared here
        if (appid == 0 && !*tool) continue;
        // Only Cartouche's own tools, or nothing to clear the choice
        if (*tool && !is_tool_name(tool)) {
            NP_WARN("np_compat_apply_requests: app %lu asks for %s, which is not a Cartouche "
                    "tool, skipped", appid, tool);
            continue;
        }
        np_compat_map_tool(compat_mgr, (uint32_t)appid, tool);
        NP_LOG("np_compat_apply_requests: app %lu now maps to %s", appid,
               *tool ? tool : "its default");
        applied++;
    }
    fclose(f);
    unlink(taken);
    return applied;
}

// Called on every compat query, so the file is looked at no more than once a second
int np_compat_apply_requests(void *compat_mgr) {
    static _Atomic int64_t next_check;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    int64_t ms = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    int64_t due = atomic_load(&next_check);
    if (ms < due || !atomic_compare_exchange_strong(&next_check, &due, ms + 1000)) return 0;

    const char *home = np_home_dir();
    if (!home) return 0;
    char path[512];
    snprintf(path, sizeof(path), "%s/" CARTOUCHE_SUPPORT_DIR "/" CARTOUCHE_COMPAT_REQUESTS, home);
    return np_compat_apply_requests_from(compat_mgr, path);
}

typedef void (*fn_YldRegisterTool)(void *compat_mgr, void *tool);
static fn_YldRegisterTool g_yld_register_tool;
typedef void (*fn_PlatFree)(void *ptr);
static fn_PlatFree g_free_tool_path;

void np_compat_set_register_fn(uintptr_t yld_register_tool) {
    g_yld_register_tool = (fn_YldRegisterTool)yld_register_tool;
    g_free_tool_path = (fn_PlatFree)dlsym(RTLD_DEFAULT, "Plat_Free");
    if (!g_free_tool_path)
        NP_WARN("np_compat_set_register_fn: Plat_Free unresolved, temporary tool paths will leak");
}

static void free_tool_paths(uint8_t *tool) {
    // YldRegisterTool fills these CUtlStrings in the caller's entry.
    // These need Plat_Free, not free.
    static const uint32_t offsets[] = {0x98, 0xA0, 0xA8, 0xD0, 0xD8, 0xE0, 0xE8,
                                       COMPAT_TOOL_LAST_PATH_OFF};
    if (!g_free_tool_path) return;
    for (size_t i = 0; i < sizeof(offsets) / sizeof(*offsets); i++) {
        void **path = (void **)(tool + np_compat_tool_off(offsets[i]));
        if (*path) g_free_tool_path(*path);
        *path = NULL;
    }
}

static void *g_manager;

void *np_compat_manager(void) {
    return g_manager;
}

int np_compat_app_runs_tool(uint32_t appid) {
    const uint8_t *tool = np_compat_tool_for_app(g_manager, appid);

    return tool && is_tool_name(*(const char *const *)(tool + COMPAT_TOOL_NAME_OFF));
}

// Caller holds g_tools_lock.
static void *find_tool(void *compat_mgr, const char *wanted) {
    if (g_tool_layout_refused) return NULL;
    uint8_t *base = (uint8_t *)compat_mgr;
    uint8_t *array = *(uint8_t **)(base + COMPAT_MANAGER_TOOL_ARRAY_OFF);
    uint32_t count = *(uint32_t *)(base + COMPAT_MANAGER_TOOL_COUNT_OFF);
    if ((count && !array) || count > manager_tools_max_locked()) {
        // Once, because Steam walks this for every windows-only app as the library
        // redraws and a count this wrong does not correct itself.
        static const char once = 0;
        if (np_log_first_hit(&once, 0))
            NP_ERR("np_compat_registered_tool: the manager reports %u tool(s) at %p, "
                   "which is not a list this reads", count, (const void *)array);
        return NULL;
    }
    if (!array)
        return NULL;

    for (uint32_t i = 0; i < count; i++) {
        uint8_t *entry = array + (size_t)i * np_compat_tool_stride();
        const char *name = *(const char **)(entry + COMPAT_TOOL_NAME_OFF);
        if (name && strcmp(name, wanted) == 0)
            return entry;
    }
    return NULL;
}

int np_compat_register_crossover(void *compat_mgr) {
    // Every compat query arrives on the instance the properties page reads, which is
    // the one the tool list has to be enumerated from.
    if (compat_mgr)
        g_manager = compat_mgr;

    if (!compat_mgr || !g_yld_register_tool || g_tool_layout_refused)
        return 0;

    pthread_mutex_lock(&g_tools_lock);
    refresh_tool_list_locked();

    int missing = 0;
    for (int i = 0; i < g_tool_count; i++)
        if (!find_tool(compat_mgr, g_tools[i].name)) missing++;
    if (!missing) {
        pthread_mutex_unlock(&g_tools_lock);
        return 0;
    }

    // YldRegisterTool copies the entry and its strings. Each buffer carries headroom
    // for a client that inserted a field. to_oslist=macos passes
    // the registration gate, from_oslist=windows intersects the app mask so the
    // dropdown keeps it, and appid 0 marks a manager-local tool the resolver routes
    // to the local run script.
    uint8_t (*buffers)[COMPAT_TOOL_BUFFER] = calloc((size_t)missing, sizeof(*buffers));
    if (!buffers) {
        NP_WARN("np_compat_register_crossover: out of memory, no tool registered");
        pthread_mutex_unlock(&g_tools_lock);
        return 0;
    }
    static const char from_oslist[] = "windows";
    static const char to_oslist[]   = "macos";

    int added = 0;
    for (int i = 0; i < g_tool_count && added < missing; i++) {
        const tool_entry_t *t = &g_tools[i];

        if (find_tool(compat_mgr, t->name)) {
            NP_LOG("np_compat_register_crossover: %s already registered from disk, "
                   "skipping the runtime entry", t->name);
            continue;
        }

        uint8_t *tool = buffers[added];
        memset(tool, 0, sizeof(buffers[added]));
        *(uint32_t *)(tool + COMPAT_TOOL_FLAGS_OFF)      = COMPAT_TOOL_FLAG_NO_APP;
        *(const char **)(tool + COMPAT_TOOL_NAME_OFF)    = t->name;
        *(const char **)(tool + COMPAT_TOOL_DISPLAY_OFF) = t->display;
        *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_INSTALL_OFF)) = t->dir;
        *(uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_APPID_OFF)) = 0;
        *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_FROM_OSLIST_OFF)) = from_oslist;
        *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_TO_OSLIST_OFF))   = to_oslist;

        g_yld_register_tool(compat_mgr, tool);
        free_tool_paths(tool);
        added++;
        NP_LOG("np_compat_register_crossover: registered %s (build %s) into manager 0x%llx",
               t->name, t->build, (unsigned long long)(uintptr_t)compat_mgr);
    }

    free(buffers);
    pthread_mutex_unlock(&g_tools_lock);
    return added;
}

const char *np_compat_fallback_tool_name(void) {
    pthread_mutex_lock(&g_tools_lock);
    refresh_tool_list_locked();
    const char *name = g_tool_count > 0 ? g_tools[0].name : TOOL_DIR_NAME;
    pthread_mutex_unlock(&g_tools_lock);
    return name;
}

size_t np_compat_fex_tools(const char **names, size_t max) {
    pthread_mutex_lock(&g_tools_lock);
    refresh_tool_list_locked();
    size_t n = 0;
    for (int i = 0; i < g_tool_count; i++) {
        if (strcmp(g_tools[i].flavor, "fex") != 0) continue;
        if (n == max) {
            static atomic_flag warned = ATOMIC_FLAG_INIT;
            if (!atomic_flag_test_and_set(&warned))
                NP_WARN("np_compat_fex_tools: more than %zu FEX tools, %s and later "
                        "are left out", max, g_tools[i].name);
            break;
        }
        names[n++] = g_tools[i].name;
    }
    pthread_mutex_unlock(&g_tools_lock);
    return n;
}

void *np_compat_registered_tool(void *compat_mgr) {
    if (!compat_mgr)
        return NULL;

    pthread_mutex_lock(&g_tools_lock);
    refresh_tool_list_locked();
    void *entry = NULL;
    if (g_tool_count == 0) {
        entry = find_tool(compat_mgr, TOOL_DIR_NAME);
    } else {
        for (int i = 0; i < g_tool_count && !entry; i++)
            entry = find_tool(compat_mgr, g_tools[i].name);
    }
    pthread_mutex_unlock(&g_tools_lock);
    return entry;
}
