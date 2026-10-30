import Foundation
import StrataArchiveClient

// Test and development builds aren't an app, so they can't reach the archive service, which only an app can carry.
// They run this host inside `StrataArchiveHarness.app`, built around the same service: the request on standard input,
// passed to the worker as it is (the worker validates it), the archive on descriptor 3, the output on standard output,
// and the outcome as the exit status: "couldn't be read" when the service didn't confirm the worker ended. Tests may
// lower the worker's limits (--cpu-limit microseconds, --memory-limit bytes), the output limit (--output-limit bytes)
// and the read's timeout (--timeout-ms), send the request once more without them after the first (--then-plain: the
// output and status are then the second's), and exit with the service's own answer instead (--service-status).
// Extract's read (--unpacking) has no timeout or output limit, and its output goes out as it comes; so does a preview's
// copy of one file (--streaming), within its timeout.

func option(_ name: String) -> Int? {
    let arguments = CommandLine.arguments
    return arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
}

/// At most one byte past the limit, so that a longer request is still refused as over it. The request holds the
/// password: it is read into memory that is wiped once copied into its `Secret`.
func readRequest() throws -> ArchiveService.Secret {
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: ArchiveService.requestLimit + 1, alignment: 1)
    defer {
        memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
        buffer.deallocate()
    }
    var count = 0
    while count < buffer.count {
        let read = Darwin.read(STDIN_FILENO, buffer.baseAddress! + count, buffer.count - count)
        if read < 0 && errno == EINTR { continue }
        guard read >= 0 else { throw POSIXError(.EIO) }
        if read == 0 { break }
        count += read
    }
    return ArchiveService.Secret(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
}

func forward(_ output: Int32, through reader: PipeReader) throws {
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let count = try buffer.withUnsafeMutableBytes { try reader.readSome(output, into: $0) }
        if count == 0 { return }
        try FileHandle.standardOutput.write(contentsOf: buffer[..<count])
    }
}

func run() async -> Int32 {
    guard let service = ArchiveService.identifier(inApp: Bundle.main.bundleURL), let request = try? readRequest() else { return ArchiveService.Status.unreadable.rawValue }
    let archive = FileHandle(fileDescriptor: 3, closeOnDealloc: false)
    func send(_ limits: ArchiveService.Limits, outputLimit: Int?, timeout: TimeInterval = 20) async throws
        -> ArchiveService.Reply {
        guard lseek(3, 0, SEEK_SET) == 0 else { throw POSIXError(.EIO) }
        return try await ArchiveService.send(encoded: request, limits: limits, to: service, archive: archive,
                                             timeout: timeout, outputLimit: outputLimit ?? ArchiveService.outputLimit)
    }
    do {
        let limits = ArchiveService.Limits(cpu: option("--cpu-limit").map { .microseconds($0) },
                                           memory: option("--memory-limit"))
        let timeout = option("--timeout-ms").map { TimeInterval($0) / 1000 } ?? 20
        /// A read whose output goes out as it comes. A reader that stops reading ends the read, not the harness.
        func passOn(_ read: (PipeReader) throws -> ArchiveService.Reply) throws -> Int32 {
            guard fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
            let reader = try PipeReader()
            let reply = try read(reader)
            return (reply.ended ? reply.outcome : .unreadable).rawValue
        }
        if CommandLine.arguments.contains("--unpacking") {
            return try passOn { reader in
                try ArchiveService.unpack(encoded: request, limits: limits, to: service, archive: archive,
                                          reader: reader) { try forward($0, through: reader) }
            }
        }
        if CommandLine.arguments.contains("--streaming") {
            return try passOn { reader in
                try ArchiveService.stream(encoded: request, limits: limits, to: service, archive: archive,
                                          timeout: timeout, reader: reader) { try forward($0, through: reader) }
            }
        }
        var reply = try await send(limits, outputLimit: option("--output-limit"), timeout: timeout)
        if CommandLine.arguments.contains("--then-plain") { reply = try await send(ArchiveService.Limits(), outputLimit: nil) }
        try FileHandle.standardOutput.write(contentsOf: reply.output)
        if CommandLine.arguments.contains("--service-status") {
            return reply.serviceStatus ?? ArchiveService.Status.unreadable.rawValue
        }
        return (reply.ended ? reply.outcome : .unreadable).rawValue
    } catch {
        return ArchiveService.Status.unreadable.rawValue
    }
}

exit(await run())
