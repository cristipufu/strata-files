#ifndef STRATA_ARCHIVE_SANDBOX_H
#define STRATA_ARCHIVE_SANDBOX_H
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
#endif
