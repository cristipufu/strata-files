#include "CArchivePreview.h"
#include "ArchiveAPI.h"
#include <sys/stat.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <locale.h>
#include <errno.h>
#include <pthread.h>
#include <mach/mach.h>

/* One read per process, started by the archive service, whose App Sandbox it inherits: it can't reach your files, the
 * network, devices or system services, starts no other programs and can't put a byte into any file. Its only archive
 * input is the app's pinned descriptor 3; its output is a bounded binary stream, never tar or executable metadata.
 * Passwords arrive on stdin. */
static uint64_t cpu_limit, memory_limit;
struct source { unsigned char buffer[65536]; uint64_t read, cap; off_t size; int limited; };
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
static int number(uint64_t value, unsigned count) {
    unsigned char bytes[8];
    for (unsigned i = 0; i < count; ++i) bytes[count-i-1] = (unsigned char)(value >> (8*i));
    return emit(bytes, count);
}
static uint64_t resident(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return UINT64_MAX;
    return info.resident_size;
}
static uint64_t cpu_used(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage)) return UINT64_MAX;
    return (uint64_t)(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000000
        + (uint64_t)(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec);
}
static int over_cpu(void) { return cpu_used() >= cpu_limit; }
static int over_memory(void) { return resident() >= memory_limit; }
/* Both limits are checked at each read of the archive, so a read stops at its first read past even a lowered one; the
 * kernel's CPU limit and the memory watchdog stop one stuck inside a library call. */
static ssize_t input(struct archive *a, void *context, const void **buffer) {
    (void)a;
    struct source *s = context;
    if (over_cpu() || over_memory()) { s->limited = 1; return -1; }
    if (s->read >= s->cap) { s->limited = 1; return -1; }
    ssize_t n;
    do { n = read(3, s->buffer, sizeof(s->buffer)); } while (n < 0 && errno == EINTR);
    if (n > 0) s->read += (uint64_t)n;
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
/* Every system service a sandboxed process may look up goes through launchd, and the sandbox lets a worker reach
 * some that could carry data out, such as the pasteboard or LaunchServices opening a URL. A worker needs none of them
 * once it has checked its own signature, so it clears its bootstrap port and gives up every send right to launchd's,
 * then confirms no right is left: a worker that kept one refuses to read. */
static int drop_bootstrap(void) {
    const mach_port_t self = mach_task_self(), launchd = bootstrap_port;
    if (task_set_special_port(self, TASK_BOOTSTRAP_PORT, MACH_PORT_NULL) != KERN_SUCCESS) return 0;
    bootstrap_port = MACH_PORT_NULL;
    if (launchd != MACH_PORT_NULL) {
        mach_port_urefs_t references = 0;
        if (mach_port_get_refs(self, launchd, MACH_PORT_RIGHT_SEND, &references) != KERN_SUCCESS) return 0;
        const mach_port_delta_t all = -(mach_port_delta_t)references;
        if (references && mach_port_mod_refs(self, launchd, MACH_PORT_RIGHT_SEND, all) != KERN_SUCCESS) return 0;
    }
    mach_port_t current = MACH_PORT_NULL;
    if (task_get_special_port(self, TASK_BOOTSTRAP_PORT, &current) != KERN_SUCCESS) return 0;
    mach_port_type_t type = 0;
    const int launchd_reachable = launchd != MACH_PORT_NULL && mach_port_type(self, launchd, &type) == KERN_SUCCESS &&
        (type & MACH_PORT_TYPE_SEND);
    return current == MACH_PORT_NULL && !launchd_reachable;
}
static void *watch_memory(void *unused) {
    (void)unused;
    while (1) {
        if (over_memory()) _exit(strata_archive_limit);
        usleep(10000);
    }
    return NULL;
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
static int survey(struct archive *a) {
    if (!emit("SAS1", 4)) return strata_archive_unreadable;
    uint64_t entries = 0, bytes = 0;
    unsigned char encrypted = 0;
    struct archive_entry *entry;
    int status, result = 0;
    while ((status = archive_read_next_header(a, &entry)) == ARCHIVE_OK || status == ARCHIVE_WARN) {
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
    unsigned count = ((unsigned)metadata[24] << 8) | metadata[25];
    if (count > (size-26)/12) return 1;
    for (unsigned i = 0; i < count; ++i) {
        const unsigned char *record = metadata+26+12*i;
        uint32_t offset = read32(record+4), length = read32(record+8);
        if (offset > size || length > size-offset) return 1;
        if (read32(record) == 2 && length) return 1;
    }
    return 0;
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
int strata_archive_preview_worker(uint64_t lowered_cpu_limit, uint64_t lowered_memory_limit) {
    if (!strata_archive_sandboxed()) return strata_archive_unsandboxed;
    cpu_limit = lowered_cpu_limit && lowered_cpu_limit < strata_archive_cpu_limit
        ? lowered_cpu_limit : strata_archive_cpu_limit;
    memory_limit = lowered_memory_limit && lowered_memory_limit < strata_archive_memory_limit
        ? lowered_memory_limit : strata_archive_memory_limit;
    setlocale(LC_ALL, "en_US.UTF-8");
    /* No new processes and no file contents either: the sandbox allows starting other programs, which libarchive does
     * for a few formats' decompressors, and writing in the service's container. Pipes have no file size. */
    const rlim_t seconds = (rlim_t)((cpu_limit + 999999) / 1000000);
    struct rlimit cpu = {seconds, seconds}, files = {32,32}, core = {0,0}, processes = {0,0}, size = {0,0};
    if (setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_NOFILE, &files) || setrlimit(RLIMIT_CORE, &core) ||
        setrlimit(RLIMIT_NPROC, &processes) || setrlimit(RLIMIT_FSIZE, &size)) return strata_archive_unreadable;
    // Darwin does not support a useful RLIMIT_DATA. Monitor the isolated worker's resident memory instead;
    // this is a sampled ceiling, not a per-allocation guarantee inside the system library.
    pthread_t monitor;
    if (pthread_create(&monitor, NULL, watch_memory, NULL)) return strata_archive_unreadable;
    pthread_detach(monitor);
    if (!drop_bootstrap()) return strata_archive_unsandboxed;
    unsigned char request[10];
    if (!exact_read(0, request, sizeof(request)) || request[0] > strata_archive_survey || request[1] > 1) {
        return strata_archive_unreadable;
    }
    uint32_t path_length = read32(request+2), password_length = read32(request+6);
    if (path_length > 4096 || password_length > 1024) return strata_archive_limit;
    char selected[4097] = {0}, password[1025] = {0};
    if (!exact_read(0, selected, path_length) || !exact_read(0, password, password_length) ||
        memchr(selected, 0, path_length) || memchr(password, 0, password_length)) return strata_archive_unreadable;
    const int extracting = request[0] == strata_archive_extract, surveying = request[0] == strata_archive_survey;
    const int folder = request[1];
    if (extracting && !valid_path(selected, path_length)) return strata_archive_unsafe;
    struct stat info;
    if (fstat(3, &info) || !S_ISREG(info.st_mode)) return strata_archive_unreadable;
    /* A preview reads at most 1 GiB of archive; a survey before Extract reads all of it, as Extract will. */
    struct source source = {.read = 0, .cap = surveying ? UINT64_MAX : 1ULL << 30, .size = info.st_size, .limited = 0};
    struct archive *a = archive_read_new();
    if (!a) return strata_archive_unreadable;
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    archive_read_set_format_option(a, NULL, "mac-ext", "1");
    if (password_length) archive_read_add_passphrase(a, password);
    archive_read_set_seek_callback(a, seek_input);
    int result = strata_archive_unreadable;
    const int opened = archive_read_open2(a, &source, NULL, input, NULL, NULL);
    if (opened != ARCHIVE_OK && opened != ARCHIVE_WARN) { result = failure(a); goto done; }
    if (surveying) { result = survey(a); goto done; }
    if (!emit("SAP1", 4)) goto done;
    uint64_t output = 4;
    unsigned headers = 0, matched = 0;
    struct archive_entry *entry;
    int status;
    /* A listing stops at its limits with what it has listed, and its end mark says there is more; a copy over them is
     * refused. */
    unsigned char end = strata_archive_end;
    while ((status = archive_read_next_header(a, &entry)) == ARCHIVE_OK || status == ARCHIVE_WARN) {
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
        if (extracting && needs_full_extraction(entry)) { result = strata_archive_needs_extraction; goto done; }
        int64_t size = kind == 1 ? archive_entry_size(entry) : 0;
        if (size < 0 || (extracting && (uint64_t)size > strata_archive_byte_limit-output)) {
            result = strata_archive_limit;
            goto done;
        }
        output += 21+raw_length+(extracting ? (uint64_t)size : 0);
        if (output > strata_archive_byte_limit) {
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
