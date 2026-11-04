#include "SQLiteFile.h"
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>

static sqlite3_vfs *platform;
struct read_file { sqlite3_file base; int descriptor; sqlite3_int64 length; };
static int close_file(sqlite3_file *file) {
    struct read_file *read = (struct read_file *)file;
    close(read->descriptor); read->descriptor = -1; return SQLITE_OK;
}
static int read_file(sqlite3_file *file, void *bytes, int count, sqlite3_int64 offset) {
    struct read_file *source = (struct read_file *)file;
    if (count < 0 || offset < 0 || offset > INT64_MAX-count) return SQLITE_IOERR_READ;
    unsigned char *next = bytes;
    size_t remaining = (size_t)count;
    while (remaining) {
        ssize_t received = pread(source->descriptor, next, remaining, (off_t)offset);
        if (received < 0 && errno == EINTR) continue;
        if (received < 0) return SQLITE_IOERR_READ;
        if (!received) { memset(next, 0, remaining); return SQLITE_IOERR_SHORT_READ; }
        next += received; remaining -= (size_t)received; offset += received;
    }
    return SQLITE_OK;
}
static int write_file(sqlite3_file *file, const void *bytes, int count, sqlite3_int64 offset) {
    (void)file; (void)bytes; (void)count; (void)offset; return SQLITE_READONLY;
}
static int truncate_file(sqlite3_file *file, sqlite3_int64 length) { (void)file; (void)length; return SQLITE_READONLY; }
static int sync_file(sqlite3_file *file, int flags) { (void)file; (void)flags; return SQLITE_OK; }
static int file_size(sqlite3_file *file, sqlite3_int64 *size) { *size = ((struct read_file *)file)->length; return SQLITE_OK; }
static int lock_file(sqlite3_file *file, int lock) { (void)file; (void)lock; return SQLITE_OK; }
static int reserved(sqlite3_file *file, int *result) { (void)file; *result = 0; return SQLITE_OK; }
static int control(sqlite3_file *file, int operation, void *argument) {
    (void)file; (void)operation; (void)argument; return SQLITE_NOTFOUND;
}
static int sector(sqlite3_file *file) { (void)file; return 4096; }
static int characteristics(sqlite3_file *file) { (void)file; return SQLITE_IOCAP_IMMUTABLE; }
static const sqlite3_io_methods methods = {
    .iVersion = 1, .xClose = close_file, .xRead = read_file, .xWrite = write_file, .xTruncate = truncate_file,
    .xSync = sync_file, .xFileSize = file_size, .xLock = lock_file, .xUnlock = lock_file, .xCheckReservedLock = reserved,
    .xFileControl = control, .xSectorSize = sector, .xDeviceCharacteristics = characteristics
};
static int open_file(sqlite3_vfs *vfs, const char *name, sqlite3_file *file, int flags, int *out_flags) {
    (void)name;
    if (!(flags & SQLITE_OPEN_MAIN_DB) || !(flags & SQLITE_OPEN_READONLY)) return SQLITE_CANTOPEN;
    const int source = *(int *)vfs->pAppData;
    struct stat info;
    if (fstat(source, &info) || !S_ISREG(info.st_mode) || info.st_size < 0) return SQLITE_CANTOPEN;
    int descriptor = dup(source);
    if (descriptor < 0) return SQLITE_CANTOPEN;
    struct read_file *read = (struct read_file *)file;
    memset(read, 0, sizeof(*read));
    read->descriptor = descriptor; read->length = info.st_size; read->base.pMethods = &methods;
    if (out_flags) *out_flags = SQLITE_OPEN_READONLY;
    return SQLITE_OK;
}
static int delete_file(sqlite3_vfs *vfs, const char *name, int sync) { (void)vfs; (void)name; (void)sync; return SQLITE_READONLY; }
static int access_file(sqlite3_vfs *vfs, const char *name, int flags, int *result) {
    (void)vfs; *result = flags != SQLITE_ACCESS_READWRITE && !strcmp(name, "strata.sqlite"); return SQLITE_OK;
}
static int full_path(sqlite3_vfs *vfs, const char *name, int size, char *output) {
    (void)vfs; (void)name;
    const char path[] = "strata.sqlite";
    if (size < (int)sizeof(path)) return SQLITE_CANTOPEN;
    memcpy(output, path, sizeof(path)); return SQLITE_OK;
}
static int randomness(sqlite3_vfs *vfs, int bytes, char *output) { (void)vfs; return platform->xRandomness(platform, bytes, output); }
static int sleep_for(sqlite3_vfs *vfs, int microseconds) { (void)vfs; return platform->xSleep(platform, microseconds); }
static int current_time(sqlite3_vfs *vfs, double *time) { (void)vfs; return platform->xCurrentTime(platform, time); }
static int last_error(sqlite3_vfs *vfs, int size, char *output) {
    (void)vfs; return platform->xGetLastError ? platform->xGetLastError(platform, size, output) : 0;
}
int strata_sqlite_open(int descriptor, sqlite3 **database) {
    platform = sqlite3_vfs_find(NULL);
    if (!platform) return SQLITE_CANTOPEN;
    // Keep only the system's clock/randomness callbacks; every file callback is descriptor-only and read-only.
    static sqlite3_vfs vfs;
    static int source;
    source = descriptor; memset(&vfs, 0, sizeof(vfs));
    vfs.iVersion = 1; vfs.szOsFile = sizeof(struct read_file); vfs.mxPathname = 64;
    vfs.zName = "strata-readonly"; vfs.pAppData = &source; vfs.pNext = NULL;
    vfs.xOpen = open_file; vfs.xDelete = delete_file; vfs.xAccess = access_file; vfs.xFullPathname = full_path;
    vfs.xRandomness = randomness; vfs.xSleep = sleep_for; vfs.xCurrentTime = current_time; vfs.xGetLastError = last_error;
    int status = sqlite3_vfs_register(&vfs, 0);
    if (status != SQLITE_OK) return status;
    return sqlite3_open_v2("strata.sqlite", database, SQLITE_OPEN_READONLY | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOMUTEX, vfs.zName);
}
