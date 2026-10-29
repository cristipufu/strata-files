#ifndef STRATA_ARCHIVE_PREVIEW_H
#define STRATA_ARCHIVE_PREVIEW_H
#include <stdint.h>
#include "CArchiveSandbox.h"
/* Runs only in the archive service's workers, which never initialize app storage or AppKit. */

/* A worker's limits: CPU time in microseconds, resident memory in bytes, and the bytes it writes before its end
 * mark. Extract's worker has no CPU or output limit, since both grow with the archive, and the memory of the largest
 * dictionaries archivers use; the free space Strata keeps on the disk bounds what it writes. */
#define strata_archive_cpu_limit (15ULL * 1000000)
#define strata_archive_memory_limit (256ULL << 20)
#define strata_archive_byte_limit (60ULL << 20)
#define strata_archive_unpack_memory_limit (4ULL << 30)
/* For Extract: the most bytes in one chunk of contents, and in one entry's Mac metadata. */
#define strata_archive_chunk_limit 65536
#define strata_archive_metadata_limit (64ULL << 20)

/* One read in a worker process: the request on standard input ([mode, folder, path length, password length, path,
 * password]), the archive on descriptor 3, the output on standard output; returns the status. Limits only lower the
 * defines above (0 keeps them). Extract's read takes `unpacking`, and only it does.
 *
 * Listing and copying out write "SAP1", then a record per entry ([kind: 1 file, 2 folder, 3 anything else; path length;
 * size; modified; path; contents when copying out]), then an end mark. A survey writes
 * "SAS1", then snapshots of its running totals ([tag; entries; bytes of files; any entry encrypted]), then an end mark
 * once it has counted everything.
 *
 * Extract writes "SAU1", then a record per entry tar would write: [kind: 1 file, 2 folder, 3 symbolic link, 4 hard
 * link; path length (4 bytes); path; link length (4); the link's target, or the path a hard link shares; permissions
 * (2); which times are set (1: modified, 2: accessed, 4: created), then each as seconds (8) and nanoseconds (4);
 * attribute count (2), then each attribute: name length (1), name, value length (4), value; then for a file or hard
 * link its contents, in chunks of [length (4); bytes] ending with an empty one], then an end mark. Devices, pipes and
 * sockets are left out. */
enum { strata_archive_list = 0, strata_archive_extract = 1, strata_archive_survey = 2, strata_archive_unpack = 3 };
enum {
    strata_archive_end = 0, strata_archive_end_more = 4 /* a listing stopped at its limits, with entries left */,
    strata_archive_snapshot = 0x53
};
int strata_archive_preview_worker(uint64_t cpu_limit, uint64_t memory_limit, int unpacking);
#endif
