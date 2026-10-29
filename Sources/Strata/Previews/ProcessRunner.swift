import Foundation
import StrataArchiveClient

/// Runs a command-line tool off the main thread, collecting its output, with a timeout and an output cap,
/// and terminating it if the calling task is cancelled.
nonisolated package enum ProcessRunner {
    package struct Result: Sendable {
        package var output: Data
        package var status: Int32
        package var timedOut: Bool
        /// The output went past `outputLimit`; what came stops there.
        package var truncated: Bool
        /// Reading the output failed; what came is incomplete.
        package var failed: Bool

        package init(output: Data, status: Int32, timedOut: Bool, truncated: Bool, failed: Bool = false) {
            self.output = output
            self.status = status
            self.timedOut = timedOut
            self.truncated = truncated
            self.failed = failed
        }
    }

    package static let outputLimit = 64 << 20

    /// Standard input and one more file (descriptor 3 in the child) are optional; the caller keeps both open until this
    /// call returns. Secrets reach the child through them, never its arguments.
    package static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                            standardInput: FileHandle? = nil, file: FileHandle? = nil) async throws -> Result {
        let box = ProcessBox()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Swift.Result {
                        try box.run(executable, arguments, timeout: timeout, standardInput: standardInput, file: file)
                    })
                }
            }
        } onCancel: {
            box.terminate()
        }
        try Task.checkCancellation()
        return result
    }

    /// The child stays unreaped until the same lock that guards signaling clears its PID. Foundation's Process
    /// reaps independently, which cannot provide that guarantee for a delayed SIGKILL.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var timedOut = false
        private var cancelled = false

        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, standardInput: FileHandle?,
                 file: FileHandle?) throws -> Result {
            let outputFD = try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                let child = try Self.launch(executable, arguments, standardInput: standardInput, file: file)
                pid = child.pid
                return child.output
            }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, lock.withLock({ () -> Bool in
                    guard pid != nil else { return false }
                    timedOut = true
                    return true
                }) else { return }
                terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { deadline.cancel() }
            let (data, ending) = Pipes.read(outputFD, limit: ProcessRunner.outputLimit)
            // A tool still writing into a pipe nobody reads is ended by SIGPIPE, rather than by the delayed SIGKILL.
            close(outputFD)
            let truncated = ending == .truncated, failed = ending == .failed
            if truncated || failed { terminate() }
            var status: Int32 = 0
            while true {
                let finished = lock.withLock { () -> Bool in
                    guard let pid else { return true }
                    let waited = waitpid(pid, &status, WNOHANG)
                    if waited == pid || (waited < 0 && errno != EINTR) {
                        if waited < 0 { status = -1 }
                        self.pid = nil
                        return true
                    }
                    return false
                }
                if finished { break }
                usleep(1000)
            }
            let code = status < 0 ? -1 : status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
            return Result(output: data, status: code, timedOut: lock.withLock { timedOut }, truncated: truncated, failed: failed)
        }

        /// Ends the process group. A read still in progress goes on until the pipe closes, so output already written is
        /// kept.
        func terminate() {
            let child = lock.withLock { () -> pid_t? in
                cancelled = true
                guard let pid else { return nil }
                _ = kill(-pid, SIGTERM)
                return pid
            }
            guard let child else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    guard self.pid == child else { return }
                    _ = kill(-child, SIGKILL)
                }
            }
        }

        /// A separate process group lets cancellation stop decompressors too. Only stdout, the given standard input
        /// (else /dev/null) and file are inherited; stderr goes to /dev/null.
        private static func launch(_ executable: String, _ arguments: [String], standardInput: FileHandle?,
                                   file: FileHandle?) throws -> (pid: pid_t, output: Int32) {
            let output = try Pipes.make()
            var succeeded = false
            defer {
                close(output.write)
                if !succeeded { close(output.read) }
            }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            func checked(_ code: Int32) throws {
                if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            }
            try checked(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try checked(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            // Darwin leaves FD_CLOEXEC set for dup2(fd, fd), so each source is a distinct descriptor above the targets.
            var sources: [Int32] = []
            defer { sources.forEach { close($0) } }
            func place(_ fd: Int32, at target: Int32) throws {
                let source = fcntl(fd, F_DUPFD_CLOEXEC, 4)
                guard source >= 0 else { throw POSIXError(.EBADF) }
                sources.append(source)
                try checked(posix_spawn_file_actions_adddup2(&actions, source, target))
            }
            try place(output.write, at: STDOUT_FILENO)
            if let standardInput { try place(standardInput.fileDescriptor, at: STDIN_FILENO) }
            else { try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)) }
            try checked(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
            if let file { try place(file.fileDescriptor, at: 3) }
            // Spawned from a Dispatch thread, which blocks asynchronous signals, the tool would inherit that mask and
            // never see the SIGTERM that lets it stop cleanly. It starts with none blocked and every one at its default.
            var none = sigset_t(), all = sigset_t()
            sigemptyset(&none)
            sigfillset(&all)
            try checked(posix_spawnattr_setsigmask(&attributes, &none))
            try checked(posix_spawnattr_setsigdefault(&attributes, &all))
            try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                                                                    | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
            try checked(posix_spawnattr_setpgroup(&attributes, 0))
            var child: pid_t = 0
            try cStrings([executable] + arguments) { argv in
                try cStrings(["LC_ALL=en_US.UTF-8", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin"]) { environment in
                    try checked(posix_spawn(&child, executable, &actions, &attributes, argv, environment))
                }
            }
            succeeded = true
            return (child, output.read)
        }

        private static func cStrings<T>(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
            var pointers: [UnsafeMutablePointer<CChar>?] = []
            defer { pointers.forEach { free($0) } }
            for value in values {
                guard !value.contains("\0") else { throw POSIXError(.EINVAL) }
                guard let pointer = strdup(value) else { throw POSIXError(.ENOMEM) }
                pointers.append(pointer)
            }
            pointers.append(nil)
            return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
        }
    }
}
