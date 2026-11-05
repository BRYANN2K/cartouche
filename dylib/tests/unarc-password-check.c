// The unarc driver answers the archive password into a buffer unarc owns and sizes. The
// copy used to be an unbounded strcpy; a password as long as the buffer or longer must
// now be refused without a byte written past it.
#include "../../helpers/unarc-password.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

int main(void) {
    char buf[8 + 4];
    memset(buf, 'x', sizeof buf);

    check(unarc_answer_password(buf, 8, "secret") == 1, "a short password is answered");
    check(strcmp(buf, "secret") == 0, "and copied with its NUL");

    memset(buf, 'x', sizeof buf);
    check(unarc_answer_password(buf, 8, "1234567") == 1, "seven bytes fit eight");
    check(buf[7] == '\0' && buf[8] == 'x', "the NUL is the last byte of the buffer");

    memset(buf, 'x', sizeof buf);
    check(unarc_answer_password(buf, 8, "12345678") == 0, "eight bytes and a NUL do not fit eight");
    check(unarc_answer_password(buf, 8, "a much longer password") == 0, "a long one is refused");
    int untouched = 1;
    for (size_t i = 0; i < sizeof buf; i++) untouched &= buf[i] == 'x';
    check(untouched, "a refused password writes nothing");

    check(unarc_answer_password(buf, 0, "a") == 0, "no buffer size, no answer");
    check(unarc_answer_password(buf, -1, "a") == 0, "a negative size, no answer");
    check(unarc_answer_password(NULL, 8, "a") == 0, "no buffer, no answer");
    check(unarc_answer_password(buf, 8, NULL) == 0, "no password, no answer");

    if (failures) return 1;
    printf("==> unarccheck: the password answer stays inside unarc's buffer\n");
    return 0;
}
