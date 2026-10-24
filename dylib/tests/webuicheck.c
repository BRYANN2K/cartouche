// Route registration borrows a job class and access flags from routes the client serves.
// Including the unit points it at a synthesised route table, job vtable and instruction
// words, which are decoded but never run. No Steam.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/loader.h>

#include "../feats/webui.c"

int   np_log_level = -1;
FILE *np_log_file  = NULL;

int np_log_first_hit(const void *anchor, unsigned long tag) {
    (void)anchor; (void)tag;
    return 1;
}

int np_find_segment(const struct mach_header_64 *mh, intptr_t slide,
                    const char *segname, uintptr_t *out_base, size_t *out_size) {
    (void)mh; (void)slide; (void)segname; (void)out_base; (void)out_size;
    return -1;
}

int np_get_section_containing(const struct mach_header_64 *mh, intptr_t slide,
                              uintptr_t addr, uintptr_t *out_base, size_t *out_size) {
    (void)mh; (void)slide; (void)addr; (void)out_base; (void)out_size;
    return -1;
}

static int failures;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

#define RET 0xD65F03C0u
#define NOP 0xD503201Fu

// Fake __text. Word indexes of the functions laid out in it.
#define TEXT_WORDS   256
#define SEND_IDX     0
#define HANDLER_IDX  16
#define PLAIN_IDX    32
#define CTOR_IDX     48
#define FACTORY_IDX  64
#define NEW_IDX      80
static _Alignas(4096) uint32_t text[TEXT_WORDS];

// Fake __DATA_CONST holding the job vtable two words in, past offset-to-top and RTTI.
#define CONST_WORDS  64
#define VT_AT        2
#define HANDLER_SLOT 3
#define TEXT_RUN     10
static _Alignas(16) uintptr_t konst[CONST_WORDS];

static uintptr_t at(int idx) { return (uintptr_t)&text[idx]; }

static uint32_t bl(int from, uintptr_t to) {
    return 0x94000000u | (uint32_t)(((intptr_t)to - (intptr_t)at(from)) / 4 & 0x3FFFFFF);
}

static uint32_t adrp_x8(int from, uintptr_t to) {
    intptr_t pages = ((intptr_t)(to & ~(uintptr_t)0xFFF) -
                      (intptr_t)(at(from) & ~(uintptr_t)0xFFF)) >> 12;
    uint32_t imm = (uint32_t)pages & 0x1FFFFF;
    return 0x90000000u | ((imm & 3) << 29) | ((imm >> 2) << 5) | 8;
}

static uint32_t add_x8(uintptr_t to) {
    return 0x91000000u | ((uint32_t)(to & 0xFFF) << 10) | (8 << 5) | 8;
}

static void build_text(void) {
    for (int i = 0; i < TEXT_WORDS; i++) text[i] = NOP;
    text[SEND_IDX] = RET;
    text[HANDLER_IDX]     = bl(HANDLER_IDX, at(SEND_IDX));
    text[HANDLER_IDX + 1] = RET;
    text[PLAIN_IDX] = RET;
    uintptr_t vt = (uintptr_t)&konst[VT_AT];
    text[CTOR_IDX]     = adrp_x8(CTOR_IDX, vt);
    text[CTOR_IDX + 1] = add_x8(vt);
    text[CTOR_IDX + 2] = RET;
    text[FACTORY_IDX]     = bl(FACTORY_IDX, at(CTOR_IDX));
    text[FACTORY_IDX + 1] = RET;
    text[NEW_IDX] = RET;
}

// Slot 10 points outside __text (a stub, say), and more virtuals follow it.
static void build_vtable(void) {
    memset(konst, 0, sizeof konst);
    konst[0] = 0;
    konst[1] = 0x1234567800ULL;
    for (int s = 0; s < VT_SLOTS; s++)
        konst[VT_AT + s] = at(PLAIN_IDX);
    konst[VT_AT + HANDLER_SLOT] = at(HANDLER_IDX);
    konst[VT_AT + TEXT_RUN] = (uintptr_t)&failures;
}

// The registry: a map whose elements are 48-byte {name, descriptor, flags} records.
#define ROUTES 8
static _Alignas(16) uint8_t registry[256];
static _Alignas(16) uint8_t elements[ROUTES * ROUTE_STRIDE];
static uintptr_t descriptor[DESC_QWORDS];

static void put_route(int i, const char *name, uintptr_t flags) {
    uint8_t *e = elements + (size_t)i * ROUTE_STRIDE;
    *(const char **)e = name;
    *(uintptr_t *)(e + ELEM_DESCRIPTOR_OFF) = (uintptr_t)descriptor;
    *(uintptr_t *)(e + ELEM_FLAGS_OFF) = flags;
}

static uintptr_t registered_flags;
static int register_calls;

static int stub_register(uintptr_t reg, void *record) {
    (void)reg;
    registered_flags = ((uintptr_t *)record)[1];
    register_calls++;
    return 1;
}

static _Alignas(16) uintptr_t msg_vt[8];

static void reset(void) {
    build_text();
    build_vtable();
    memset(registry, 0, sizeof registry);
    memset(elements, 0, sizeof elements);
    memset(descriptor, 0, sizeof descriptor);
    descriptor[DESC_FACTORY] = at(FACTORY_IDX);
    *(uintptr_t *)(registry + REGISTRY_MAP_OFF + MAP_ELEMENTS_OFF) = (uintptr_t)elements;
    *(int32_t *)(registry + REGISTRY_MAP_OFF + MAP_BOUND_OFF) = ROUTES;
    msg_vt[MSG_NEW_OFF / 8] = at(NEW_IDX);

    g_registry      = (uintptr_t)registry;
    g_register_fn   = (uintptr_t)stub_register;
    g_send_response = at(SEND_IDX);
    g_text_base     = (uintptr_t)text;
    g_text_end      = (uintptr_t)(text + TEXT_WORDS);
    g_const_base    = (uintptr_t)konst;
    g_const_end     = (uintptr_t)(konst + CONST_WORDS);
    g_route_count   = 0;
    g_clone_vptr    = 0;
    g_stock_factory = 0;
    g_route_flags   = 0;
    g_route_flags_ready = 0;
    memset(g_clone, 0, sizeof g_clone);
    registered_flags = 0;
    register_calls = 0;
}

static int handler(uintptr_t request, uintptr_t response) {
    (void)request; (void)response;
    return 1;
}

static int add(const char *name) {
    return np_webui_register_route(name, (uintptr_t)msg_vt, (uintptr_t)msg_vt, handler);
}

static void flag_cases(void) {
    reset();
    put_route(0, "Unrelated.FirstServed#1", 0x11);
    put_route(1, UNAUTH_ROUTE, 0x0);
    put_route(2, "TransportValidation.CountOrderedBytes#1", 0x5);
    check(add("Cartouche.Test#1") == 1, "a route registers next to a validation route");
    check(registered_flags == 0x5, "the flags come from the named validation route, not the first one served");

    reset();
    put_route(0, "TransportValidation.AddNumbers#1", 0x7);
    put_route(1, "TransportValidation.GetLargeResponse#1", 0x9);
    check(add("Cartouche.Test#1") == 1 && registered_flags == 0x9,
          "the first name in the preference list wins wherever it sits");

    reset();
    put_route(0, UNAUTH_ROUTE, 0x0);
    put_route(1, "SteamEngine.GetGameIDForPID#1", 0x11);
    put_route(2, "TransportValidationClient.AddNumbers#1", 0x5);
    check(add("Cartouche.Test#1") == 1 && registered_flags == 0x5,
          "the macOS client's TransportValidationClient route is a named route");

    // The live macOS client gives both the same word: registering still goes ahead
    reset();
    put_route(0, UNAUTH_ROUTE, 0x3);
    put_route(1, "TransportValidationClient.AddNumbers#1", 0x3);
    check(add("Cartouche.Test#1") == 1 && registered_flags == 0x3,
          "a flag word equal to the pre-auth route's still registers");

    reset();
    put_route(0, "Unrelated.FirstServed#1", 0x11);
    put_route(1, UNAUTH_ROUTE, 0x0);
    check(add("Cartouche.Test#1") == 1 && registered_flags == 0x11,
          "without a named route the first served route's flags are used, as before");
}

static void clone_cases(void) {
    reset();
    put_route(0, "TransportValidation.CountOrderedBytes#1", 0x5);
    check(add("Cartouche.Test#1") == 1, "the job class is borrowed");
    check(g_clone_vptr == (uintptr_t)&g_clone[2], "the clone stands in for the vtable");
    check(g_clone[2 + HANDLER_SLOT] == (uintptr_t)job_handler,
          "only the handler slot is overridden");
    int same = g_clone[0] == konst[0] && g_clone[1] == konst[1];
    for (int s = 0; s < VT_SLOTS; s++)
        if (s != HANDLER_SLOT) same &= g_clone[2 + s] == konst[VT_AT + s];
    check(same, "every other slot is copied, including the ones past a non-__text pointer");
    check(g_clone[2 + TEXT_RUN + 1] == at(PLAIN_IDX),
          "a virtual after a stub pointer is not left zero");
}

static void capacity_cases(void) {
    reset();
    put_route(0, "TransportValidation.CountOrderedBytes#1", 0x5);
    static char names[MAX_ROUTES + 1][32];
    int ok = 1;
    for (int i = 0; i < MAX_ROUTES; i++) {
        snprintf(names[i], sizeof names[i], "Cartouche.Route%d#1", i);
        ok &= add(names[i]) == 1;
    }
    check(ok && MAX_ROUTES >= 8, "every route up to the cap registers, with room past four");
    snprintf(names[MAX_ROUTES], sizeof names[0], "Cartouche.Overflow#1");
    check(add(names[MAX_ROUTES]) == 0, "a route past the cap is refused");
}

int main(void) {
    flag_cases();
    clone_cases();
    capacity_cases();

    if (failures) {
        printf("==> webui: %d check(s) failed\n", failures);
        return 1;
    }
    printf("==> webui: custom routes take a served route's flags and a full vtable clone\n");
    return 0;
}
