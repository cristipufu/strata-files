import Foundation

nonisolated package enum Pipes {
    package enum Ending: Sendable { case finished, failed, stopped, truncated }

    /// Both ends close on exec, so a child gets only the descriptors it is handed. A writer that must never wait for a
    /// reader, or be signaled by one that went away, is nonblocking and ignores SIGPIPE.
    package static func make(nonblockingWriter: Bool = false) throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE) }
        let configured = fds.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 })
            && (!nonblockingWriter || fcntl(fds[1], F_SETNOSIGPIPE, 1) == 0 && fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0)
        guard configured else {
            fds.forEach { close($0) }
            throw POSIXError(.EIO)
        }
        return (fds[0], fds[1])
    }

    /// Reads until the writer closes its end, the output passes `limit` (keeping `limit` bytes), reading fails, or
    /// `wake` becomes readable. Output that ended as the wake-up came is complete: it finished.
    package static func read(_ fd: Int32, limit: Int, wake: Int32? = nil) -> (Data, Ending) {
        let limit = max(0, limit)
        var data = Data(), chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            var woken = false
            if let wake {
                var watched = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
                if poll(&watched, 2, -1) < 0 {
                    if errno == EINTR { continue }
                    return (data, .failed)
                }
                woken = watched[1].revents != 0
                if woken && watched[0].revents == 0 { return (data, .stopped) }
            }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return (data, .failed)
            }
            if count == 0 { return (data, .finished) }
            guard data.count + count <= limit else {
                data.append(contentsOf: chunk.prefix(limit - data.count))
                return (data, .truncated)
            }
            data.append(contentsOf: chunk.prefix(count))
            if woken { return (data, .stopped) }
        }
    }
}

/// Reads one pipe with `Pipes.read`, and can be stopped at once: stopping never waits for the writer.
nonisolated package final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let wake: (read: Int32, write: Int32)

    package init() throws { wake = try Pipes.make(nonblockingWriter: true) }

    deinit {
        close(wake.read)
        close(wake.write)
    }

    package var isStopped: Bool { lock.withLock { stopped } }

    /// Ends the read in progress, or the next one, as stopped. The wake-up pipe never fills: one byte is enough, and
    /// a full pipe is already awake.
    package func stop() {
        lock.withLock { stopped = true }
        var byte: UInt8 = 1
        _ = Darwin.write(wake.write, &byte, 1)
    }

    package func read(_ fd: Int32, limit: Int) -> (Data, Pipes.Ending) { Pipes.read(fd, limit: limit, wake: wake.read) }
}
