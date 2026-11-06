#include "CArchiveSandbox.h"
#include <sys/resource.h>
#include <unistd.h>
#include <stdint.h>
#include <pthread.h>
#include <mach/mach.h>
#include <fcntl.h>

static uint64_t cpu_limit, memory_limit;
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
int strata_read_over_cpu(void) { return cpu_used() >= cpu_limit; }
int strata_read_over_memory(void) { return resident() >= memory_limit; }

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
        if (strata_read_over_memory()) _exit(strata_archive_limit);
        usleep(10000);
    }
    return NULL;
}

static int start(uint64_t cpu, uint64_t memory, int media) {
    if (!strata_archive_sandboxed()) return strata_archive_unsandboxed;
    cpu_limit = cpu;
    memory_limit = memory;
    const rlim_t seconds = cpu_limit == UINT64_MAX ? RLIM_INFINITY
        : (rlim_t)(cpu_limit / 1000000 + (cpu_limit % 1000000 != 0));
    const rlim_t file_limit = media ? 128 : 32;
    const rlim_t cache_limit = media ? 8 << 20 : 0;
    struct rlimit time = {seconds, seconds}, files = {file_limit,file_limit}, core = {0,0}, processes = {0,0}, size = {cache_limit,cache_limit};
    if (setrlimit(RLIMIT_CPU, &time) || setrlimit(RLIMIT_NOFILE, &files) || setrlimit(RLIMIT_CORE, &core) ||
        setrlimit(RLIMIT_NPROC, &processes) || setrlimit(RLIMIT_FSIZE, &size) ||
        fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)) return strata_archive_unreadable;
    // Darwin has no useful RLIMIT_DATA. This sampled ceiling supplements each parser's allocation bounds.
    pthread_t monitor;
    if (pthread_create(&monitor, NULL, watch_memory, NULL)) return strata_archive_unreadable;
    pthread_detach(monitor);
    return media || drop_bootstrap() ? 0 : strata_archive_unsandboxed;
}

int strata_read_worker_start(uint64_t cpu, uint64_t memory) { return start(cpu, memory, 0); }
int strata_media_worker_start(uint64_t cpu, uint64_t memory) { return start(cpu, memory, 1); }
