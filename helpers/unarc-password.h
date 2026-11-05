// The answer to unarc's password request, kept apart from the Win32 driver so it can be
// tested natively. unarc passes its buffer and the buffer's size (int1 of the callback).
#ifndef CARTOUCHE_UNARC_PASSWORD_H
#define CARTOUCHE_UNARC_PASSWORD_H

#include <string.h>

// 1 when the password fits the buffer with its NUL and was copied. A password that does not
// fit is not cut, since a cut password only fails later as a wrong one.
static inline int unarc_answer_password(char *buf, int size, const char *password) {
    if (!buf || !password || size <= 0) return 0;
    size_t len = strlen(password);
    if (len >= (size_t)size) return 0;
    memcpy(buf, password, len + 1);
    return 1;
}

#endif
