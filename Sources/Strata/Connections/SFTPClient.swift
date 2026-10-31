import Foundation
import StrataModel
import StrataSupport

/// What an SFTP server says about a file: whatever of these it sent.
package nonisolated struct SFTPAttributes: Sendable, Equatable {
    package var size: UInt64?
    package var uid: UInt32?
    package var gid: UInt32?
    package var permissions: UInt32?
    package var accessTime: UInt32?
    package var modificationTime: UInt32?

    package var fileType: UInt32? { permissions.map { $0 & UInt32(S_IFMT) } }
    package var isDirectory: Bool { fileType == UInt32(S_IFDIR) }
    package var isSymlink: Bool { fileType == UInt32(S_IFLNK) }
    package var isRegularFile: Bool { fileType == UInt32(S_IFREG) }
}

/// One item of a remote folder.
package nonisolated struct SFTPEntry: Sendable, Equatable {
    package let name: String
    package let attributes: SFTPAttributes
}

package nonisolated enum SFTPError: Error, Equatable, LocalizedError {
    /// The server refused: one of SFTP's status codes, and its message.
    case status(UInt32, String)
    /// The connection ended (the login failed, the network dropped, ssh quit): what ssh said, if anything.
    case disconnected(String)
    /// The server sent something that isn't SFTP (or far bigger than SFTP allows).
    case malformed
    case stopped
    /// The file is bigger than it was when it was listed.
    case tooLarge
    /// Connected, but nothing came back for a minute while something was asked (see `silenceLimit`).
    case stoppedAnswering

    package static let eof: UInt32 = 1
    package static let noSuchFile: UInt32 = 2
    package static let permissionDenied: UInt32 = 3
    package static let failure: UInt32 = 4
    package static let unsupported: UInt32 = 8

    package var errorDescription: String? {
        switch self {
        case .status(let code, let message):
            switch code {
            case Self.noSuchFile: String(localized: "It isn’t on the server anymore.")
            case Self.permissionDenied: String(localized: "The server doesn’t allow that (permission denied).")
            case Self.unsupported: String(localized: "The server doesn’t support that.")
            default: message.isEmpty ? String(localized: "The server couldn’t do that.") : message
            }
        case .disconnected(let detail):
            detail.isEmpty ? String(localized: "The connection to the server ended.")
                : String(localized: "The connection to the server ended: \(detail)", comment: "What ssh said follows")
        case .malformed: String(localized: "The server sent something Strata doesn’t understand.")
        case .stopped: String(localized: "Stopped.")
        case .tooLarge: String(localized: "It changed on the server while it was being read. Reload the folder and try again.")
        case .stoppedAnswering: String(localized: "The server stopped answering, so Strata disconnected. Reload the folder to connect again.")
        }
    }
}

/// SFTP (version 3, what OpenSSH and nearly every server speak) over a pipe to a process: `ssh -s host sftp` for a
/// server, `sftp-server` itself in tests. Requests can overlap (reads and writes are pipelined); each call blocks its
/// thread until its answer arrives, so callers run it off the main thread.
///
/// Everything from the server is untrusted: messages are size-checked, and names are handed out as sent, for callers
/// to vet before they become local paths. Call `close()` when done: the reader threads keep the client alive until then.
package nonisolated final class SFTPClient: @unchecked Sendable {
    private enum Packet: UInt8 {
        case `init` = 1, version = 2, open = 3, close = 4, read = 5, write = 6, lstat = 7, fstat = 8, setstat = 9
        case opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15, realpath = 16, stat = 17, rename = 18
        case readlink = 19, status = 101, handle = 102, data = 103, name = 104, attrs = 105, extended = 200
    }

    /// OpenSSH's own limit is 256 KiB; anything much bigger isn't SFTP.
    private static let maxPacket = 1 << 20
    package static let chunk = 32 * 1024
    /// Reads and writes in flight per transfer.
    private static let window = 16

    private let process: Process
    private let toServer: FileHandle
    private let fromServer: FileHandle
    private let errors = Pipe()
    private let lock = NSLock()
    /// Whole packets go out one at a time. Separate from `lock`: a write can block on a full pipe while the reader still
    /// needs `lock` to hand out answers.
    private let writeLock = NSLock()
    private var nextID: UInt32 = 1
    private var waiting: [UInt32: Waiter] = [:]
    private var closedReason: String?
    /// When anything last came from the server, and whether the session is up (logging in can take as long as you
    /// take to type a password, so the silence limit only counts after it).
    private var lastHeard = ProcessInfo.processInfo.systemUptime
    private var isAnswering = false
    private var stoppedAnswering = false
    /// How long a connected server may send nothing at all while something is asked before it's taken as stuck and the
    /// connection is closed. A slow server still sends something; a dropped network ends ssh by itself (keepalives).
    package let silenceLimit: TimeInterval
    private var stderrText = ""
    /// Extensions the server announced ("posix-rename@openssh.com", "statvfs@openssh.com"…).
    package private(set) var extensions: [String: String] = [:]

    private final class Waiter: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var reply: (type: UInt8, body: [UInt8])?
    }

    /// Starts `executable` with `arguments` (and `environment` added); `connect()` then says hello. Throws when the
    /// program can't start.
    package init(executable: URL, arguments: [String], environment: [String: String] = [:], connect: Bool = true,
         silenceLimit: TimeInterval = 60) throws {
        self.silenceLimit = silenceLimit
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        toServer = input.fileHandleForWriting
        fromServer = output.fileHandleForReading
        // ssh can exit between a request's connection check and its write. Suppress SIGPIPE on this descriptor
        // only, so FileHandle reports EPIPE instead of terminating the app.
        guard fcntl(toServer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try process.run()
        let reader = Thread { [weak self] in self?.readLoop() }
        reader.name = "SFTP reader"
        reader.start()
        let errorReader = Thread { [weak self] in self?.readErrors() }
        errorReader.name = "SFTP stderr"
        errorReader.start()
        if connect { try self.connect() }
    }

    /// Says hello: waits (as long as logging in takes) for the server's answer. A failure ends the session.
    package func connect() throws {
        do {
            try hello()
            lock.withLock { isAnswering = true }
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    /// Ends the session (and the ssh process). Calls waiting for an answer fail.
    package func close() {
        lock.lock()
        let pending = waiting
        waiting.removeAll()
        if closedReason == nil { closedReason = "" }
        lock.unlock()
        pending.values.forEach { $0.done.signal() }
        try? toServer.close()
        if process.isRunning { process.terminate() }
    }

    package var isConnected: Bool {
        lock.withLock { closedReason == nil } && process.isRunning
    }

    // MARK: - Files and folders

    /// The absolute form of `path` ("." is the folder a login starts in).
    package func realPath(_ path: String) throws -> String {
        let reply = try request(.realpath) { $0.string(path) }
        guard reply.type == Packet.name.rawValue else { throw try failure(reply) }
        var reader = Reader(reply.body)
        guard try reader.uint32() >= 1 else { throw SFTPError.malformed }
        return try reader.text()
    }

    /// Everything in the folder at `path`, as the server lists it (not "." or "..").
    package func list(_ path: String) throws -> [SFTPEntry] {
        let handle = try openHandle(.opendir) { $0.string(path) }
        defer { closeHandle(handle) }
        var entries: [SFTPEntry] = []
        // A server answering with empty pages (or only "." and "..") forever is stopped, not followed.
        var emptyPages = 0
        var pages = 0
        while true {
            // However the pages come (one name each, or nothing), a listing ends.
            pages += 1
            if pages > 50_000 { throw SFTPError.malformed }
            let reply = try request(.readdir) { $0.bytes(handle) }
            if reply.type == Packet.status.rawValue {
                let (code, message) = try Self.status(reply.body)
                if code == SFTPError.eof { break }
                throw SFTPError.status(code, message)
            }
            guard reply.type == Packet.name.rawValue else { throw SFTPError.malformed }
            var reader = Reader(reply.body)
            let count = try reader.uint32()
            let before = entries.count
            defer {
                emptyPages = entries.count == before ? emptyPages + 1 : 0
            }
            for _ in 0..<count {
                let raw = try reader.bytes()
                _ = try reader.bytes() // the `ls -l` line, not used
                let attributes = try reader.attributes()
                // A name that isn't text can't be shown or asked for again; it's left out.
                guard let name = String(validating: raw, as: UTF8.self), name != ".", name != ".." else { continue }
                entries.append(SFTPEntry(name: name, attributes: attributes))
            }
            if entries.count > 1_000_000 || emptyPages > 100 { throw SFTPError.malformed }
        }
        return entries
    }

    package func stat(_ path: String) throws -> SFTPAttributes {
        try attributes(.stat, path)
    }

    package func lstat(_ path: String) throws -> SFTPAttributes {
        try attributes(.lstat, path)
    }

    package func readLink(_ path: String) throws -> String {
        let reply = try request(.readlink) { $0.string(path) }
        guard reply.type == Packet.name.rawValue else { throw try failure(reply) }
        var reader = Reader(reply.body)
        guard try reader.uint32() >= 1 else { throw SFTPError.malformed }
        return try reader.text()
    }

    package func makeFolder(_ path: String, permissions: UInt32 = 0o755) throws {
        try expectOK(request(.mkdir) { $0.string(path); $0.attributes(SFTPAttributes(permissions: permissions)) })
    }

    package func removeFolder(_ path: String) throws {
        try expectOK(request(.rmdir) { $0.string(path) })
    }

    package func removeFile(_ path: String) throws {
        try expectOK(request(.remove) { $0.string(path) })
    }

    /// Fails when something is already at `newPath` (SFTP's rename never replaces).
    package func rename(_ path: String, to newPath: String) throws {
        try expectOK(request(.rename) { $0.string(path); $0.string(newPath) })
    }

    /// Whether the server can replace an item in one step (`replace`).
    package var canReplace: Bool { extensions["posix-rename@openssh.com"] != nil }

    /// Renames `path` over whatever is at `newPath`, in one step (OpenSSH's posix-rename): a link there is replaced, never
    /// followed. Only when `canReplace`.
    package func replace(_ newPath: String, with path: String) throws {
        try expectOK(request(.extended) { $0.string("posix-rename@openssh.com"); $0.string(path); $0.string(newPath) })
    }

    package func setTimes(_ path: String, access: UInt32, modification: UInt32) throws {
        try expectOK(request(.setstat) { $0.string(path); $0.attributes(SFTPAttributes(accessTime: access, modificationTime: modification)) })
    }

    package func setPermissions(_ path: String, _ permissions: UInt32) throws {
        try expectOK(request(.setstat) { $0.string(path); $0.attributes(SFTPAttributes(permissions: permissions)) })
    }

    // MARK: - Transfers

    /// Copies the remote file at `path` into `destination` (made or emptied), several reads in flight. `progress` gets
    /// the bytes so far; `stop` is asked between chunks. More than `limit` bytes (the size it was listed with) is refused:
    /// a server can't fill the disk by sending without end.
    package func download(_ path: String, to destination: URL, limit: Int64 = .max, progress: (Int64) -> Void = { _ in },
                  stop: () -> Bool = { false }) throws {
        let handle = try openHandle(.open) { $0.string(path); $0.uint32(0x01); $0.attributes(SFTPAttributes()) } // READ
        defer { closeHandle(handle) }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let file = try? FileHandle(forWritingTo: destination) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? file.close() }
        var requested: UInt64 = 0
        var written: UInt64 = 0
        var inFlight: [(offset: UInt64, waiter: Waiter, id: UInt32)] = []
        var reachedEnd = false
        while true {
            while !reachedEnd, inFlight.count < Self.window {
                let offset = requested
                let (id, waiter) = try send(.read) { $0.bytes(handle); $0.uint64(offset); $0.uint32(UInt32(Self.chunk)) }
                inFlight.append((offset, waiter, id))
                requested += UInt64(Self.chunk)
            }
            guard !inFlight.isEmpty else { break }
            let next = inFlight.removeFirst()
            let reply = try wait(next.waiter, id: next.id)
            if stop() { throw SFTPError.stopped }
            if reply.type == Packet.status.rawValue {
                let (code, message) = try Self.status(reply.body)
                guard code == SFTPError.eof else { throw SFTPError.status(code, message) }
                reachedEnd = true
                continue
            }
            guard reply.type == Packet.data.rawValue else { throw SFTPError.malformed }
            var reader = Reader(reply.body)
            let data = try reader.bytes()
            guard !data.isEmpty else { throw SFTPError.malformed }
            guard next.offset == written else { continue } // past a short read: asked again below
            let (nextWritten, overflow) = Int64(clamping: written).addingReportingOverflow(Int64(data.count))
            guard !overflow, nextWritten <= limit else { throw SFTPError.tooLarge }
            try file.write(contentsOf: data)
            written += UInt64(data.count)
            progress(Int64(written))
            if data.count < Self.chunk, !reachedEnd {
                // A short read (not the end): the reads already sent assumed full chunks. Drop them, go on from here.
                for pending in inFlight { _ = try? wait(pending.waiter, id: pending.id) }
                inFlight.removeAll()
                requested = written
            }
        }
    }

    /// Copies the local file at `source` to `path` on the server (made, or replaced), several writes in flight, then
    /// gives it `modificationDate`.
    package func upload(_ source: URL, to path: String, permissions: UInt32 = 0o644, modificationDate: Date? = nil,
                progress: (Int64) -> Void = { _ in }, stop: () -> Bool = { false }) throws {
        // WRITE | CREAT | TRUNC
        let handle = try openHandle(.open) { $0.string(path); $0.uint32(0x02 | 0x08 | 0x10); $0.attributes(SFTPAttributes(permissions: permissions)) }
        var closed = false
        defer { if !closed { closeHandle(handle) } }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var offset: UInt64 = 0
        var inFlight: [(waiter: Waiter, id: UInt32)] = []
        var finished = false
        while true {
            while !finished, inFlight.count < Self.window {
                let data = try file.read(upToCount: Self.chunk) ?? Data()
                if data.isEmpty {
                    finished = true
                    break
                }
                let at = offset
                let (id, waiter) = try send(.write) { $0.bytes(handle); $0.uint64(at); $0.bytes([UInt8](data)) }
                inFlight.append((waiter, id))
                offset += UInt64(data.count)
            }
            guard !inFlight.isEmpty else { break }
            let next = inFlight.removeFirst()
            try expectOK(wait(next.waiter, id: next.id))
            if stop() {
                for pending in inFlight { _ = try? wait(pending.waiter, id: pending.id) }
                throw SFTPError.stopped
            }
            progress(max(0, Int64(offset) - Int64(inFlight.count * Self.chunk)))
        }
        progress(Int64(offset))
        closed = true
        try expectOK(request(.close) { $0.bytes(handle) })
        if let modificationDate {
            let raw = modificationDate.timeIntervalSince1970
            let seconds = raw.isFinite ? UInt32(clamping: Int64(min(max(raw, 0), Double(UInt32.max)))) : 0
            try? setTimes(path, access: seconds, modification: seconds)
        }
    }

    // MARK: - Protocol

    private func hello() throws {
        // VERSION has no request ID: it's the first thing back.
        let waiter = Waiter()
        lock.withLock { waiting[0] = waiter }
        var body = Writer()
        body.uint32(3)
        try write(type: Packet.`init`.rawValue, body: body.bytes)
        let reply = try wait(waiter, id: 0)
        guard reply.type == Packet.version.rawValue else { throw SFTPError.malformed }
        var reader = Reader(reply.body)
        guard try reader.uint32() >= 3 else { throw SFTPError.malformed }
        var announced: [String: String] = [:]
        while !reader.isAtEnd {
            let name = try reader.text()
            announced[name] = try reader.text()
        }
        extensions = announced
    }

    private func attributes(_ type: Packet, _ path: String) throws -> SFTPAttributes {
        let reply = try request(type) { $0.string(path) }
        guard reply.type == Packet.attrs.rawValue else { throw try failure(reply) }
        var reader = Reader(reply.body)
        return try reader.attributes()
    }

    private func openHandle(_ type: Packet, _ fill: (inout Writer) -> Void) throws -> [UInt8] {
        let reply = try request(type, fill)
        guard reply.type == Packet.handle.rawValue else { throw try failure(reply) }
        var reader = Reader(reply.body)
        let handle = try reader.bytes()
        guard handle.count <= 256 else { throw SFTPError.malformed }
        return handle
    }

    private func closeHandle(_ handle: [UInt8]) {
        _ = try? request(.close) { $0.bytes(handle) }
    }

    private func expectOK(_ reply: (type: UInt8, body: [UInt8])) throws {
        guard reply.type == Packet.status.rawValue else { throw SFTPError.malformed }
        let (code, message) = try Self.status(reply.body)
        guard code == 0 else { throw SFTPError.status(code, message) }
    }

    /// The error a reply stands for (a STATUS, or something unexpected).
    private func failure(_ reply: (type: UInt8, body: [UInt8])) throws -> SFTPError {
        guard reply.type == Packet.status.rawValue else { return .malformed }
        let (code, message) = try Self.status(reply.body)
        return .status(code, message)
    }

    private static func status(_ body: [UInt8]) throws -> (UInt32, String) {
        var reader = Reader(body)
        let code = try reader.uint32()
        let message = reader.isAtEnd ? "" : (try? reader.text()) ?? ""
        return (code, String(message.prefix(300)))
    }

    private func request(_ type: Packet, _ fill: (inout Writer) -> Void) throws -> (type: UInt8, body: [UInt8]) {
        let (id, waiter) = try send(type, fill)
        return try wait(waiter, id: id)
    }

    /// Sends a request; its answer comes to the returned waiter.
    private func send(_ type: Packet, _ fill: (inout Writer) -> Void) throws -> (UInt32, Waiter) {
        let waiter = Waiter()
        let id: UInt32 = try lock.withLock {
            if let reason = closedReason { throw SFTPError.disconnected(reason.isEmpty ? stderrText : reason) }
            let id = nextID
            nextID = nextID == UInt32.max ? 1 : nextID + 1
            waiting[id] = waiter
            return id
        }
        var body = Writer()
        body.uint32(id)
        fill(&body)
        do {
            try write(type: type.rawValue, body: body.bytes)
        } catch {
            _ = lock.withLock { waiting.removeValue(forKey: id) }
            throw SFTPError.disconnected(lock.withLock { stderrText })
        }
        return (id, waiter)
    }

    private func wait(_ waiter: Waiter, id: UInt32) throws -> (type: UInt8, body: [UInt8]) {
        let asked = ProcessInfo.processInfo.systemUptime
        let check = min(5, max(silenceLimit / 4, 0.05))
        while waiter.done.wait(timeout: .now() + check) == .timedOut {
            let stuck = lock.withLock {
                isAnswering && ProcessInfo.processInfo.systemUptime - max(lastHeard, asked) >= silenceLimit
            }
            if stuck {
                lock.withLock { stoppedAnswering = true }
                close()
            }
        }
        guard let reply = waiter.reply else {
            if lock.withLock({ stoppedAnswering }) { throw SFTPError.stoppedAnswering }
            let detail = lock.withLock { stderrText.isEmpty ? (closedReason ?? "") : stderrText }
            throw SFTPError.disconnected(detail)
        }
        return reply
    }

    /// Something came from the server.
    private func heard() {
        lock.withLock { lastHeard = ProcessInfo.processInfo.systemUptime }
    }

    /// The ssh (or server) process, for tests.
    package var processIdentifier: Int32 { process.processIdentifier }

    /// The writer must turn a closed ssh input into an error, never a process-wide SIGPIPE.
    package var suppressesBrokenPipeSignal: Bool { fcntl(toServer.fileDescriptor, F_GETNOSIGPIPE) == 1 }

    private func write(type: UInt8, body: [UInt8]) throws {
        var packet = Writer()
        packet.uint32(UInt32(body.count + 1))
        packet.byte(type)
        packet.raw(body)
        // Several threads may send at once: whole packets only.
        try writeLock.withLock { try toServer.write(contentsOf: Data(packet.bytes)) }
    }

    /// Answers, matched to their requests by ID, until the server goes away.
    private func readLoop() {
        let fd = fromServer.fileDescriptor
        while true {
            guard let header = Self.readExactly(fd, 4, heard: heard) else { break }
            let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
            guard length >= 1, length <= Self.maxPacket, let packet = Self.readExactly(fd, length, heard: heard) else { break }
            let type = packet[0]
            var body = Array(packet[1...])
            let id: UInt32
            if type == Packet.version.rawValue {
                id = 0
            } else {
                guard body.count >= 4 else { break }
                id = UInt32(body[0]) << 24 | UInt32(body[1]) << 16 | UInt32(body[2]) << 8 | UInt32(body[3])
                body.removeFirst(4)
            }
            let waiter = lock.withLock { waiting.removeValue(forKey: id) }
            waiter?.reply = (type, body)
            waiter?.done.signal()
        }
        lock.lock()
        if closedReason == nil { closedReason = "" }
        let pending = waiting
        waiting.removeAll()
        lock.unlock()
        pending.values.forEach { $0.done.signal() }
        // Garbled or gone: ssh goes too (it isn't left running with nothing reading it).
        if process.isRunning { process.terminate() }
    }

    /// What ssh prints (a login that failed, an unknown host…), kept short for messages.
    private func readErrors() {
        // close() ends ssh but leaves this owned read handle open until the reader finishes.
        let descriptor = errors.fileHandleForReading.fileDescriptor
        while true {
            guard let data = try? PipeRead.availableData(from: descriptor), !data.isEmpty else { break }
            let text = String(decoding: data, as: UTF8.self)
            lock.withLock {
                stderrText = String((stderrText + text).suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int, heard: () -> Void) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.read(fd, base + got, count - got)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            got += n
            heard()
        }
        return buffer
    }
}

// MARK: - Encoding

nonisolated private struct Writer {
    var bytes: [UInt8] = []

    mutating func byte(_ value: UInt8) { bytes.append(value) }

    mutating func uint32(_ value: UInt32) {
        bytes += [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    mutating func uint64(_ value: UInt64) {
        uint32(UInt32(value >> 32))
        uint32(UInt32(value & 0xffff_ffff))
    }

    mutating func raw(_ data: [UInt8]) { bytes += data }

    mutating func bytes(_ data: [UInt8]) {
        uint32(UInt32(data.count))
        bytes += data
    }

    mutating func string(_ text: String) { bytes(Array(text.utf8)) }

    mutating func attributes(_ attributes: SFTPAttributes) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= 0x1 }
        if attributes.uid != nil, attributes.gid != nil { flags |= 0x2 }
        if attributes.permissions != nil { flags |= 0x4 }
        if attributes.accessTime != nil, attributes.modificationTime != nil { flags |= 0x8 }
        uint32(flags)
        if let size = attributes.size { uint64(size) }
        if let uid = attributes.uid, let gid = attributes.gid { uint32(uid); uint32(gid) }
        if let permissions = attributes.permissions { uint32(permissions) }
        if let access = attributes.accessTime, let modification = attributes.modificationTime { uint32(access); uint32(modification) }
    }
}

nonisolated private struct Reader {
    private let data: [UInt8]
    private var position = 0

    init(_ data: [UInt8]) { self.data = data }

    var isAtEnd: Bool { position >= data.count }

    mutating func uint32() throws -> UInt32 {
        guard position + 4 <= data.count else { throw SFTPError.malformed }
        defer { position += 4 }
        return UInt32(data[position]) << 24 | UInt32(data[position + 1]) << 16 | UInt32(data[position + 2]) << 8 | UInt32(data[position + 3])
    }

    mutating func uint64() throws -> UInt64 {
        UInt64(try uint32()) << 32 | UInt64(try uint32())
    }

    mutating func bytes() throws -> [UInt8] {
        let count = Int(try uint32())
        guard count <= data.count - position else { throw SFTPError.malformed }
        defer { position += count }
        return Array(data[position..<(position + count)])
    }

    mutating func text() throws -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }

    mutating func attributes() throws -> SFTPAttributes {
        let flags = try uint32()
        var attributes = SFTPAttributes()
        if flags & 0x1 != 0 { attributes.size = try uint64() }
        if flags & 0x2 != 0 { attributes.uid = try uint32(); attributes.gid = try uint32() }
        if flags & 0x4 != 0 { attributes.permissions = try uint32() }
        if flags & 0x8 != 0 { attributes.accessTime = try uint32(); attributes.modificationTime = try uint32() }
        if flags & 0x8000_0000 != 0 {
            let count = try uint32()
            guard count <= 1000 else { throw SFTPError.malformed }
            for _ in 0..<count {
                _ = try bytes()
                _ = try bytes()
            }
        }
        return attributes
    }
}
