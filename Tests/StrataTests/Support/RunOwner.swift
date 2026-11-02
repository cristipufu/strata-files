import Darwin
import Foundation

/// The test process that made something it may leave behind, such as a scratch disk or a preferences folder: its
/// number, and when it started, which tells it from a later process given the same number.
nonisolated struct RunOwner: Equatable {
    static let file = "owner"
    let pid: pid_t
    let started: Int64
}

nonisolated extension RunOwner {
    /// This process, unless the system can't say when it started.
    static let current = (try? started(pid: getpid())).map { Self(pid: getpid(), started: $0) }

    /// The owner the marker in the opened `folder` names, or nil for a folder without one. It's read without following a
    /// link, and only from a small regular file.
    init?(markerIn folder: Int32) throws {
        let fd = openat(folder, Self.file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64 else { throw POSIXError(.EFTYPE) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard read(fd, &bytes, bytes.count) == bytes.count else { throw POSIXError(.EIO) }
        let fields = String(decoding: bytes, as: UTF8.self).split(separator: " ")
        guard fields.count == 2, let pid = pid_t(fields[0]), let started = Int64(fields[1]) else { throw POSIXError(.EFTYPE) }
        self.init(pid: pid, started: started)
    }

    var marker: Data { Data("\(pid) \(started)".utf8) }

    /// Whether this process still runs; one the system can't say about counts as running.
    var isRunning: Bool {
        do {
            return try Self.started(pid: pid) == started
        } catch {
            return true
        }
    }

    /// When process `pid` started; nil when there's no such process.
    private static func started(pid: pid_t) throws -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&request, u_int(request.count), &info, &size, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }
}
