// File/Path Helpers.
#ifndef CARTOUCHE_UTIL_FILE_H
#define CARTOUCHE_UTIL_FILE_H

#include <stdint.h>
#include <stddef.h>

// Caller owns the returned buffer. Refuses anything over 16 MB.
uint8_t *np_read_whole_file(const char *path, size_t *out_len);

const char *np_home_dir(void);

void np_support_path(char *buf, size_t bufsz, const char *home, const char *rel);
void np_logs_path(char *buf, size_t bufsz, const char *home, const char *rel);

#endif // CARTOUCHE_UTIL_FILE_H
