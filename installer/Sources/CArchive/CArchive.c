// The shim's bodies: dlopen the dylib, keep the resolved entry points in
// CALib, and forward. Types are declared to match libarchive's stable C ABI
// (int64_t, ssize_t, mode_t).

#include "CArchive.h"

#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

struct archive;
struct archive_entry;

typedef int (*fn_int_a)(struct archive *);
typedef const char *(*fn_str_a)(struct archive *);
typedef ssize_t (*fn_data)(struct archive *, void *, size_t);
typedef int (*fn_write_data)(struct archive *, const void *, size_t);

struct CALib {
    void *handle;

    struct archive *(*read_new)(void);
    int (*read_support_filter_all)(struct archive *);
    int (*read_support_format_all)(struct archive *);
    int (*read_open_filenames)(struct archive *, const char **, size_t);
    int (*read_next_header)(struct archive *, struct archive_entry **);
    int (*read_data_skip)(struct archive *);
    fn_data read_data;
    int (*read_close)(struct archive *);
    int (*read_free)(struct archive *);
    fn_str_a error_string;
    fn_int_a err_no;
    fn_int_a format_code;
    fn_str_a format_name;
    fn_int_a filter_count;
    const char *(*filter_name)(struct archive *, int);
    fn_int_a has_encrypted;

    const char *(*entry_pathname)(struct archive_entry *);
    const char *(*entry_pathname_utf8)(struct archive_entry *);
    int64_t (*entry_size)(struct archive_entry *);
    mode_t (*entry_filetype)(struct archive_entry *);
    int (*entry_is_encrypted)(struct archive_entry *);
    const char *(*entry_symlink)(struct archive_entry *);
    const char *(*entry_hardlink)(struct archive_entry *);
    void (*entry_set_pathname)(struct archive_entry *, const char *);

    struct archive *(*write_disk_new)(void);
    int (*write_disk_set_options)(struct archive *, int);
    int (*write_header)(struct archive *, struct archive_entry *);
    fn_write_data write_data;
    int (*write_finish_entry)(struct archive *);
    int (*write_close)(struct archive *);
    int (*write_free)(struct archive *);

    const char *(*version_string)(void);
};

static void *sym(CALib *lib, const char *name) {
    return dlsym(lib->handle, name);
}

CALib *ca_open(const char *path) {
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) return NULL;
    CALib *lib = calloc(1, sizeof(CALib));
    lib->handle = handle;

    lib->read_new = sym(lib, "archive_read_new");
    lib->read_support_filter_all = sym(lib, "archive_read_support_filter_all");
    lib->read_support_format_all = sym(lib, "archive_read_support_format_all");
    lib->read_open_filenames = sym(lib, "archive_read_open_filenames");
    lib->read_next_header = sym(lib, "archive_read_next_header");
    lib->read_data = (fn_data)sym(lib, "archive_read_data");
    lib->read_data_skip = sym(lib, "archive_read_data_skip");
    lib->read_close = sym(lib, "archive_read_close");
    lib->read_free = sym(lib, "archive_read_free");
    lib->error_string = sym(lib, "archive_error_string");
    lib->err_no = sym(lib, "archive_errno");
    lib->format_code = sym(lib, "archive_format");
    lib->format_name = sym(lib, "archive_format_name");
    lib->filter_count = sym(lib, "archive_filter_count");
    lib->filter_name = sym(lib, "archive_filter_name");
    lib->has_encrypted = sym(lib, "archive_read_has_encrypted_entries");

    lib->entry_pathname = sym(lib, "archive_entry_pathname");
    lib->entry_pathname_utf8 = sym(lib, "archive_entry_pathname_utf8");
    lib->entry_size = sym(lib, "archive_entry_size");
    lib->entry_filetype = sym(lib, "archive_entry_filetype");
    lib->entry_is_encrypted = sym(lib, "archive_entry_is_encrypted");
    lib->entry_symlink = sym(lib, "archive_entry_symlink");
    lib->entry_hardlink = sym(lib, "archive_entry_hardlink");
    lib->entry_set_pathname = sym(lib, "archive_entry_set_pathname");

    lib->write_disk_new = sym(lib, "archive_write_disk_new");
    lib->write_disk_set_options = sym(lib, "archive_write_disk_set_options");
    lib->write_header = sym(lib, "archive_write_header");
    lib->write_data = (fn_write_data)sym(lib, "archive_write_data");
    lib->write_finish_entry = sym(lib, "archive_write_finish_entry");
    lib->write_close = sym(lib, "archive_write_close");
    lib->write_free = sym(lib, "archive_write_free");

    lib->version_string = sym(lib, "archive_version_string");

    if (!lib->read_new || !lib->read_support_filter_all || !lib->read_support_format_all ||
        !lib->read_open_filenames || !lib->read_next_header || !lib->read_data ||
        !lib->read_free || !lib->error_string || !lib->format_code ||
        !lib->entry_pathname || !lib->entry_size || !lib->entry_filetype ||
        !lib->entry_set_pathname || !lib->write_disk_new || !lib->write_disk_set_options ||
        !lib->write_header || !lib->write_data || !lib->write_finish_entry ||
        !lib->write_free || !lib->version_string) {
        ca_close(lib);
        return NULL;
    }
    return lib;
}

void ca_close(CALib *lib) {
    if (!lib) return;
    if (lib->handle) dlclose(lib->handle);
    free(lib);
}

const char *ca_version(CALib *lib) { return lib->version_string(); }

struct CARead {
    CALib *lib;
    struct archive *a;
    struct archive_entry *entry;
    int open_error;
};

CARead *ca_read_open(CALib *lib, const char *const *paths, int count) {
    if (!lib || !paths || count < 1) return NULL;
    CARead *r = calloc(1, sizeof(CARead));
    r->lib = lib;
    r->a = lib->read_new();
    if (!r->a) { free(r); return NULL; }
    lib->read_support_filter_all(r->a);
    lib->read_support_format_all(r->a);
    /* libarchive expects a NULL-terminated list; it opens volumes as the
       reader crosses them, which is what multi-volume RAR needs. */
    const char **list = calloc((size_t)count + 1, sizeof(char *));
    for (int i = 0; i < count; i++) list[i] = paths[i];
    /* The archive object stays so its error string remains readable. */
    r->open_error = lib->read_open_filenames(r->a, list, 64 * 1024);
    free(list);
    return r;
}

int ca_read_next(CARead *r) {
    if (r->open_error < 0) return r->open_error;
    int rc = r->lib->read_next_header(r->a, &r->entry);
    if (rc == CA_EOF) return CA_EOF;
    return rc < 0 ? rc : CA_OK;
}

long long ca_read_data(CARead *r, void *buf, unsigned long long size) {
    return (long long)r->lib->read_data(r->a, buf, (size_t)size);
}

int ca_read_skip(CARead *r) { return r->lib->read_data_skip(r->a); }

int ca_read_close(CARead *r) {
    if (!r) return CA_OK;
    int rc = r->lib->read_free(r->a);
    free(r);
    return rc;
}

const char *ca_read_error(CARead *r) { return r->lib->error_string(r->a); }
int ca_read_errno(CARead *r) { return r->lib->err_no ? r->lib->err_no(r->a) : 0; }
int ca_read_format(CARead *r) { return r->lib->format_code(r->a); }
const char *ca_read_format_name(CARead *r) { return r->lib->format_name ? r->lib->format_name(r->a) : NULL; }
int ca_read_filter_count(CARead *r) { return r->lib->filter_count ? r->lib->filter_count(r->a) : 0; }
const char *ca_read_filter_name(CARead *r, int index) {
    return r->lib->filter_name ? r->lib->filter_name(r->a, index) : NULL;
}
int ca_read_has_encrypted(CARead *r) {
    return r->lib->has_encrypted ? r->lib->has_encrypted(r->a) : 0;
}

const char *ca_entry_path(CARead *r) {
    if (!r->entry) return NULL;
    const char *p = r->lib->entry_pathname_utf8 ? r->lib->entry_pathname_utf8(r->entry) : NULL;
    return p ? p : r->lib->entry_pathname(r->entry);
}
long long ca_entry_size(CARead *r) { return r->entry ? (long long)r->lib->entry_size(r->entry) : 0; }
int ca_entry_type(CARead *r) { return r->entry ? (int)r->lib->entry_filetype(r->entry) : 0; }
int ca_entry_encrypted(CARead *r) {
    return (r->entry && r->lib->entry_is_encrypted) ? r->lib->entry_is_encrypted(r->entry) : 0;
}
const char *ca_entry_symlink(CARead *r) { return r->entry && r->lib->entry_symlink ? r->lib->entry_symlink(r->entry) : NULL; }
const char *ca_entry_hardlink(CARead *r) { return r->entry && r->lib->entry_hardlink ? r->lib->entry_hardlink(r->entry) : NULL; }
void ca_entry_set_path(CARead *r, const char *path) {
    if (r->entry) r->lib->entry_set_pathname(r->entry, path);
}

struct CAWrite {
    CALib *lib;
    struct archive *a;
};

CAWrite *ca_write_disk(CALib *lib, int flags) {
    CAWrite *w = calloc(1, sizeof(CAWrite));
    w->lib = lib;
    w->a = lib->write_disk_new();
    if (!w->a) { free(w); return NULL; }
    lib->write_disk_set_options(w->a, flags);
    return w;
}

int ca_write_header(CAWrite *w, CARead *r) { return w->lib->write_header(w->a, r->entry); }
long long ca_write_data(CAWrite *w, const void *buf, unsigned long long size) {
    return (long long)w->lib->write_data(w->a, buf, (size_t)size);
}
int ca_write_finish_entry(CAWrite *w) { return w->lib->write_finish_entry(w->a); }
const char *ca_write_error(CAWrite *w) { return w->lib->error_string(w->a); }
int ca_write_errno(CAWrite *w) { return w->lib->err_no ? w->lib->err_no(w->a) : 0; }
int ca_write_close(CAWrite *w) {
    if (!w) return CA_OK;
    int rc = w->lib->write_free(w->a);
    free(w);
    return rc;
}
