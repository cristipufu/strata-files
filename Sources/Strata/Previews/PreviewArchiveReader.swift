import Foundation
import os
import StrataArchiveClient
import StrataModel
import StrataSupport

nonisolated package enum PreviewArchiveError: Error, LocalizedError {
    case password, limit, unsafe, unreadable, encryption, needsExtraction
    package var errorDescription: String? {
        switch self {
        case .needsExtraction: String(localized: "Extract the archive first to preview or copy this item.")
        case .encryption: String(localized: "This archive’s encryption isn’t supported.")
        case .password: String(localized: "The archive password wasn’t accepted.")
        case .limit: String(localized: "This selection is too large to preview or copy here.")
        case .unsafe: String(localized: "This archive contains unsafe or ambiguous paths.")
        case .unreadable: String(localized: "This archive couldn’t be read.")
        }
    }
}

/// Pins the chosen archive before any password sheet or worker starts. Contents must stay unchanged too.
nonisolated package final class PreviewArchiveSource: Sendable {
    package let chosen: ChosenFile
    private let stamp: Stamp
    private struct Stamp: Equatable, Sendable {
        let identity: FileIdentity
        let size: Int64
        let modified: timespec
        let changed: timespec
        init(_ info: stat) {
            identity = .from(info); size = info.st_size; modified = info.st_mtimespec; changed = info.st_ctimespec
        }
        package static func == (a: Self, b: Self) -> Bool {
            a.identity == b.identity && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec
                && a.modified.tv_nsec == b.modified.tv_nsec && a.changed.tv_sec == b.changed.tv_sec
                && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }
    package var size: Int64 { stamp.size }

    package init(_ url: URL) throws {
        guard url.isFileURL else { throw PreviewArchiveError.unreadable }
        chosen = try ChosenFile(url)
        stamp = try chosen.withParent { _, _, info in
            guard info.st_mode & S_IFMT == S_IFREG else { throw PreviewArchiveError.unreadable }
            return Stamp(info)
        }
    }
    package func open() throws -> FileHandle {
        try chosen.withParent { parent, name, _ in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw PreviewArchiveError.unreadable }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Stamp(info) == stamp else {
                close(fd); throw POSIXError(.ESTALE)
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }
    package func verify(_ file: FileHandle) throws {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, Stamp(info) == stamp else { throw POSIXError(.ESTALE) }
        try chosen.withParent { _, _, current in
            guard Stamp(current) == stamp else { throw POSIXError(.ESTALE) }
        }
    }
}

nonisolated package struct PreviewArchiveRecord: Sendable {
    package let path: [String]
    package let kind: UInt8
    package let size: Int64
    package let modified: Date
    package let body: Data?
    package init(path: [String], kind: UInt8, size: Int64, modified: Date, body: Data?) {
        self.path = path; self.kind = kind; self.size = size; self.modified = modified; self.body = body
    }
}

/// The names of an archive's entries, as a tree of components: each is looked up once, so checking a path takes time in
/// proportion to its length however deep it is. A path listed twice, one name spelled two ways (a Unicode alias), and a
/// name that is both a file and a folder are refused before anything is written. A folder a deeper path implied may
/// still be listed itself, once.
nonisolated package struct ArchivePathNames {
    private struct Component: Hashable { let parent: Int; let name: String }
    private var components: [Component: Int] = [:], spellings: [Data] = [], types: [UInt8] = [], listed: [Bool] = []

    package init() {}

    /// Adds `parts`: the last of kind `kind` (2 for a folder), the rest folders.
    package mutating func add(_ parts: [String], kind: UInt8) throws {
        var parent = -1
        for (depth, part) in parts.enumerated() {
            let key = Component(parent: parent, name: part), last = depth == parts.count - 1
            let type: UInt8 = last ? kind : 2
            if let known = components[key] {
                guard spellings[known].elementsEqual(part.utf8), types[known] == type, !(last && listed[known]) else {
                    throw PreviewArchiveError.unsafe
                }
                if last { listed[known] = true }
                parent = known
            } else {
                guard spellings.count < 100_000 else { throw PreviewArchiveError.limit }
                parent = spellings.count
                components[key] = parent
                spellings.append(Data(part.utf8))
                types.append(type)
                listed.append(last)
            }
        }
    }
}

/// What a survey counted, for the check before Extract. Counts from one that didn't finish are lower bounds; `limited`
/// says it stopped at a limit (time, CPU, memory), which an archive too large to count in time meets.
nonisolated package struct PreviewArchiveSurvey: Sendable, Equatable {
    package var entries = 0
    package var bytes: Int64 = 0
    package var encrypted = false
    package var complete = false
    package var limited = false
    package init(entries: Int = 0, bytes: Int64 = 0, encrypted: Bool = false, complete: Bool = false,
                 limited: Bool = false) {
        self.entries = entries; self.bytes = bytes; self.encrypted = encrypted; self.complete = complete
        self.limited = limited
    }

    /// The size the archive holds at least: all of it when the survey finished, part of it when the survey ran into a
    /// limit. A survey stopped by damage may have counted a size the archive doesn't hold, so it says nothing.
    package var lowerBound: Int64? { complete || limited ? bytes : nil }
}

/// A listing of a whole archive. One cut short keeps what it read, and says why it stopped.
nonisolated package struct PreviewArchiveListing: Sendable {
    package enum End: Sendable, Equatable { case complete, moreEntries, stopped(PreviewArchiveError) }
    package let records: [PreviewArchiveRecord]
    package let end: End
    package init(records: [PreviewArchiveRecord], end: End) { self.records = records; self.end = end }
}

/// Parses only the worker's bounded, length-delimited protocol. Text command listings never authorize extraction.
nonisolated package enum PreviewArchiveReader {
    /// The most member data one selection reads.
    package static let memberLimit = ArchiveService.byteLimit
    /// Where a streamed file's contents go, a chunk at a time.
    package typealias Sink = (UnsafeRawBufferPointer) throws -> Void
    /// What a worker counts against a streamed file's limit besides its contents: its mark and the record's fields.
    package static let recordOverhead = 25
    private static let log = Logger(subsystem: "dev.strata.app", category: "archives")

    /// Where archives are read: the app's archive service, whose identity comes from its own bundle; outside an app,
    /// the harness; or nowhere, when the app lacks its service.
    package enum Route: Equatable { case service(String), harness, missingService }
    package static func route(for bundle: URL) -> Route {
        guard bundle.pathExtension == "app" else { return .harness }
        return ArchiveService.identifier(inApp: bundle).map(Route.service) ?? .missingService
    }
    private static let route = route(for: Bundle(for: PreviewArchiveBundle.self).bundleURL)

    /// Test and development builds aren't an app: they read through the host of an app built around the same service,
    /// among the build's products (beside the test bundle, or the folder of a bare executable).
    package static let harnessApp: URL = {
        let bundle = Bundle(for: PreviewArchiveBundle.self).bundleURL
        let products = bundle.pathExtension.isEmpty ? bundle : bundle.deletingLastPathComponent()
        return products.appending(path: "StrataArchiveHarness.app")
    }()
    package static let harness = harnessApp.appending(path: "Contents/MacOS/StrataArchiveHarness")

    @concurrent package static func read(_ source: PreviewArchiveSource, member: [String]? = nil, directory: Bool = false,
                                password: String? = nil) async throws -> [PreviewArchiveRecord] {
        let path = try requested(member ?? [], password: password)
        let request = ArchiveService.Request(mode: member != nil ? .extract : .list, folder: directory, path: path)
        let (output, status) = try await exchange(source, request, password: password, timeout: 20, allowance: .shared)
        if let error = error(for: status) { throw error }
        return try parse(output, member: member, directory: directory)
    }

    /// Copies one file out as it comes, never holding more of it than a chunk: once the worker has named it, `open` is
    /// told its size and says where its contents go. It returns once all of them have gone there.
    @concurrent package static func stream(_ source: PreviewArchiveSource, member: [String], password: String?,
                                           open: @escaping @Sendable (Int64) throws -> Sink) async throws {
        guard !member.isEmpty else { throw PreviewArchiveError.unsafe }
        let path = try requested(member, password: password)
        let request = ArchiveService.Request(mode: .stream, path: path)
            .encoded(password: ArchiveService.Secret(password ?? ""))
        // Copies have reads of their own, so a large one never holds up covers and pages.
        let (status, complete) = try await withRead(source, allowance: .copies) { archive in
            try await streamed(request, archive: archive, timeout: 20) { output, reader in
                try copy(output, reader: reader, path: path, open: open)
            }
        }
        if let error = error(for: status) { throw error }
        guard complete else { throw PreviewArchiveError.unreadable }
    }

    private static func requested(_ member: [String], password: String?) throws -> Data {
        let path = Data(member.joined(separator: "/").utf8)
        guard path.count <= 4096, (password?.utf8.count ?? 0) <= 1024, !path.contains(0),
              !(password?.utf8.contains(0) ?? false) else { throw PreviewArchiveError.limit }
        return path
    }

    /// Reads a worker's copy of the file at `path` from `output` as it comes, and says whether it was all of it, read
    /// to the end. Output that ends early is left to the read's status; output that goes on wrong is refused.
    package static func copy(_ output: Int32, reader: PipeReader, path: Data, open: (Int64) throws -> Sink) throws
        -> Bool {
        var file = StreamedFile(output, reader: reader)
        return try file.copy(path, open: open)
    }

    /// Lists the whole archive, keeping what a listing cut short by its limits, its time or an error read.
    @concurrent package static func list(_ source: PreviewArchiveSource, timeout: TimeInterval) async throws
        -> PreviewArchiveListing {
        let (output, status) = try await exchange(source, ArchiveService.Request(mode: .list), password: nil,
                                                  timeout: timeout, allowance: .listings)
        let decoded = try decode(output, member: nil, directory: false)
        guard let error = error(for: status) else { return decoded }
        return PreviewArchiveListing(records: decoded.records, end: .stopped(error))
    }

    /// Counts what the archive holds without listing it, for the check before Extract.
    @concurrent package static func survey(_ source: PreviewArchiveSource, timeout: TimeInterval) async throws
        -> PreviewArchiveSurvey {
        let (output, status) = try await exchange(source, ArchiveService.Request(mode: .survey), password: nil,
                                                  timeout: timeout, allowance: .surveys)
        var survey = decodeSurvey(output)
        let error = error(for: status)
        if error == .password { survey.encrypted = true }
        if error == .limit { survey.limited = true }
        return survey
    }

    /// The last snapshot of a survey's totals, complete only when the worker ended the stream itself.
    package static func decodeSurvey(_ data: Data) -> PreviewArchiveSurvey {
        let bytes = [UInt8](data)
        guard bytes.count <= ArchiveService.outputLimit, bytes.starts(with: Array("SAS1".utf8)) else {
            return PreviewArchiveSurvey()
        }
        func number(_ offset: Int) -> UInt64 { bigEndian(bytes[offset..<(offset + 8)]) }
        var survey = PreviewArchiveSurvey(), offset = 4
        while offset < bytes.count {
            if bytes[offset] == endMark, offset + 1 == bytes.count {
                survey.complete = true
                break
            }
            guard bytes[offset] == snapshotMark, bytes.count - offset >= 18 else { break }
            survey.entries = Int(clamping: number(offset + 1))
            survey.bytes = Int64(clamping: number(offset + 9))
            survey.encrypted = bytes[offset + 17] != 0
            offset += 18
        }
        return survey
    }

    private static func exchange(_ source: PreviewArchiveSource, _ request: ArchiveService.Request, password: String?,
                                 timeout: TimeInterval, allowance: ArchiveReadAllowance) async throws
        -> (Data, ArchiveService.Status) {
        try await withRead(source, allowance: allowance) { file in
            try await send(request, password: ArchiveService.Secret(password ?? ""), archive: file, timeout: timeout)
        }
    }

    /// One read in the archive service, pinned to `source` and counted against the reads `allowance` permits at once.
    private static func withRead<T>(_ source: PreviewArchiveSource, allowance: ArchiveReadAllowance,
                                    _ read: (FileHandle) async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await allowance.enter(id)
        } onCancel: { Task { await allowance.cancel(id) } }
        defer { Task { await allowance.leave() } }
        try Task.checkCancellation()
        do {
            let file = try source.open()
            defer { try? file.close() }
            let result = try await read(file)
            try Task.checkCancellation()
            try source.verify(file)
            return result
        } catch let error as POSIXError {
            // The archive is gone or changed while it was read (one still downloading does), or staging the read failed.
            log.info("An archive couldn't be read: \(error.localizedDescription, privacy: .public)")
            throw PreviewArchiveError.unreadable
        }
    }

    /// Extract's read, on the calling thread: the worker sends every entry of `archive` to `consume`, which reads the
    /// pipe it is given through `reader` (see `ArchiveWriter`). The read's status, once its worker has ended.
    package static func unpack(_ archive: FileHandle, reader: PipeReader, consume: (Int32) throws -> Void) throws
        -> ArchiveService.Status {
        let request = ArchiveService.Request(mode: .unpack).encoded(password: ArchiveService.Secret(""))
        return try routed(request, archive: archive, harness: ["--unpacking"], consume: consume) {
            try ArchiveService.unpack(encoded: request, to: $0, archive: archive, reader: reader, consume: consume)
        }
    }

    /// A copy of one file, read on a Dispatch queue since reading its pipe waits; cancelling the task stops it at once.
    /// The read's status once its worker has ended, and whether `consume` took the whole of its output.
    private static func streamed(_ request: ArchiveService.Secret, archive: FileHandle, timeout: TimeInterval,
                                 consume: @escaping @Sendable (Int32, PipeReader) throws -> Bool)
        async throws -> (ArchiveService.Status, Bool) {
        let reader = try PipeReader()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        var result = false
                        let milliseconds = String(Int((timeout * 1000).rounded()))
                        let status = try routed(request, archive: archive,
                                                harness: ["--streaming", "--timeout-ms", milliseconds],
                                                consume: { result = try consume($0, reader) }) {
                            try ArchiveService.stream(encoded: request, to: $0, archive: archive, timeout: timeout,
                                                      reader: reader) { result = try consume($0, reader) }
                        }
                        return (status, result)
                    })
                }
            }
        } onCancel: { reader.stop() }
    }

    /// A read whose output `consume` takes as it comes: through the app's service with `read`, or the harness with
    /// `harness` as its arguments.
    private static func routed(_ request: ArchiveService.Secret, archive: FileHandle, harness arguments: [String],
                               consume: (Int32) throws -> Void, read: (String) throws -> ArchiveService.Reply) throws
        -> ArchiveService.Status {
        switch route {
        case .service(let service):
            let reply = try read(service)
            if !reply.ended { log.error("The archive service didn't confirm that a stopped read's worker ended.") }
            return reply.outcome
        case .harness:
            try requireHarness()
            guard let input = try ArchiveService.requestPipe(request) else { return .limit }
            defer { try? input.close() }
            let status = try ProcessRunner.stream(harness.path, arguments, standardInput: input, file: archive,
                                                  consume: consume)
            return ArchiveService.Status(rawValue: status) ?? .unreadable
        case .missingService:
            log.error("The app has no archive service (Contents/XPCServices/StrataArchiveService.xpc).")
            throw PreviewArchiveError.unreadable
        }
    }

    package static func error(for status: ArchiveService.Status) -> PreviewArchiveError? {
        switch status {
        case .success: return nil
        case .password: return .password
        case .limit: return .limit
        case .unsafe: return .unsafe
        case .encryption: return .encryption
        case .needsExtraction: return .needsExtraction
        case .unsandboxed:
            log.error("Archive reads were refused as unconfined: check the App Sandbox entitlements and the bootstrap port drop.")
            return .unreadable
        case .unreadable, .missing, .stopped: return .unreadable
        }
    }

    private static func send(_ request: ArchiveService.Request, password: ArchiveService.Secret, archive: FileHandle,
                             timeout: TimeInterval) async throws -> (Data, ArchiveService.Status) {
        switch route {
        case .service(let service):
            let reply = try await ArchiveService.send(request, password: password, to: service, archive: archive,
                                                      timeout: timeout)
            if !reply.ended { log.error("The archive service didn't confirm that a stopped read's worker ended.") }
            return (reply.output, reply.outcome)
        case .harness:
            return try await sendThroughHarness(request, password: password, archive: archive, timeout: timeout)
        case .missingService:
            log.error("The app has no archive service (Contents/XPCServices/StrataArchiveService.xpc).")
            throw PreviewArchiveError.unreadable
        }
    }

    private static func sendThroughHarness(_ request: ArchiveService.Request, password: ArchiveService.Secret,
                                           archive: FileHandle, timeout: TimeInterval) async throws
        -> (Data, ArchiveService.Status) {
        try requireHarness()
        guard let input = try ArchiveService.requestPipe(request.encoded(password: password)) else {
            return (Data(), .limit)
        }
        defer { try? input.close() }
        // Room for the harness's own read and its wait for the service to end the worker.
        let run = try await ProcessRunner.run(harness.path, ["--timeout-ms", String(Int((timeout * 1000).rounded()))],
                                              timeout: timeout + ArchiveService.answerBackstop + 5,
                                              standardInput: input, file: archive)
        if run.failed { return (run.output, .unreadable) }
        let reply = ArchiveService.Reply(output: run.output, status: run.status, timedOut: run.timedOut,
                                         truncated: run.truncated || run.output.count > ArchiveService.outputLimit)
        return (reply.output, reply.outcome)
    }

    private static func requireHarness() throws {
        guard FileManager.default.isExecutableFile(atPath: harness.path) else {
            log.error("Outside the app, archives are read through \(harness.path, privacy: .public), which the archive tests build.")
            throw PreviewArchiveError.unreadable
        }
    }

    /// The worker's records, in a stream it ended or not: what was decoded before the stream ended, or turned out
    /// unsafe, is kept.
    package static func decode(_ data: Data, member: [String]?, directory: Bool) throws -> PreviewArchiveListing {
        var records: [PreviewArchiveRecord] = []
        do {
            let end = try decode(data, member: member, directory: directory, into: &records)
            return PreviewArchiveListing(records: records, end: end)
        } catch let error as PreviewArchiveError {
            return PreviewArchiveListing(records: records, end: .stopped(error))
        }
    }

    /// The strict form, for a read that must be complete.
    package static func parse(_ data: Data, member: [String]?, directory: Bool) throws -> [PreviewArchiveRecord] {
        let decoded = try decode(data, member: member, directory: directory)
        switch decoded.end {
        case .complete: return decoded.records
        case .moreEntries: throw PreviewArchiveError.limit
        case .stopped(let error): throw error
        }
    }

    fileprivate static func bigEndian(_ bytes: some Collection<UInt8>) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// The modification times a copy takes: years 1 to 9999.
    fileprivate static let years: ClosedRange<Int64> = -62_135_596_800...253_402_300_799

    /// The worker's marks (CArchivePreview.h).
    package static let endMark: UInt8 = 0, moreMark: UInt8 = 4, snapshotMark: UInt8 = 0x53

    private static func decode(_ data: Data, member: [String]?, directory: Bool,
                               into records: inout [PreviewArchiveRecord]) throws -> PreviewArchiveListing.End {
        guard data.count <= ArchiveService.outputLimit, data.starts(with: Data("SAP1".utf8)) else {
            throw PreviewArchiveError.unreadable
        }
        var offset = 4
        var names = ArchivePathNames()
        func number(_ count: Int) throws -> UInt64 {
            guard count <= data.count - offset else { throw PreviewArchiveError.unreadable }
            defer { offset += count }
            return bigEndian(data[offset..<(offset+count)])
        }
        while offset < data.count {
            try Task.checkCancellation()
            let mark = try number(1)
            if mark == UInt64(endMark) || mark == UInt64(moreMark) {
                guard offset == data.count, member == nil || (mark == UInt64(endMark) && !records.isEmpty) else {
                    throw PreviewArchiveError.unreadable
                }
                return mark == UInt64(endMark) ? .complete : .moreEntries
            }
            let kind = mark
            guard (1...3).contains(kind), records.count < 50_000 else { throw PreviewArchiveError.limit }
            let count = try number(4), size = try number(8), seconds = Int64(bitPattern: try number(8))
            guard (1...4096).contains(count), count <= data.count - offset, size <= Int64.max else { throw PreviewArchiveError.limit }
            // Years 1 to 9999. A listing shows an odd date at the nearest end; a copy refuses it.
            guard member == nil || Self.years.contains(seconds) else { throw PreviewArchiveError.unreadable }
            let shown = min(max(seconds, Self.years.lowerBound), Self.years.upperBound)
            let modified = Date(timeIntervalSince1970: Double(shown))
            let bytes = data.subdata(in: offset..<(offset+Int(count)))
            offset += Int(count)
            guard let path = String(data: bytes, encoding: .utf8), !path.hasPrefix("/"), !path.hasSuffix("/"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\\" }) else {
                throw PreviewArchiveError.unsafe
            }
            let parts = path.components(separatedBy: "/")
            guard parts.count <= 128, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
                throw PreviewArchiveError.unsafe
            }
            try names.add(parts, kind: UInt8(kind))
            var body: Data?
            if let member {
                let chosen = parts.count >= member.count && zip(parts, member).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
                guard chosen, directory || parts.count == member.count, kind != 3,
                      size <= data.count - offset else { throw PreviewArchiveError.unsafe }
                if kind == 1 {
                    body = data.subdata(in: offset..<(offset+Int(size)))
                    offset += Int(size)
                }
            }
            records.append(PreviewArchiveRecord(path: parts, kind: UInt8(kind), size: Int64(size),
                                                modified: modified, body: body))
        }
        throw PreviewArchiveError.unreadable
    }
}

nonisolated private struct StreamedFile {
    private let output: Int32
    private let reader: PipeReader
    private var buffered: [UInt8] = []
    private var chunk = [UInt8](repeating: 0, count: 1 << 16)

    init(_ output: Int32, reader: PipeReader) {
        self.output = output
        self.reader = reader
    }

    mutating func copy(_ path: Data, open: (Int64) throws -> PreviewArchiveReader.Sink) throws -> Bool {
        guard let magic = try take(4) else { return false }
        guard magic.elementsEqual("SAP1".utf8) else { throw PreviewArchiveError.unreadable }
        guard let record = try take(21) else { return false }
        guard record[0] == 1 else { throw record[0] == 3 ? PreviewArchiveError.unsafe : PreviewArchiveError.unreadable }
        let length = PreviewArchiveReader.bigEndian(record[1..<5])
        let size = PreviewArchiveReader.bigEndian(record[5..<13])
        let seconds = Int64(bitPattern: PreviewArchiveReader.bigEndian(record[13..<21]))
        guard length == UInt64(path.count) else { throw PreviewArchiveError.unsafe }
        let overhead = PreviewArchiveReader.recordOverhead + path.count
        guard size <= UInt64(ArchiveService.fileLimit - overhead) else { throw PreviewArchiveError.limit }
        guard PreviewArchiveReader.years.contains(seconds) else { throw PreviewArchiveError.unreadable }
        guard let name = try take(path.count) else { return false }
        guard name.elementsEqual(path) else { throw PreviewArchiveError.unsafe }
        guard try forward(size, to: try open(Int64(size))) else { return false }
        guard let mark = try take(1) else { return false }
        // Another record is the same path listed twice.
        guard mark[0] == PreviewArchiveReader.endMark else {
            throw (1...3).contains(mark[0]) ? PreviewArchiveError.unsafe : PreviewArchiveError.unreadable
        }
        guard try take(1) == nil else { throw PreviewArchiveError.unreadable }
        return true
    }

    /// The next `count` bytes, or nil when the output ends first.
    private mutating func take(_ count: Int) throws -> [UInt8]? {
        while buffered.count < count {
            guard try read() else { return nil }
        }
        defer { buffered.removeFirst(count) }
        return Array(buffered.prefix(count))
    }

    /// Hands the next `size` bytes to `sink`, straight from each read once what came with the record is passed on;
    /// false when the output ends first.
    private mutating func forward(_ size: UInt64, to sink: PreviewArchiveReader.Sink) throws -> Bool {
        var remaining = size
        let early = Int(min(UInt64(buffered.count), remaining))
        try buffered.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[..<early])) }
        buffered.removeFirst(early)
        remaining -= UInt64(early)
        while remaining > 0 {
            let count = try chunk.withUnsafeMutableBytes { try reader.readSome(output, into: $0) }
            guard count > 0 else { return false }
            let used = Int(min(UInt64(count), remaining))
            try chunk.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[..<used])) }
            buffered.append(contentsOf: chunk[used..<count])
            remaining -= UInt64(used)
        }
        return true
    }

    /// Reads what has come; false once the output has ended.
    private mutating func read() throws -> Bool {
        let count = try chunk.withUnsafeMutableBytes { try reader.readSome(output, into: $0) }
        buffered.append(contentsOf: chunk[..<count])
        return count > 0
    }
}

/// Tells the shipping app, whose service is in its bundle, from a test or development build.
nonisolated private final class PreviewArchiveBundle: NSObject {}
