#ifndef STRATA_TABLE_PREVIEW_H
#define STRATA_TABLE_PREVIEW_H
#include <stdint.h>
int strata_table_preview_worker(uint64_t cpu_limit, uint64_t resident_limit, uint64_t heap_limit);
#endif
