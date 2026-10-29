/* Public libarchive ABI declarations, from libarchive 3.7.4 archive.h/archive_entry.h.
 * https://github.com/libarchive/libarchive/tree/v3.7.4/libarchive
 * The macOS SDK ships libarchive.2 but does not ship these headers.
 * No libarchive implementation is bundled. See THIRD_PARTY_NOTICES.md. */
#include <sys/types.h>
#include <stdint.h>
#include <time.h>
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_set_format_option(struct archive *, const char *, const char *, const char *);
const void *archive_entry_mac_metadata(struct archive_entry *, size_t *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_set_seek_callback(struct archive *, int64_t (*)(struct archive *, void *, int64_t, int));
int archive_read_open2(struct archive *, void *, int (*)(struct archive *, void *),
    ssize_t (*)(struct archive *, void *, const void **), int64_t (*)(struct archive *, void *, int64_t),
    int (*)(struct archive *, void *));
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
/* libarchive's own statuses: a warning still comes with a usable entry. */
enum { ARCHIVE_EOF = 1, ARCHIVE_OK = 0, ARCHIVE_WARN = -20 };
