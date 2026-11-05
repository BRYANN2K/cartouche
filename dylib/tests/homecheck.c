// Without HOME, np_home_dir falls back to getpwuid and returns the entry's own pw_dir.
// POSIX lets the next lookup overwrite that entry; macOS gives each result its own
// storage. This holds the platform to that, since cppcheck's getpwuidCalled is suppressed
// on the strength of it.
#include "../util/file.h"

#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    struct passwd *me = getpwuid(getuid());
    if (!me || !me->pw_dir) {
        printf("==> homecheck: no password entry for this user, skipped\n");
        return 0;
    }
    char want[1024];
    snprintf(want, sizeof want, "%s", me->pw_dir);

    unsetenv("HOME");
    const char *home = np_home_dir();
    if (!home || strcmp(home, want) != 0) {
        printf("FAIL without HOME the home is %s, not %s\n", home ? home : "(none)", want);
        return 1;
    }
    // Another user's entry through the same call, as anything else in Steam may look up
    struct passwd *other = getpwuid(getuid() == 0 ? (uid_t)-2 : 0);
    if (other && strcmp(other->pw_dir, want) != 0 && strcmp(home, want) != 0) {
        printf("FAIL a later getpwuid turned the home into %s\n", home);
        return 1;
    }
    if (np_home_dir() != home) {
        printf("FAIL the home moved between calls\n");
        return 1;
    }
    setenv("HOME", "/tmp/elsewhere", 1);
    if (strcmp(np_home_dir(), "/tmp/elsewhere") != 0) {
        printf("FAIL HOME is not preferred\n");
        return 1;
    }
    printf("==> homecheck: the fallback home survives other password lookups\n");
    return 0;
}
