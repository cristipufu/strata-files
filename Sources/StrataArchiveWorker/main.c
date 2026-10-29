#include "CArchivePreview.h"
#include <stdlib.h>
#include <string.h>

/* One archive read, started by the archive service: `StrataArchiveWorker [--cpu-limit microseconds]
 * [--memory-limit bytes]`, which may only lower the worker's own limits. */
static uint64_t option(int argc, char **argv, const char *name) {
    for (int i = 1; i + 1 < argc; ++i)
        if (!strcmp(argv[i], name)) return strtoull(argv[i + 1], NULL, 10);
    return 0;
}

int main(int argc, char **argv) {
    return strata_archive_preview_worker(option(argc, argv, "--cpu-limit"), option(argc, argv, "--memory-limit"));
}
