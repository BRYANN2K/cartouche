// Owned-library export route and its per-launch token.
#ifndef CARTOUCHE_FEATS_LIBEXPORT_H
#define CARTOUCHE_FEATS_LIBEXPORT_H

#include <stdint.h>
#include <stddef.h>
#include <mach-o/loader.h>

// Registers on first route lookup rather than at install time.
void np_libexport_register(const struct mach_header_64 *mh, intptr_t slide,
                           uintptr_t text_base, size_t text_size);

// The token the injected page script has to present. Empty until generated.
const char *np_libexport_token(void);

// A rewound anonymous fd holding the launch token, which the loopback host
// serves so the page learns the token at run time rather than at patch time.
// -1 on failure.
int np_libexport_open_token(void);

enum {
    NP_LIBEXPORT_UNTRIED = 0,
    NP_LIBEXPORT_READY,
    NP_LIBEXPORT_ABSENT,
};
int np_libexport_routes(void);

#endif
