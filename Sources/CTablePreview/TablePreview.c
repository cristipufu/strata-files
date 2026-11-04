#include "CTablePreview.h"
#include "CArchiveSandbox.h"
#include "SQLiteFile.h"
#include "SQLiteQuota.h"
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#define HEAP_LIMIT (64ULL << 20)
#define RESIDENT_LIMIT (256ULL << 20)
#define CPU_LIMIT (8ULL * 1000000)
#define VALUE_LIMIT (8 << 20)
#define PAGE_LIMIT (8ULL << 20)
#define OUTPUT_LIMIT (10ULL << 20)
#define TABLE_LIMIT 500
#define COLUMN_LIMIT 256
#define ROW_LIMIT 200
#define NAME_LIMIT 1200
#define STRINGIFY_INNER(value) #value
#define STRINGIFY(value) STRINGIFY_INNER(value)

struct table { char name[NAME_LIMIT+1]; int view; int64_t rows; };
struct budget { double deadline; };
static uint64_t written;
static int output_failed;

static double monotonic_time(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value)) return 1e100;
    return (double)value.tv_sec+(double)value.tv_nsec/1e9;
}
static int progress(void *context) {
    const struct budget *budget = context;
    return !budget || monotonic_time() > budget->deadline || strata_read_over_cpu() || strata_read_over_memory();
}
static void begin_budget(sqlite3 *db, struct budget *budget, double seconds) {
    budget->deadline = monotonic_time()+seconds;
    sqlite3_progress_handler(db, 1000, progress, budget);
}
static int emit(const void *bytes, size_t length) {
    if (output_failed || length > OUTPUT_LIMIT-written) { output_failed = 1; return 0; }
    written += length;
    const unsigned char *next = bytes;
    while (length) {
        ssize_t sent = write(STDOUT_FILENO, next, length);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) { output_failed = 1; return 0; }
        next += sent; length -= (size_t)sent;
    }
    return 1;
}
static int emit_number(uint64_t value, unsigned length) {
    unsigned char bytes[8];
    for (unsigned i=0; i<length; ++i) bytes[length-i-1]=(unsigned char)(value>>(8*i));
    return emit(bytes,length);
}
static int emit_string(const void *value, size_t length) { return emit_number(length,4) && emit(value,length); }
static int emit_name(const char *value) { return emit_string(value,strnlen(value,NAME_LIMIT)); }
static int exact_read(void *bytes, size_t length) {
    unsigned char *next = bytes;
    while (length) {
        ssize_t received = read(STDIN_FILENO,next,length);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) return 0;
        next += received; length -= (size_t)received;
    }
    return 1;
}
static uint64_t read_number(const unsigned char *bytes, unsigned length) {
    uint64_t value = 0;
    for (unsigned i=0; i<length; ++i) value=(value<<8)|bytes[i];
    return value;
}
static int prepare(sqlite3 *db, const char *sql, sqlite3_stmt **statement) {
    return sqlite3_prepare_v2(db,sql,-1,statement,NULL);
}
static int tables(sqlite3 *db, struct table *tables, unsigned *count) {
    const char *sql = "SELECT name,type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' AND length(CAST(name AS BLOB))<=" STRINGIFY(NAME_LIMIT) " ORDER BY type,name COLLATE NOCASE LIMIT " STRINGIFY(TABLE_LIMIT);
    struct budget budget;
    begin_budget(db,&budget,2);
    sqlite3_stmt *statement = NULL;
    int status = prepare(db,sql,&statement);
    while (status == SQLITE_OK && (status=sqlite3_step(statement)) == SQLITE_ROW) {
        if (*count >= TABLE_LIMIT) { status=SQLITE_TOOBIG; break; }
        const unsigned char *name = sqlite3_column_text(statement,0);
        int length = sqlite3_column_bytes(statement,0);
        const unsigned char *type = sqlite3_column_text(statement,1);
        if (!name || length<=0 || length>NAME_LIMIT || memchr(name,0,(size_t)length) || !type) { status=SQLITE_CORRUPT; break; }
        struct table *table = &tables[(*count)++];
        memcpy(table->name,name,(size_t)length); table->name[length]=0;
        table->view = !strcmp((const char *)type,"view"); table->rows = -1;
        status=SQLITE_OK;
    }
    sqlite3_finalize(statement);
    sqlite3_progress_handler(db,0,NULL,NULL);
    if (status != SQLITE_DONE) return status;
    const double deadline=monotonic_time()+1.5;
    for (unsigned i=0; i<*count && monotonic_time()<deadline; ++i) {
        if (tables[i].view) continue;
        char *query = sqlite3_mprintf("SELECT count(*) FROM \"%w\"",tables[i].name);
        if (!query) return SQLITE_NOMEM;
        begin_budget(db,&budget,0.3);
        statement=NULL;
        if (prepare(db,query,&statement)==SQLITE_OK && sqlite3_step(statement)==SQLITE_ROW) tables[i].rows=sqlite3_column_int64(statement,0);
        sqlite3_finalize(statement); sqlite3_free(query);
        sqlite3_progress_handler(db,0,NULL,NULL);
    }
    return SQLITE_OK;
}
static int emit_tables(const struct table *tables, unsigned count) {
    if (!emit_number(count,2)) return 0;
    for (unsigned i=0; i<count; ++i)
        if (!emit_name(tables[i].name) || !emit_number((unsigned)tables[i].view,1) || !emit_number((uint64_t)tables[i].rows,8)) return 0;
    return 1;
}
static int emit_row(sqlite3_stmt *statement, unsigned columns, uint64_t *bytes) {
    const unsigned char *text[COLUMN_LIMIT] = {0};
    unsigned sizes[COLUMN_LIMIT] = {0}, tags[COLUMN_LIMIT] = {0};
    uint64_t row_bytes=0;
    for (unsigned i=0; i<columns; ++i) {
        int type=sqlite3_column_type(statement,(int)i);
        if (type==SQLITE_NULL) continue;
        if (type==SQLITE_BLOB) { tags[i]=3; sizes[i]=(unsigned)sqlite3_column_bytes(statement,(int)i); continue; }
        text[i]=sqlite3_column_text(statement,(int)i);
        int size=sqlite3_column_bytes(statement,(int)i);
        if (!text[i] || size<0 || (uint64_t)size>PAGE_LIMIT-row_bytes) return SQLITE_NOMEM;
        row_bytes+=(uint64_t)size; sizes[i]=(unsigned)size;
        tags[i] = type==SQLITE_INTEGER || type==SQLITE_FLOAT ? 1 : 2;
    }
    if (row_bytes>PAGE_LIMIT-*bytes) return SQLITE_TOOBIG;
    *bytes+=row_bytes;
    if (!emit_number(1,1)) return SQLITE_IOERR_WRITE;
    for (unsigned i=0; i<columns; ++i) {
        if (!emit_number(tags[i],1)) return SQLITE_IOERR_WRITE;
        if (tags[i]==3) { if (!emit_number(sizes[i],8)) return SQLITE_IOERR_WRITE; }
        else if (tags[i] && !emit_string(text[i],sizes[i])) return SQLITE_IOERR_WRITE;
    }
    return SQLITE_OK;
}
static int rows(sqlite3 *db, const char *table, uint64_t offset) {
    struct budget budget;
    begin_budget(db,&budget,3);
    sqlite3_stmt *statement=NULL;
    char *sql=sqlite3_mprintf("SELECT * FROM \"%w\" LIMIT %u OFFSET %llu",table,ROW_LIMIT+1,(unsigned long long)offset);
    int status=sql ? prepare(db,sql,&statement) : SQLITE_NOMEM;
    sqlite3_free(sql);
    unsigned columns = status==SQLITE_OK ? (unsigned)sqlite3_column_count(statement) : 0;
    if (columns>COLUMN_LIMIT) columns=COLUMN_LIMIT;
    if (!emit_number(columns,2)) { sqlite3_finalize(statement); sqlite3_progress_handler(db,0,NULL,NULL); return SQLITE_IOERR_WRITE; }
    for (unsigned i=0; i<columns; ++i) {
        const char *name=sqlite3_column_name(statement,(int)i);
        if (!emit_name(name ? name : "")) { sqlite3_finalize(statement); sqlite3_progress_handler(db,0,NULL,NULL); return SQLITE_IOERR_WRITE; }
    }
    unsigned count=0, more=0;
    uint64_t bytes=0;
    if (status==SQLITE_OK) {
        while ((status=sqlite3_step(statement))==SQLITE_ROW) {
            if (count==ROW_LIMIT) { more=1; status=SQLITE_DONE; break; }
            status=emit_row(statement,columns,&bytes);
            if (status!=SQLITE_OK) break;
            ++count;
        }
    }
    const unsigned reason = status==SQLITE_DONE ? 0 : status==SQLITE_TOOBIG || status==SQLITE_NOMEM ? 1 : status==SQLITE_INTERRUPT ? 2 : 3;
    const char *error = reason==3 ? sqlite3_errmsg(db) : "";
    int sent=emit_number(0,1) && emit_number(more,1) && emit_number(reason,1) && emit_name(error ? error : "SQLite error");
    sqlite3_finalize(statement); sqlite3_progress_handler(db,0,NULL,NULL);
    return sent ? SQLITE_OK : SQLITE_IOERR_WRITE;
}
int strata_table_preview_worker(uint64_t cpu, uint64_t resident, uint64_t heap) {
    if (strata_sqlite_quota(heap && heap<HEAP_LIMIT ? (size_t)heap : (size_t)HEAP_LIMIT)!=SQLITE_OK) return strata_archive_unreadable;
    int setup=strata_read_worker_start(cpu && cpu<CPU_LIMIT ? cpu : CPU_LIMIT, resident && resident<RESIDENT_LIMIT ? resident : RESIDENT_LIMIT);
    if (setup) return setup;
    unsigned char request[15];
    if (!exact_read(request,sizeof(request)) || memcmp(request,"STQ1",4) || request[4]>2) return strata_archive_unreadable;
    unsigned mode=request[4], length=(unsigned)read_number(request+5,2);
    uint64_t offset=read_number(request+7,8);
    if (length>NAME_LIMIT || (mode==1 && !length) || (mode!=1 && (length || offset)) || offset>INT64_MAX-ROW_LIMIT) return strata_archive_unreadable;
    char table[NAME_LIMIT+1]={0};
    if (!exact_read(table,length) || memchr(table,0,length)) return strata_archive_unreadable;
    sqlite3 *db=NULL;
    int status=strata_sqlite_open(3,&db);
    if (status!=SQLITE_OK) { sqlite3_close(db); return status==SQLITE_NOMEM ? strata_archive_limit : strata_archive_unreadable; }
    sqlite3_limit(db,SQLITE_LIMIT_LENGTH,VALUE_LIMIT);
    sqlite3_limit(db,SQLITE_LIMIT_WORKER_THREADS,0);
    status=sqlite3_exec(db,"PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY; PRAGMA query_only=ON",NULL,NULL,NULL);
    struct table schema[TABLE_LIMIT];
    unsigned count=0;
    if (status==SQLITE_OK && mode!=1) status=tables(db,schema,&count);
    if (status==SQLITE_OK && (!emit("STP1",4) || !emit_number(mode,1))) status=SQLITE_IOERR_WRITE;
    if (status==SQLITE_OK && mode!=1 && !emit_tables(schema,count)) status=SQLITE_IOERR_WRITE;
    if (status==SQLITE_OK && mode!=0) status=rows(db,mode==2 && count ? schema[0].name : table,offset);
    sqlite3_close(db); sqlite3_shutdown();
    if (status==SQLITE_NOMEM || status==SQLITE_TOOBIG || status==SQLITE_INTERRUPT) return strata_archive_limit;
    return status==SQLITE_OK && !output_failed ? 0 : strata_archive_unreadable;
}
