#ifndef STRATA_ARCHIVE_SANDBOX_H
#define STRATA_ARCHIVE_SANDBOX_H
#include <stdint.h>
/* What the archive service and its workers share. The service links only this, never the parser. */

/* Statuses: a worker's exit status and the service's reply; 0 is success. StrataArchiveClient's ArchiveService.Status
 * mirrors them. */
enum {
    strata_archive_password = 40, strata_archive_limit = 41, strata_archive_unsafe = 42, strata_archive_unreadable = 43,
    strata_archive_missing = 44, strata_archive_encryption = 45, strata_archive_needs_extraction = 46,
    strata_archive_unsandboxed = 47, strata_archive_stopped = 48
};

/* How long the service lets a worker run, in seconds, before it ends it and answers. */
#define strata_archive_deadline 25

/* Read from this process's own code signature: a sandbox the process merely inherited doesn't count. */
int strata_archive_sandboxed(void);
/* Shared setup for a sandboxed, read-only parser process. Limits are supplied by its own fixed policy. */
int strata_read_worker_start(uint64_t cpu_microseconds, uint64_t resident_bytes);
/* AVFoundation uses sandbox-allowed media services; this worker retains its bootstrap port. */
int strata_media_worker_start(uint64_t cpu_microseconds, uint64_t resident_bytes);
int strata_read_over_cpu(void);
int strata_read_over_memory(void);
#endif
