#include <sqlite3.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <stdlib.h>

typedef union { struct { size_t size; } value; max_align_t alignment; } Header;
static _Atomic size_t used;
static size_t ceiling;
static int reserve(size_t amount) {
    size_t current = atomic_load(&used);
    do { if (current > ceiling || amount > ceiling-current) return 0; }
    while (!atomic_compare_exchange_weak(&used, &current, current+amount));
    return 1;
}
static void *allocate(int bytes) {
    if (bytes <= 0 || (size_t)bytes > SIZE_MAX-sizeof(Header)) return NULL;
    size_t size = sizeof(Header)+(size_t)bytes;
    if (!reserve(size)) return NULL;
    Header *header = malloc(size);
    if (!header) { atomic_fetch_sub(&used,size); return NULL; }
    header->value.size = (size_t)bytes;
    return header+1;
}
static void release(void *pointer) {
    if (!pointer) return;
    Header *header = (Header *)pointer-1;
    size_t size = sizeof(Header)+header->value.size;
    free(header); atomic_fetch_sub(&used,size);
}
static void *resize(void *pointer, int bytes) {
    if (!pointer) return allocate(bytes);
    if (bytes <= 0) { release(pointer); return NULL; }
    Header *old = (Header *)pointer-1;
    size_t before = old->value.size, after = (size_t)bytes;
    if (after > SIZE_MAX-sizeof(Header)) return NULL;
    if (after > before && !reserve(after-before)) return NULL;
    Header *fresh = realloc(old,sizeof(Header)+after);
    if (!fresh) { if (after>before) atomic_fetch_sub(&used,after-before); return NULL; }
    fresh->value.size = after;
    if (after<before) atomic_fetch_sub(&used,before-after);
    return fresh+1;
}
static int size(void *pointer) { return pointer ? (int)(((Header *)pointer)-1)->value.size : 0; }
static int rounded(int bytes) { return bytes<=0 || bytes>INT_MAX-7 ? 0 : (bytes+7)&~7; }
static int start(void *ignored) { (void)ignored; return SQLITE_OK; }
int strata_sqlite_quota(size_t bytes) {
    ceiling = bytes;
    sqlite3_mem_methods methods = {allocate,release,resize,size,rounded,start,NULL,NULL};
    return sqlite3_config(SQLITE_CONFIG_MALLOC,&methods);
}
