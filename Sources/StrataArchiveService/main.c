#include "CArchiveSandbox.h"
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* Strata's archive service: an XPC service with an App Sandbox of its own that never reads an archive itself. Each
 * request starts a worker (Contents/Helpers/StrataArchiveWorker), which inherits the sandbox, reads one archive with
 * limits of its own and exits with its status. The service ends a worker as soon as the app cancels its request, and
 * after 25 seconds, except Extract's, which reads as long as the archive takes. */
static int refusal;
static char worker[PATH_MAX];

static int find_worker(void) {
    char self[PATH_MAX];
    uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size)) return 0;
    char *name = strrchr(self, '/');
    if (!name) return 0;
    *name = 0;
    int written = snprintf(worker, sizeof(worker), "%s/../Helpers/StrataArchiveWorker", self);
    return written > 0 && written < (int)sizeof(worker);
}

/* A received descriptor moved above the standard three, so placing one on standard input or output can't overwrite
 * another still to be placed. */
static int above_standard(int fd) {
    if (fd < 0 || fd > STDERR_FILENO) return fd;
    int moved = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    close(fd);
    return moved;
}

/* dup2 onto a descriptor's own number keeps its close-on-exec flag, so that one is inherited instead. */
static int place(posix_spawn_file_actions_t *actions, int fd, int target) {
    return fd == target ? posix_spawn_file_actions_addinherit_np(actions, fd)
                        : posix_spawn_file_actions_adddup2(actions, fd, target);
}

static pid_t spawn_worker(int request, int archive, int output, char *const arguments[]) {
    char *const environment[] = {NULL};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions)) return -1;
    if (posix_spawnattr_init(&attributes)) {
        posix_spawn_file_actions_destroy(&actions);
        return -1;
    }
    /* Spawned from a Dispatch thread, which blocks asynchronous signals, the worker would inherit that mask: the
     * kernel's CPU limit could never stop it. It starts with no signal blocked and every one at its default. */
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    const int ready = !posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK |
                                                              POSIX_SPAWN_SETSIGDEF) &&
        !posix_spawnattr_setsigmask(&attributes, &none) && !posix_spawnattr_setsigdefault(&attributes, &all) &&
        !place(&actions, request, STDIN_FILENO) && !place(&actions, output, STDOUT_FILENO) &&
        !place(&actions, archive, 3) &&
        !posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    pid_t pid;
    if (!ready || posix_spawn(&pid, worker, &actions, &attributes, arguments, environment)) pid = -1;
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    return pid;
}

/* The worker gets the request on standard input, the archive on 3 and the output pipe on standard output, and no other
 * descriptor of the service's. */
static pid_t start(xpc_object_t message) {
    int request = above_standard(xpc_dictionary_dup_fd(message, "request"));
    int archive = above_standard(xpc_dictionary_dup_fd(message, "archive"));
    int output = above_standard(xpc_dictionary_dup_fd(message, "output"));
    pid_t pid = -1;
    if (request >= 0 && archive >= 0 && output >= 0) {
        char cpu[24], memory[24];
        snprintf(cpu, sizeof(cpu), "%llu", (unsigned long long)xpc_dictionary_get_uint64(message, "cpuLimit"));
        snprintf(memory, sizeof(memory), "%llu", (unsigned long long)xpc_dictionary_get_uint64(message, "memoryLimit"));
        char *arguments[] = {"StrataArchiveWorker", "--cpu-limit", cpu, "--memory-limit", memory,
                             xpc_dictionary_get_bool(message, "unpacking") ? "--unpacking" : NULL, NULL};
        pid = spawn_worker(request, archive, output, arguments);
    }
    if (request >= 0) close(request);
    if (archive >= 0) close(archive);
    if (output >= 0) close(output);
    return pid;
}

/* A worker's exit status is the read's status. One the service ended because the app stopped the read was stopped;
 * one ended at the service's deadline, or by the kernel at its CPU or file size limit, is over its limits; one that
 * crashed, or that the service ended because the app went away, couldn't be read. */
static int outcome(int status, int past_deadline, int stopped) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (stopped) return strata_archive_stopped;
    const int limit_signal = WIFSIGNALED(status) && (WTERMSIG(status) == SIGXCPU || WTERMSIG(status) == SIGXFSZ);
    if (past_deadline || limit_signal) return strata_archive_limit;
    return strata_archive_unreadable;
}

static void reply(xpc_connection_t connection, xpc_object_t message, int status) {
    xpc_object_t answer = xpc_dictionary_create_reply(message);
    if (!answer) return;
    xpc_dictionary_set_int64(answer, "status", status);
    xpc_connection_send_message(connection, answer);
    xpc_release(answer);
}

/* One request per connection; any later message stops it. Everything about its worker happens on the connection's
 * queue: the worker's exit is delivered there, and it is reaped only after the service has forgotten it, so ending it
 * can never reach a process that took over its number. The reply follows the reaping, so a client that waits for it
 * knows its worker is gone. */
static void accept_connection(xpc_connection_t connection) {
    dispatch_queue_t queue = dispatch_queue_create("dev.strata.archive-service.request", DISPATCH_QUEUE_SERIAL);
    xpc_connection_set_target_queue(connection, queue);
    __block pid_t running = 0;
    __block int started = 0, past_deadline = 0, stopped = 0;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            // The app went away, or stopped waiting for the service: its worker has no one to read for.
            if (running > 0) kill(running, SIGKILL);
            return;
        }
        if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
        if (started) {
            if (running > 0) { stopped = 1; kill(running, SIGKILL); }
            return;
        }
        started = 1;
        pid_t pid = refusal ? 0 : start(event);
        if (pid <= 0) {
            reply(connection, event, refusal ? refusal : strata_archive_unreadable);
            return;
        }
        dispatch_source_t exited = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT,
                                                          queue);
        if (!exited) {
            kill(pid, SIGKILL);
            while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
            reply(connection, event, strata_archive_unreadable);
            return;
        }
        running = pid;
        xpc_retain(event);
        xpc_retain(connection);
        if (!xpc_dictionary_get_bool(event, "unpacking")) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, strata_archive_deadline * NSEC_PER_SEC), queue, ^{
                if (running == pid) { past_deadline = 1; kill(pid, SIGKILL); }
            });
        }
        dispatch_source_set_event_handler(exited, ^{
            running = 0;
            int status;
            pid_t waited;
            while ((waited = waitpid(pid, &status, 0)) < 0 && errno == EINTR) {}
            reply(connection, event, waited == pid ? outcome(status, past_deadline, stopped) : strata_archive_unreadable);
            xpc_release(event);
            xpc_release(connection);
            dispatch_source_cancel(exited);
        });
        dispatch_source_set_cancel_handler(exited, ^{ dispatch_release(exited); });
        dispatch_resume(exited);
    });
    xpc_connection_resume(connection);
    dispatch_release(queue);
}

int main(void) {
    refusal = !strata_archive_sandboxed() ? strata_archive_unsandboxed : find_worker() ? 0 : strata_archive_unreadable;
    xpc_main(accept_connection);
}
