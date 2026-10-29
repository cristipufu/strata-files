#ifndef STRATA_ARCHIVE_PREVIEW_H
#define STRATA_ARCHIVE_PREVIEW_H
#include <stdint.h>
#include "CArchiveSandbox.h"
/* Runs only in the archive service's workers, which never initialize app storage or AppKit. */

/* A worker's limits: CPU time in microseconds, resident memory in bytes, and the bytes it writes before its end
 * mark. */
#define strata_archive_cpu_limit (15ULL * 1000000)
#define strata_archive_memory_limit (256ULL << 20)
#define strata_archive_byte_limit (60ULL << 20)

/* One read in a worker process: the request on standard input ([mode, folder, path length, password length, path,
 * password]), the archive on descriptor 3, the output on standard output; returns the status. Limits only lower the
 * defines above (0 keeps them).
 *
 * Listing and copying out write "SAP1", then a record per entry ([kind: 1 file, 2 folder, 3 anything else; path length;
 * size; modified; path; contents when copying out]), then an end mark. A survey writes
 * "SAS1", then snapshots of its running totals ([tag; entries; bytes of files; any entry encrypted]), then an end mark
 * once it has counted everything. */
enum { strata_archive_list = 0, strata_archive_extract = 1, strata_archive_survey = 2 };
enum {
    strata_archive_end = 0, strata_archive_end_more = 4 /* a listing stopped at its limits, with entries left */,
    strata_archive_snapshot = 0x53
};
int strata_archive_preview_worker(uint64_t cpu_limit, uint64_t memory_limit);
#endif
