import Foundation
import XPC

/// Sends one read to Strata's archive service, an XPC service with an App Sandbox of its own, and collects its bounded
/// output. The service starts a worker for each read, which inherits that sandbox and exits with the read's status. The
/// request (with the password), the archive and the output each travel as a descriptor, so neither the service nor the
/// worker opens a file and the password never sits in a message.
nonisolated package enum ArchiveService {
    /// The statuses of the service and its workers (CArchiveSandbox.h).
    package enum Status: Int32, Sendable {
        case success = 0, password = 40, limit, unsafe, unreadable, missing, encryption, needsExtraction, unsandboxed, stopped
    }

    /// The most a worker writes before its end mark: records and contents (CArchivePreview.h).
    package static let byteLimit = 60 << 20
    /// The most a worker writes: its records and contents, and the end mark.
    package static let outputLimit = byteLimit + 1
    /// The longest a read waits for the service's answer. A live service answers as soon as its worker is gone, at the
    /// latest at its own deadline, and one that went away answers at once: this only bounds a service that stopped
    /// answering without going away.
    package static let answerBackstop: TimeInterval = 60

    package static let requestLimit = 8192
    /// For Extract: the most bytes in one chunk of contents, and in one entry's Mac metadata (CArchivePreview.h).
    package static let chunkLimit = 65536
    package static let metadataLimit = 64 << 20

    /// The identifier of the archive service inside the app at `app`; nil when the app has none.
    package static func identifier(inApp app: URL) -> String? {
        Bundle(url: app.appending(path: "Contents/XPCServices/StrataArchiveService.xpc"))?.bundleIdentifier
    }

    /// A password, or a request holding one, in memory of its own, wiped when the last reference to it goes: a copy of a
    /// `Data` could outlive its wipe.
    package final class Secret: @unchecked Sendable {
        fileprivate let bytes: UnsafeMutableRawBufferPointer

        package convenience init(_ text: String) { self.init(text.utf8) }

        package init(_ source: some Collection<UInt8>) {
            bytes = .allocate(byteCount: source.count, alignment: 1)
            bytes.copyBytes(from: source)
        }

        fileprivate init(count: Int, filling fill: (UnsafeMutableRawBufferPointer) -> Void) {
            bytes = .allocate(byteCount: count, alignment: 1)
            fill(bytes)
        }

        package var count: Int { bytes.count }

        package func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
            try body(UnsafeRawBufferPointer(bytes))
        }

        deinit {
            if let base = bytes.baseAddress { memset_s(base, bytes.count, 0, bytes.count) }
            bytes.deallocate()
        }
    }

    /// Lower limits than the worker's own, which it never raises; nil keeps the worker's. Even a tiny or negative limit
    /// stays a limit.
    package struct Limits: Sendable {
        package let cpu: Duration?
        package let memory: Int?

        package init(cpu: Duration? = nil, memory: Int? = nil) { self.cpu = cpu; self.memory = memory }

        /// Longer than any worker allows, a limit only has to stay representable.
        fileprivate var cpuMicroseconds: UInt64? {
            cpu.map { limit in
                guard limit > .zero else { return 1 }
                let (seconds, attoseconds) = limit.components
                let whole = min(UInt64(clamping: seconds), UInt64.max / 1_000_000 - 1)
                return max(1, whole * 1_000_000 + UInt64(clamping: attoseconds) / 1_000_000_000_000)
            }
        }

        fileprivate var memoryBytes: UInt64? { memory.map { UInt64(clamping: max(1, $0)) } }
    }

    package struct Request: Sendable {
        /// What a worker does (CArchivePreview.h): list every entry, copy out the chosen path, only count, or send
        /// everything for Extract to write.
        package enum Mode: UInt8, Sendable { case list = 0, extract = 1, survey = 2, unpack = 3 }
        package let mode: Mode
        package let folder: Bool
        package let path: Data

        package init(mode: Mode, folder: Bool = false, path: Data = Data()) {
            self.mode = mode; self.folder = folder; self.path = path
        }

        /// The request as a worker reads it on standard input:
        /// [mode, folder, path length (4 bytes), password length (4 bytes), path, password]. It holds the
        /// password, so it is a `Secret` too.
        package func encoded(password: Secret) -> Secret {
            Secret(count: 10 + path.count + password.count) { buffer in
                buffer[0] = mode.rawValue
                buffer[1] = folder ? 1 : 0
                for (offset, count) in [(2, path.count), (6, password.count)] {
                    for index in 0..<4 { buffer[offset + index] = UInt8(truncatingIfNeeded: count >> (8 * (3 - index))) }
                }
                UnsafeMutableRawBufferPointer(rebasing: buffer[10..<(10 + path.count)]).copyBytes(from: path)
                password.withBytes { UnsafeMutableRawBufferPointer(rebasing: buffer[(10 + path.count)...]).copyMemory(from: $0) }
            }
        }
    }

    package struct Reply: Sendable {
        package let output: Data
        /// The read's status; nil when the service couldn't be reached or ended before replying, or the read didn't finish.
        package let status: Int32?
        /// What the service answered, even for a read that didn't finish: why it ended the worker.
        package let serviceStatus: Int32?
        package let timedOut: Bool
        package let truncated: Bool
        /// Whether the service confirmed that the read's worker is gone; one it never answered may run on until the
        /// service's own deadline.
        package let ended: Bool

        package init(output: Data, status: Int32?, timedOut: Bool, truncated: Bool, ended: Bool = true,
                     serviceStatus: Int32? = nil) {
            self.output = output; self.status = status; self.timedOut = timedOut; self.truncated = truncated
            self.ended = ended; self.serviceStatus = serviceStatus ?? status
        }

        /// A read stopped by the timeout or the output limit is over a limit; one the service never answered, or
        /// answered with a status this client doesn't know, couldn't be read.
        package var outcome: Status {
            if timedOut || truncated { return .limit }
            return status.flatMap(Status.init(rawValue:)) ?? .unreadable
        }
    }

    /// Cancelling the task, the timeout and output past `outputLimit` all stop reading at once and cancel the request,
    /// which ends its worker.
    package static func send(_ request: Request, password: Secret, to service: String, archive: FileHandle,
                             timeout: TimeInterval, outputLimit: Int = outputLimit) async throws -> Reply {
        try await send(encoded: request.encoded(password: password), to: service, archive: archive, timeout: timeout,
                       outputLimit: outputLimit)
    }

    /// A request already encoded, passed to the worker as it is: the worker validates it. Only a request over
    /// `requestLimit` is refused here, as over the limit; the worker's own bounds are far below it.
    package static func send(encoded request: Secret, limits: Limits = Limits(), to service: String, archive: FileHandle,
                             timeout: TimeInterval, outputLimit: Int = outputLimit) async throws -> Reply {
        let exchange = Exchange(output: try PipeReader())
        let reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try exchange.run(request, limits: limits, service: service, archive: archive,
                                         timeout: timeout, outputLimit: outputLimit)
                    })
                }
            }
        } onCancel: {
            exchange.stop()
        }
        try Task.checkCancellation()
        return reply
    }

    /// Extract's read, on the calling thread, with no timeout or output limit: `consume` reads the worker's output as it
    /// comes, from the pipe it is given, through `reader`, whose `stop()` stops it at once. A `consume` that throws stops
    /// the read, and its error is rethrown once the service has ended the worker.
    package static func unpack(encoded request: Secret, limits: Limits = Limits(), to service: String,
                               archive: FileHandle, reader: PipeReader, consume: (Int32) throws -> Void) throws -> Reply {
        try Exchange(output: reader).run(request, limits: limits, unpacking: true, service: service, archive: archive) {
            try consume($0)
            return (Data(), .finished)
        }
    }

    private final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false
        private var answer: Answer?
        private let output: PipeReader
        private let replied = DispatchSemaphore(value: 0)

        init(output: PipeReader) { self.output = output }

        func stop() { output.stop() }

        func run(_ request: Secret, limits: Limits, service: String, archive: FileHandle, timeout: TimeInterval,
                 outputLimit: Int) throws -> Reply {
            try run(request, limits: limits, unpacking: false, service: service, archive: archive) { fd in
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    lock.withLock { expired = true }
                    output.stop()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                defer { deadline.cancel() }
                return output.read(fd, limit: outputLimit)
            }
        }

        /// `read` reads the output pipe it is given and says how its output ended; one that throws stops the read.
        func run(_ request: Secret, limits: Limits, unpacking: Bool, service: String, archive: FileHandle,
                 read: (Int32) throws -> (Data, Pipes.Ending)) throws -> Reply {
            guard !output.isStopped else { throw CancellationError() }
            guard let requestPipe = try ArchiveService.requestPipe(request) else {
                return Reply(output: Data(), status: Status.limit.rawValue, timedOut: false, truncated: false)
            }
            let pipe = try Pipes.make()
            defer { close(pipe.read) }
            let connection = xpc_connection_create(service, nil)
            xpc_connection_set_event_handler(connection) { _ in }
            xpc_connection_activate(connection)
            defer { xpc_connection_cancel(connection) }
            send(limits, unpacking: unpacking, archive: archive, requestPipe: requestPipe, output: pipe.write,
                 on: connection) { [self] answer in
                lock.withLock { self.answer = answer }
                replied.signal()
            }
            try? requestPipe.close()
            close(pipe.write)
            let result = Result { try read(pipe.read) }
            let ending = (try? result.get())?.1 ?? .stopped
            // A worker that closed its output has exited; any other the service ends now. The read ends only with the
            // service's answer, which follows the worker's end, so a stopped read never leaves a worker running.
            if ending != .finished { xpc_connection_send_message(connection, xpc_dictionary_create_empty()) }
            _ = replied.wait(timeout: .now() + ArchiveService.answerBackstop)
            let data = try result.get().0
            return lock.withLock {
                let answered: Int32? = if case .replied(let status) = answer { status } else { nil }
                return Reply(output: data, status: ending == .finished ? answered : nil, timedOut: ending == .stopped && expired,
                             truncated: ending == .truncated, ended: workerEnded(ending), serviceStatus: answered)
            }
        }

        /// A service that answered, or was never reached, leaves no worker; one that went away leaves none only if the
        /// worker had already closed its output, which it does as it exits.
        private func workerEnded(_ ending: Pipes.Ending) -> Bool {
            switch answer {
            case .replied, .unreachable: true
            case .lost: ending == .finished
            case nil: false
            }
        }

        /// What the service's reply says about its worker. A service never reached started none; one that went away
        /// before answering may have left one running until its own limits end it.
        private enum Answer { case replied(Int32?), unreachable, lost }

        /// The message, and with it its copies of the descriptors, is released once sent.
        private func send(_ limits: Limits, unpacking: Bool, archive: FileHandle, requestPipe: FileHandle, output: Int32,
                          on connection: xpc_connection_t, reply: @escaping @Sendable (Answer) -> Void) {
            let message = xpc_dictionary_create_empty()
            if let cpu = limits.cpuMicroseconds { xpc_dictionary_set_uint64(message, "cpuLimit", cpu) }
            if let memory = limits.memoryBytes { xpc_dictionary_set_uint64(message, "memoryLimit", memory) }
            if unpacking { xpc_dictionary_set_bool(message, "unpacking", true) }
            xpc_dictionary_set_fd(message, "request", requestPipe.fileDescriptor)
            xpc_dictionary_set_fd(message, "archive", archive.fileDescriptor)
            xpc_dictionary_set_fd(message, "output", output)
            xpc_connection_send_message_with_reply(connection, message, nil) { answer in
                if xpc_get_type(answer) == XPC_TYPE_DICTIONARY { reply(.replied(Self.status(in: answer))) }
                else { reply(answer === XPC_ERROR_CONNECTION_INVALID ? .unreachable : .lost) }
            }
        }

        /// Only a status the reply actually carries, as an integer that fits: a missing key would read as 0, success.
        private static func status(in answer: xpc_object_t) -> Int32? {
            guard let value = xpc_dictionary_get_value(answer, "status"), xpc_get_type(value) == XPC_TYPE_INT64 else {
                return nil
            }
            return Int32(exactly: xpc_int64_get_value(value))
        }
    }

    /// A pipe already holding `request` and closed for writing: its read end, or nil for a request over
    /// `requestLimit`. No reader exists yet, so the write never waits: one the pipe can't take at once fails.
    package static func requestPipe(_ request: Secret) throws -> FileHandle? {
        guard request.count <= requestLimit else { return nil }
        let ends = try Pipes.make(nonblockingWriter: true)
        defer { close(ends.write) }
        let written = request.withBytes { Darwin.write(ends.write, $0.baseAddress, $0.count) }
        guard written == request.count else {
            close(ends.read)
            throw POSIXError(.EIO)
        }
        return FileHandle(fileDescriptor: ends.read, closeOnDealloc: true)
    }
}
