#include "CArchivePreview.h"
#include "ArchiveAPI.h"
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <locale.h>
#include <errno.h>

/* One read per process, started by the archive service, whose App Sandbox it inherits: it can't reach your files, the
 * network, devices or system services, starts no other programs and can't put a byte into any file. Its only archive
 * input is the app's pinned descriptor 3; its output is a binary stream, bounded except for Extract's, never tar or
 * executable metadata. Passwords arrive on stdin. */
struct source { unsigned char buffer[65536]; uint64_t read, cap; off_t size, zip_disk_count; int limited; };
static int exact_read(int fd, void *bytes, size_t count) {
    unsigned char *p = bytes;
    while (count) {
        ssize_t n = read(fd, p, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        p += n; count -= (size_t)n;
    }
    return 1;
}
static int emit(const void *bytes, size_t count) {
    const unsigned char *p = bytes;
    while (count) {
        ssize_t n = write(STDOUT_FILENO, p, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        p += n; count -= (size_t)n;
    }
    return 1;
}
static uint32_t read32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static unsigned read16(const unsigned char *p) { return ((unsigned)p[0] << 8) | p[1]; }
static int number(uint64_t value, unsigned count) {
    unsigned char bytes[8];
    for (unsigned i = 0; i < count; ++i) bytes[count-i-1] = (unsigned char)(value >> (8*i));
    return emit(bytes, count);
}
static uint64_t little_number(const unsigned char *p, unsigned count) {
    uint64_t value = 0;
    for (unsigned i = 0; i < count; ++i) value |= (uint64_t)p[i] << (8*i);
    return value;
}

static int peek(struct source *s, off_t offset, unsigned char *bytes, size_t count) {
    if (offset < 0 || offset > s->size || count > (uint64_t)(s->size-offset)) return 0;
    while (count) {
        if (strata_read_over_cpu() || strata_read_over_memory() || s->read >= s->cap) { s->limited = 1; return 0; }
        const size_t take = count < s->cap-s->read ? count : (size_t)(s->cap-s->read);
        ssize_t n = pread(3, bytes, take, offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        bytes += n; count -= (size_t)n; offset += n; s->read += (uint64_t)n;
    }
    return 1;
}

/* OneDrive writes zero volumes in some single-volume ZIP64 locators. libarchive rejects that locator, then tries
 * the 32-bit directory offset and cannot list archives over 4 GiB. Correct only the bytes handed to libarchive,
 * after both end records prove a single-volume layout; the archive itself is never changed. */
static off_t zip_disk_count(struct source *s) {
    unsigned char signature[4];
    if (!peek(s, 0, signature, sizeof(signature)) || little_number(signature, 4) != 0x04034b50) return -1;
    unsigned char tail[65535+22+20];
    const size_t count = s->size < (off_t)sizeof(tail) ? (size_t)s->size : sizeof(tail);
    if (count < 42 || !peek(s, s->size-(off_t)count, tail, count)) return -1;
    for (size_t at = count-22; at >= 20; --at) {
        const unsigned char *end = tail+at, *locator = end-20;
        if (little_number(end, 4) != 0x06054b50 || little_number(end+20, 2) != count-at-22) continue;
        if (little_number(end+4, 2) || little_number(end+6, 2) ||
            little_number(end+8, 2) != little_number(end+10, 2) ||
            little_number(locator, 4) != 0x07064b50 || little_number(locator+4, 4) ||
            little_number(locator+16, 4) != 0) return -1;
        const uint64_t offset = little_number(locator+8, 8);
        const uint64_t position = (uint64_t)s->size-count+at-20;
        unsigned char record[56];
        if (offset > position || position-offset < sizeof(record) ||
            !peek(s, (off_t)offset, record, sizeof(record))) return -1;
        const uint64_t length = little_number(record+4, 8);
        const uint64_t entries = little_number(record+32, 8);
        const uint64_t bytes = little_number(record+40, 8), directory = little_number(record+48, 8);
        if (little_number(record, 4) != 0x06064b50 || length < 44 || length > 16372 ||
            length != position-offset-12 || little_number(record+16, 4) || little_number(record+20, 4) ||
            little_number(record+24, 8) != entries || directory > offset || bytes != offset-directory ||
            (little_number(end+10, 2) != 0xffff && little_number(end+10, 2) != entries) ||
            (little_number(end+12, 4) != 0xffffffff && little_number(end+12, 4) != bytes) ||
            (little_number(end+16, 4) != 0xffffffff && little_number(end+16, 4) != directory)) return -1;
        return (off_t)(position+16);
    }
    return -1;
}

/* Both limits are checked at each read of the archive, so a read stops at its first read past even a lowered one; the
 * kernel's CPU limit and the memory watchdog stop one stuck inside a library call. */
static ssize_t input(struct archive *a, void *context, const void **buffer) {
    (void)a;
    struct source *s = context;
    if (strata_read_over_cpu() || strata_read_over_memory()) { s->limited = 1; return -1; }
    if (s->read >= s->cap) { s->limited = 1; return -1; }
    ssize_t n;
    do { n = read(3, s->buffer, sizeof(s->buffer)); } while (n < 0 && errno == EINTR);
    if (n > 0) s->read += (uint64_t)n;
    if (n > 0 && s->zip_disk_count >= 0) {
        const off_t end = lseek(3, 0, SEEK_CUR);
        if (end < n) return -1;
        if (s->zip_disk_count >= end-n && s->zip_disk_count < end) s->buffer[s->zip_disk_count-(end-n)] = 1;
    }
    *buffer = s->buffer;
    return n;
}
static int64_t seek_input(struct archive *a, void *context, int64_t offset, int whence) {
    (void)a;
    struct source *s = context;
    off_t base = whence == SEEK_SET ? 0 : whence == SEEK_END ? s->size : lseek(3, 0, SEEK_CUR);
    if (base < 0 || (offset > 0 && base > INT64_MAX-offset) || (offset < 0 && offset < -base)) return -1;
    off_t target = base + offset;
    if (target > s->size) return -1;
    return lseek(3, target, SEEK_SET);
}
static int snapshot(uint64_t entries, uint64_t bytes, unsigned char encrypted) {
    const unsigned char tag = strata_archive_snapshot;
    return emit(&tag, 1) && number(entries, 8) && number(bytes, 8) && emit(&encrypted, 1);
}
static int failure(struct archive *a);
/* Only a skip libarchive finished, perhaps with a warning, moves on to the next entry. */
static int skipped(struct archive *a) {
    const int status = archive_read_data_skip(a);
    return status == ARCHIVE_OK || status == ARCHIVE_WARN;
}
/* Counts what an archive holds, for the check before Extract: every entry, the size of its files, and whether any
 * entry is encrypted. It sends no listing and has none of a preview's limits on how much it reads or how many entries
 * it counts, only the worker's own. Its totals go out every 1,000 entries and before skipping any entry of 1 MB or
 * more, which can take long enough to meet a limit, so a survey cut short still gives lower bounds. */
static int survey(struct archive *a, int status, struct archive_entry *entry) {
    if (!emit("SAS1", 4)) return strata_archive_unreadable;
    uint64_t entries = 0, bytes = 0;
    unsigned char encrypted = 0;
    int result = 0;
    for (; status == ARCHIVE_OK || status == ARCHIVE_WARN; status = archive_read_next_header(a, &entry)) {
        ++entries;
        const int64_t size = archive_entry_size(entry);
        const int file = archive_entry_filetype(entry) == S_IFREG && !archive_entry_symlink(entry) &&
            !archive_entry_hardlink(entry);
        if (file && size > 0) bytes = bytes > UINT64_MAX - (uint64_t)size ? UINT64_MAX : bytes + (uint64_t)size;
        if (archive_entry_is_encrypted(entry)) encrypted = 1;
        if ((entries % 1000 == 0 || size >= (1 << 20)) && !snapshot(entries, bytes, encrypted)) {
            return strata_archive_unreadable;
        }
        if (!skipped(a)) { result = failure(a); break; }
    }
    if (!result && status != ARCHIVE_EOF) result = failure(a);
    if (!snapshot(entries, bytes, encrypted)) return strata_archive_unreadable;
    if (result) return result;
    const unsigned char end = strata_archive_end;
    return emit(&end, 1) ? 0 : strata_archive_unreadable;
}
static int failure(struct archive *a) {
    const char *message = archive_error_string(a);
    if (message && strcasestr(message, "encrypted") && strcasestr(message, "not") && strcasestr(message, "supported"))
        return strata_archive_encryption;
    if (message && (strcasestr(message, "passphrase") || strcasestr(message, "password") ||
                    strcasestr(message, "encrypted"))) return strata_archive_password;
    return strata_archive_unreadable;
}
/* A data-only copy must not silently discard a second fork. The full extractor preserves it. */
static int needs_full_extraction(struct archive_entry *entry) {
    size_t size = 0;
    const unsigned char *metadata = archive_entry_mac_metadata(entry, &size);
    if (!metadata || !size) return 0;
    if (size < 26 || size > strata_archive_byte_limit || read32(metadata) != 0x00051607 ||
        read32(metadata+4) != 0x00020000) return 1;
    unsigned count = read16(metadata+24);
    if (count > (size-26)/12) return 1;
    for (unsigned i = 0; i < count; ++i) {
        const unsigned char *record = metadata+26+12*i;
        uint32_t offset = read32(record+4), length = read32(record+8);
        if (offset > size || length > size-offset) return 1;
        if (read32(record) == 2 && length) return 1;
    }
    return 0;
}
/* An entry's path as tar writes it: leading slashes and empty or "." components dropped. Returns its length, 0 when
 * nothing is left (the archive's own top folder), -1 for a ".." and -2 past the limits: 4096 bytes, 255 a name, 128
 * folders deep, as previews take them. */
static long tar_path(const char *raw, char path[4097]) {
    size_t length = 0;
    unsigned depth = 0;
    for (const char *p = raw; *p;) {
        while (*p == '/') ++p;
        const char *start = p;
        while (*p && *p != '/') ++p;
        const size_t n = (size_t)(p - start);
        if (!n || (n == 1 && start[0] == '.')) continue;
        if (n == 2 && start[0] == '.' && start[1] == '.') return -1;
        if (n > 255 || length + (length ? 1 : 0) + n > 4096 || ++depth > 128) return -2;
        if (length) path[length++] = '/';
        memcpy(path + length, start, n);
        length += n;
    }
    path[length] = 0;
    return (long)length;
}
static int attribute(const char *name, size_t name_length, const unsigned char *value, uint32_t length) {
    const unsigned char count = (unsigned char)name_length;
    return emit(&count, 1) && emit(name, name_length) && number(length, 4) && emit(value, length);
}
/* The resource fork the system keeps for a folder on a disk without extended attributes, saying it holds none. */
static int empty_fork(const unsigned char *fork, uint32_t length) {
    unsigned char empty[286] = {0};
    const uint32_t offsets[] = {256, 256, 0, 30};
    for (unsigned i = 0; i < 16; ++i) empty[i] = empty[256 + i] = (unsigned char)(offsets[i / 4] >> (8 * (3 - i % 4)));
    memcpy(empty + 16, "This resource fork intentionally left blank   ", 46);
    empty[281] = 28; empty[283] = 30; empty[284] = empty[285] = 0xff;
    return length == sizeof(empty) && !memcmp(fork, empty, sizeof(empty));
}
/* Counts one more attribute of `length` bytes, unless all of them would then be more than an entry's metadata may
 * carry: attributes can share their bytes, so many could name a large part of it. */
static int counted(unsigned *count, size_t *total, uint32_t length) {
    if (length > strata_archive_metadata_limit - *total) return 0;
    *total += length;
    ++*count;
    return 1;
}
/* An entry's Mac metadata, an AppleDouble file as copyfile packs it, as the attributes copyfile restores from it, in its
 * order: extended attributes, then Finder info and the resource fork: 1, or 0 for metadata copyfile refuses and -1 for
 * more than an entry's metadata may carry. Left out, as copyfile leaves them: an access list (Strata drops those anyway)
 * and a folder's empty resource fork, which no folder can take. With `writing`, writes the attributes. */
static int mac_attributes(const unsigned char *m, size_t size, int folder, int writing, unsigned *count) {
    const size_t header = size < 65536 + 18 ? size : 65536 + 18;
    size_t total = 0;
    *count = 0;
    if (header < 82 || read32(m) != 0x00051607 || read32(m+4) != 0x00020000 || read16(m+24) != 2 || read32(m+26) != 9)
        return 0;
    if (read32(m+34) > 32) {
        if (header < 120 || read32(m+84) != 0x41545452) return 0;
        size_t at = 120;
        for (unsigned i = 0, attributes = read16(m+118); i < attributes; ++i) {
            if (at > header - 12) return 0;
            const uint32_t offset = read32(m+at), length = read32(m+at+4);
            const unsigned name_length = m[at+10];
            if (name_length < 2 || name_length > 128 || name_length > header - at - 11) return 0;
            const char *name = (const char *)m + at + 11;
            if (strnlen(name, name_length) != name_length - 1 || offset > size || length > size - offset) return 0;
            if (strcmp(name, "com.apple.acl.text")) {
                if (!counted(count, &total, length)) return -1;
                if (writing && !attribute(name, name_length - 1, m + offset, length)) return 0;
            }
            at += (11 + name_length + 3) & ~(size_t)3;
        }
    }
    const uint32_t info = read32(m+30), fork = read32(m+42), fork_length = read32(m+46);
    static const unsigned char no_info[32];
    if (info > header - 32) return 0;
    if (memcmp(m + info, no_info, sizeof(no_info))) {
        if (!counted(count, &total, 32)) return -1;
        if (writing && !attribute("com.apple.FinderInfo", 20, m + info, 32)) return 0;
    }
    if (read32(m+38) == 2 && fork_length) {
        if (fork > size || fork_length > size - fork) return 0;
        if (!folder || !empty_fork(m + fork, fork_length)) {
            if (!counted(count, &total, fork_length)) return -1;
            if (writing && !attribute("com.apple.ResourceFork", 22, m + fork, fork_length)) return 0;
        }
    }
    return 1;
}
static int times(struct archive_entry *entry) {
    const int set[] = {archive_entry_mtime_is_set(entry), archive_entry_atime_is_set(entry),
                       archive_entry_birthtime_is_set(entry)};
    const time_t seconds[] = {archive_entry_mtime(entry), archive_entry_atime(entry), archive_entry_birthtime(entry)};
    const long nanoseconds[] = {archive_entry_mtime_nsec(entry), archive_entry_atime_nsec(entry),
                                archive_entry_birthtime_nsec(entry)};
    const unsigned char which = (set[0] ? 1 : 0) | (set[1] ? 2 : 0) | (set[2] ? 4 : 0);
    if (!emit(&which, 1)) return 0;
    for (unsigned i = 0; i < 3; ++i) {
        const uint64_t fraction = nanoseconds[i] >= 0 && nanoseconds[i] < 1000000000 ? (uint64_t)nanoseconds[i] : 0;
        if (set[i] && !(number((uint64_t)seconds[i], 8) && number(fraction, 4))) return 0;
    }
    return 1;
}
static int contents(struct archive *a) {
    unsigned char buffer[strata_archive_chunk_limit];
    while (1) {
        const ssize_t n = archive_read_data(a, buffer, sizeof(buffer));
        if (n < 0) return failure(a);
        if (!number((uint64_t)n, 4) || !emit(buffer, (size_t)n)) return strata_archive_unreadable;
        if (!n) return 0;
    }
}
static int unpack_entry(struct archive *a, struct archive_entry *entry) {
    const char *raw = archive_entry_pathname(entry), *hard = archive_entry_hardlink(entry);
    const char *soft = archive_entry_symlink(entry);
    if (!raw) return strata_archive_unsafe;
    char path[4097], link[4097];
    const long length = tar_path(raw, path);
    if (length < 0) return length == -1 ? strata_archive_unsafe : strata_archive_limit;
    const mode_t type = archive_entry_filetype(entry);
    const unsigned char kind = hard ? 4 : soft ? 3 : type == S_IFDIR ? 2 : type == S_IFREG ? 1 : 0;
    /* The archive's own top folder ("./") has nothing to write, and devices, pipes and sockets are left out. */
    if (!length && kind != 2) return strata_archive_unsafe;
    if (!length || !kind) return skipped(a) ? 0 : failure(a);
    long link_length = 0;
    if (kind == 4) {
        link_length = tar_path(hard, link);
        if (link_length <= 0) return link_length == -2 ? strata_archive_limit : strata_archive_unsafe;
    } else if (kind == 3) {
        link_length = (long)strnlen(soft, 4097);
        if (link_length > 4096) return strata_archive_limit;
        memcpy(link, soft, (size_t)link_length);
    }
    size_t size = 0;
    const unsigned char *metadata = archive_entry_mac_metadata(entry, &size);
    unsigned attributes = 0;
    if (size > strata_archive_metadata_limit) return strata_archive_limit;
    const int parsed = metadata && size ? mac_attributes(metadata, size, kind == 2, 0, &attributes) : 1;
    if (parsed <= 0) return parsed < 0 ? strata_archive_limit : strata_archive_unreadable;
    if (!emit(&kind, 1) || !number((uint64_t)length, 4) || !emit(path, (size_t)length) ||
        !number((uint64_t)link_length, 4) || !emit(link, (size_t)link_length) ||
        !number(archive_entry_perm(entry) & 07777, 2) || !times(entry) || !number(attributes, 2) ||
        (attributes && mac_attributes(metadata, size, kind == 2, 1, &attributes) <= 0)) return strata_archive_unreadable;
    if (kind == 1 || kind == 4) return contents(a);
    return skipped(a) ? 0 : failure(a);
}
/* Extract's read: every entry tar would write, with its contents and Mac metadata, for Strata to write itself. Like
 * tar, it fails an archive libarchive warned about, Mac metadata it couldn't load included. */
static int unpack(struct archive *a, int status, struct archive_entry *entry) {
    if (!emit("SAU1", 4)) return strata_archive_unreadable;
    for (; status == ARCHIVE_OK; status = archive_read_next_header(a, &entry)) {
        const int result = unpack_entry(a, entry);
        if (result) return result;
    }
    if (status != ARCHIVE_EOF) return failure(a);
    const unsigned char end = strata_archive_end;
    return emit(&end, 1) ? 0 : strata_archive_unreadable;
}
/* Every format archive_read_support_format_all reads, in its order, but mtree: a manifest, whose reader takes each
 * entry's contents from the file it names, which a worker may be able to read, instead of from the archive. Like it,
 * clears the warnings of formats missing a library. */
static void support_formats(struct archive *a) {
    archive_read_support_format_ar(a);
    archive_read_support_format_cpio(a);
    archive_read_support_format_empty(a);
    archive_read_support_format_lha(a);
    archive_read_support_format_tar(a);
    archive_read_support_format_xar(a);
    archive_read_support_format_warc(a);
    archive_read_support_format_7zip(a);
    archive_read_support_format_cab(a);
    archive_read_support_format_rar(a);
    archive_read_support_format_rar5(a);
    archive_read_support_format_iso9660(a);
    archive_read_support_format_zip(a);
    archive_clear_error(a);
}
static struct archive *reader(const char *password, size_t password_length, int mac_metadata) {
    struct archive *a = archive_read_new();
    if (!a) return NULL;
    archive_read_support_filter_all(a);
    support_formats(a);
    /* Mac metadata comes with its item: a tar's "._" entries, and what a zip keeps in its __MACOSX folder, which only a
     * zip read from its directory can tell from the archive's own items. A damaged one read from the start comes with
     * that folder as entries, as tar writes them. On macOS libarchive reads Mac metadata unless told not to. */
    archive_read_set_format_option(a, NULL, "mac-ext", mac_metadata ? "1" : NULL);
    if (password_length) archive_read_add_passphrase(a, password);
    archive_read_set_seek_callback(a, seek_input);
    return a;
}
/* `source` opened for reading into `*a`: how opening it went, and once it has, the first entry read into `status` and
 * `entry`. */
static int opened(struct archive **a, struct source *source, const char *password, size_t password_length,
                  int mac_metadata, int *status, struct archive_entry **entry) {
    *a = reader(password, password_length, mac_metadata);
    if (!*a) return ARCHIVE_FATAL;
    const int open = archive_read_open2(*a, source, NULL, input, NULL, NULL);
    if (open == ARCHIVE_OK || open == ARCHIVE_WARN) *status = archive_read_next_header(*a, entry);
    return open;
}
static int valid_path(const char *name, size_t length) {
    if (!length || length > 4096 || name[0] == '/') return 0;
    unsigned depth = 0;
    const char *start = name;
    for (size_t i = 0; i <= length; ++i) {
        unsigned char c = (unsigned char)name[i];
        if (i < length && (c < 32 || c == 127 || c == '\\')) return 0;
        if (i == length || c == '/') {
            size_t n = name+i-start;
            if (!n || n > 255 || (n == 1 && start[0] == '.') || (n == 2 && start[0] == '.' && start[1] == '.') || ++depth > 128) return 0;
            start = name+i+1;
        }
    }
    return 1;
}
int strata_archive_preview_worker(uint64_t lowered_cpu_limit, uint64_t lowered_memory_limit, int unpacking) {
    const uint64_t cpu_ceiling = unpacking ? UINT64_MAX : strata_archive_cpu_limit;
    const uint64_t memory_ceiling = unpacking ? strata_archive_unpack_memory_limit : strata_archive_memory_limit;
    const uint64_t cpu = lowered_cpu_limit && lowered_cpu_limit < cpu_ceiling ? lowered_cpu_limit : cpu_ceiling;
    const uint64_t memory = lowered_memory_limit && lowered_memory_limit < memory_ceiling ? lowered_memory_limit : memory_ceiling;
    setlocale(LC_ALL, "en_US.UTF-8");
    const int setup = strata_read_worker_start(cpu, memory);
    if (setup) return setup;
    unsigned char request[10];
    if (!exact_read(0, request, sizeof(request)) || request[0] > strata_archive_stream || request[1] > 1 ||
        (request[0] == strata_archive_unpack) != (unpacking != 0) ||
        (request[0] == strata_archive_stream && request[1])) {
        return strata_archive_unreadable;
    }
    uint32_t path_length = read32(request+2), password_length = read32(request+6);
    if (path_length > 4096 || password_length > 1024) return strata_archive_limit;
    char selected[4097] = {0}, password[1025] = {0};
    if (!exact_read(0, selected, path_length) || !exact_read(0, password, password_length) ||
        memchr(selected, 0, path_length) || memchr(password, 0, password_length)) return strata_archive_unreadable;
    const int streaming = request[0] == strata_archive_stream;
    const int extracting = request[0] == strata_archive_extract || streaming;
    const int surveying = request[0] == strata_archive_survey;
    const int folder = request[1];
    if (extracting && !valid_path(selected, path_length)) return strata_archive_unsafe;
    struct stat info;
    if (fstat(3, &info) || !S_ISREG(info.st_mode)) return strata_archive_unreadable;
    /* A preview reads at most 1 GiB of archive; Extract, and the survey before it, read all of it. */
    struct source source = {.read = 0, .cap = surveying || unpacking ? UINT64_MAX : 1ULL << 30, .size = info.st_size,
                            .zip_disk_count = -1, .limited = 0};
    source.zip_disk_count = zip_disk_count(&source);
    int result = strata_archive_unreadable;
    struct archive *a;
    struct archive_entry *entry;
    int status = ARCHIVE_FATAL;
    int open = opened(&a, &source, password, password_length, 1, &status, &entry);
    /* macOS's libarchive refuses a zip with an item of its own in __MACOSX when it reads Mac metadata: after its check
     * that no two items overlap, it tests the wrong variable. Finder extracts such a zip, so it is read again without Mac
     * metadata, before anything is sent: its items come as they are stored, "._" files too, and the check still runs.
     * A read stopped at its limits isn't read again: freeing the first reader can bring it back under them. Only a zip
     * is read again: Mac metadata changes nothing else that fails this way. */
    const int plain = (open == ARCHIVE_OK || open == ARCHIVE_WARN) && status == ARCHIVE_FATAL && !source.limited &&
        archive_errno(a) == ARCHIVE_ERRNO_FILE_FORMAT &&
        (archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_ZIP;
    if (plain) {
        archive_read_free(a);
        a = NULL;
        if (lseek(3, 0, SEEK_SET) != 0) goto done;
        open = opened(&a, &source, password, password_length, 0, &status, &entry);
    }
    if (!a) goto done;
    if (open != ARCHIVE_OK && open != ARCHIVE_WARN) { result = failure(a); goto done; }
    if (surveying) { result = survey(a, status, entry); goto done; }
    if (unpacking) { result = unpack(a, status, entry); goto done; }
    if (!emit("SAP1", 4)) goto done;
    uint64_t output = 4;
    const uint64_t output_limit = streaming ? strata_archive_file_limit : strata_archive_byte_limit;
    unsigned headers = 0, matched = 0;
    /* A listing stops at its limits with what it has listed, and its end mark says there is more; a copy over them is
     * refused. */
    unsigned char end = strata_archive_end;
    for (; status == ARCHIVE_OK || status == ARCHIVE_WARN; status = archive_read_next_header(a, &entry)) {
        if (++headers > 50000) {
            if (extracting) { result = strata_archive_limit; goto done; }
            end = strata_archive_end_more;
            break;
        }
        const char *raw = archive_entry_pathname(entry);
        if (!raw) { result = strata_archive_unsafe; goto done; }
        size_t raw_length = strnlen(raw, 4098);
        if (raw_length > 4096) { result = strata_archive_limit; goto done; }
        const int relative_root = raw_length && raw[0] == '.';
        /* tar commonly prefixes ./; normalize only those whole components. */
        while (raw_length >= 2 && raw[0] == '.' && raw[1] == '/') { raw += 2; raw_length -= 2; }
        while (raw_length && raw[raw_length-1] == '/') --raw_length;
        if (!raw_length || (raw_length == 1 && raw[0] == '.')) {
            /* A relative root directory carries no member data. Files and links cannot use this exemption. */
            if (!relative_root || archive_entry_filetype(entry) != S_IFDIR ||
                archive_entry_symlink(entry) || archive_entry_hardlink(entry)) {
                result = strata_archive_unsafe;
                goto done;
            }
            if (!skipped(a)) { result = failure(a); goto done; }
            continue;
        }
        char path[4097]; memcpy(path, raw, raw_length); path[raw_length] = 0;
        if (!valid_path(path, raw_length)) { result = strata_archive_unsafe; goto done; }
        int chosen = !extracting || (raw_length == path_length && !memcmp(path, selected, path_length)) ||
            (folder && raw_length > path_length && !memcmp(path, selected, path_length) && path[path_length] == '/');
        if (!chosen) { if (!skipped(a)) { result = failure(a); goto done; } continue; }
        /* libarchive reports Mac metadata it couldn't load as a warning, so a data-only copy of an entry it warned
         * about could lose a resource fork. */
        if (extracting && status == ARCHIVE_WARN) { result = strata_archive_needs_extraction; goto done; }
        mode_t type = archive_entry_filetype(entry);
        unsigned char kind = type == S_IFDIR ? 2 : type == S_IFREG ? 1 : 3;
        if (archive_entry_symlink(entry) || archive_entry_hardlink(entry)) kind = 3;
        if (extracting && kind == 3) { result = strata_archive_unsafe; goto done; }
        /* Read without Mac metadata, an item's resource fork and attributes stay in their own "._" entry. */
        if (extracting && (plain || needs_full_extraction(entry))) { result = strata_archive_needs_extraction; goto done; }
        int64_t size = kind == 1 ? archive_entry_size(entry) : 0;
        if (size < 0 || (extracting && (uint64_t)size > output_limit-output)) {
            result = strata_archive_limit;
            goto done;
        }
        output += 21+raw_length+(extracting ? (uint64_t)size : 0);
        if (output > output_limit) {
            if (extracting) { result = strata_archive_limit; goto done; }
            end = strata_archive_end_more;
            break;
        }
        if (!emit(&kind, 1) || !number(raw_length, 4) || !number((uint64_t)size, 8) ||
            !number((uint64_t)archive_entry_mtime(entry), 8) || !emit(path, raw_length)) goto done;
        ++matched;
        if (extracting && kind == 1) {
            uint64_t remaining = (uint64_t)size;
            unsigned char buffer[65536];
            while (remaining) {
                size_t count = remaining < sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
                ssize_t n = archive_read_data(a, buffer, count);
                if (n <= 0) { result = failure(a); goto done; }
                if (!emit(buffer, (size_t)n)) goto done;
                remaining -= (uint64_t)n;
            }
            unsigned char extra;
            ssize_t n = archive_read_data(a, &extra, 1);
            if (n != 0) { result = n < 0 ? failure(a) : strata_archive_unreadable; goto done; }
        } else if (!skipped(a)) { result = failure(a); goto done; }
    }
    if (end != strata_archive_end_more && status != ARCHIVE_EOF) { result = failure(a); goto done; }
    if (!matched && extracting) { result = strata_archive_missing; goto done; }
    result = emit(&end, 1) ? 0 : strata_archive_unreadable;
done:
    archive_read_free(a);
    if (result && source.limited) result = strata_archive_limit;
    for (volatile unsigned char *p = (volatile unsigned char *)password; p < (volatile unsigned char *)password + sizeof(password); ++p) *p = 0;
    return result;
}
