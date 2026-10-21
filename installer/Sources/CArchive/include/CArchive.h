// A narrow shim over libarchive's archive_read_* and archive_write_disk_*.
// The library is dlopen'd at run time (Cartouche.app/Contents/Helpers/
// libarchive.dylib), so nothing here links it at build time and InstallerKit's
// tests can run against a fake without the dylib.

#ifndef CARCHIVE_H
#define CARCHIVE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Same values as libarchive's archive.h */
#define CA_OK      0
#define CA_RETRY   (-10)
#define CA_WARN    (-20)
#define CA_FAILED  (-25)
#define CA_FATAL   (-30)
#define CA_EOF     1

/* archive_entry file types (AE_IF*) */
#define CA_IFMT   0170000
#define CA_IFREG  0100000
#define CA_IFLNK  0120000
#define CA_IFSOCK 0140000
#define CA_IFCHR  0020000
#define CA_IFBLK  0060000
#define CA_IFDIR  0040000
#define CA_IFIFO  0010000

/* archive_format() families */
#define CA_FORMAT_BASE_MASK 0xff0000
#define CA_FORMAT_CPIO    0x10000
#define CA_FORMAT_SHAR    0x20000
#define CA_FORMAT_TAR     0x30000
#define CA_FORMAT_ISO9660 0x40000
#define CA_FORMAT_ZIP     0x50000
#define CA_FORMAT_EMPTY   0x60000
#define CA_FORMAT_AR      0x70000
#define CA_FORMAT_MTREE   0x80000
#define CA_FORMAT_RAW     0x90000
#define CA_FORMAT_XAR     0xA0000
#define CA_FORMAT_LHA     0xB0000
#define CA_FORMAT_CAB     0xC0000
#define CA_FORMAT_RAR     0xD0000
#define CA_FORMAT_7ZIP    0xE0000
#define CA_FORMAT_WARC    0xF0000
#define CA_FORMAT_RAR_V5  0x100000

/* ARCHIVE_EXTRACT_* */
#define CA_EXTRACT_OWNER            0x0001
#define CA_EXTRACT_PERM             0x0002
#define CA_EXTRACT_TIME             0x0004
#define CA_EXTRACT_NO_OVERWRITE     0x0008
#define CA_EXTRACT_UNLINK           0x0010
#define CA_EXTRACT_ACL              0x0020
#define CA_EXTRACT_FFLAGS           0x0040
#define CA_EXTRACT_XATTR            0x0080
#define CA_EXTRACT_SECURE_SYMLINKS  0x0100
#define CA_EXTRACT_SECURE_NODOTDOT  0x0200
#define CA_EXTRACT_NO_AUTODIR       0x0400
#define CA_EXTRACT_NO_OVERWRITE_NEWER 0x0800
#define CA_EXTRACT_SPARSE           0x1000
#define CA_EXTRACT_MAC_METADATA     0x2000
#define CA_EXTRACT_NO_HFS_COMPRESSION 0x4000
#define CA_EXTRACT_HFS_COMPRESSION_FORCED 0x8000
#define CA_EXTRACT_SECURE_NOABSOLUTEPATHS 0x10000
#define CA_EXTRACT_CLEAR_NOCHANGE_FFLAGS 0x20000
#define CA_EXTRACT_SAFE_WRITES      0x40000

typedef struct CALib CALib;

/* dlopen(path, RTLD_NOW | RTLD_LOCAL) and resolve every entry point used.
 * NULL when the library cannot be loaded or lacks required symbols. */
CALib * _Nullable ca_open(const char * _Nonnull path);
void ca_close(CALib * _Nonnull lib);
/* "libarchive 3.8.9 zlib/1.3.1 liblzma/5.8.4 libzstd/1.5.7" */
const char * _Nonnull ca_version(CALib * _Nonnull lib);

typedef struct CARead CARead;

/* Opens the archive at paths[0]; the rest of the list is the remaining
 * volumes, in order, for multi-volume RAR. Supports all formats and
 * compression filters libarchive knows. NULL on open failure. */
CARead * _Nullable ca_read_open(CALib * _Nonnull lib,
                                const char * _Nonnull const * _Nonnull paths,
                                int count);
/* CA_OK: an entry is current. CA_EOF: done. Negative: error, ca_read_error. */
int ca_read_next(CARead * _Nonnull r);
/* Bytes read, or negative on error. */
long long ca_read_data(CARead * _Nonnull r, void * _Nonnull buf, unsigned long long size);
int ca_read_skip(CARead * _Nonnull r);
/* Closes and frees; returns the last status. */
int ca_read_close(CARead * _Nonnull r);
const char * _Nullable ca_read_error(CARead * _Nonnull r);
int ca_read_errno(CARead * _Nonnull r);
int ca_read_format(CARead * _Nonnull r);
const char * _Nullable ca_read_format_name(CARead * _Nonnull r);
int ca_read_filter_count(CARead * _Nonnull r);
const char * _Nullable ca_read_filter_name(CARead * _Nonnull r, int index);
/* >0 when the archive holds encrypted entries, 0 none, <0 unknown. */
int ca_read_has_encrypted(CARead * _Nonnull r);

/* Current entry metadata. Strings are UTF-8; NULL when unknown. */
const char * _Nullable ca_entry_path(CARead * _Nonnull r);
long long ca_entry_size(CARead * _Nonnull r);
int ca_entry_type(CARead * _Nonnull r);
int ca_entry_encrypted(CARead * _Nonnull r);
const char * _Nullable ca_entry_symlink(CARead * _Nonnull r);
const char * _Nullable ca_entry_hardlink(CARead * _Nonnull r);
/* Rewrites the current entry's path; write_disk then writes there. */
void ca_entry_set_path(CARead * _Nonnull r, const char * _Nonnull path);

typedef struct CAWrite CAWrite;

/* archive_write_disk_new + set_options(flags). */
CAWrite * _Nullable ca_write_disk(CALib * _Nonnull lib, int flags);
int ca_write_header(CAWrite * _Nonnull w, CARead * _Nonnull r);
long long ca_write_data(CAWrite * _Nonnull w, const void * _Nonnull buf, unsigned long long size);
int ca_write_finish_entry(CAWrite * _Nonnull w);
const char * _Nullable ca_write_error(CAWrite * _Nonnull w);
int ca_write_errno(CAWrite * _Nonnull w);
/* Closes and frees; returns the last status. */
int ca_write_close(CAWrite * _Nonnull w);

#ifdef __cplusplus
}
#endif

#endif
