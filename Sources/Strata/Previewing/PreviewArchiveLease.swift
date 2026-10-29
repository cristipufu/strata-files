import Foundation

/// One private, complete materialization. Cleanup knows only the identities created by this receipt.
/// Clipboard exports relinquish cleanup after publication, matching the existing next-launch staging lifetime.
nonisolated final class PreviewArchiveLease: @unchecked Sendable {
    static let cacheLimit: Int64 = 128 << 20
    private static let buildLock = NSLock()
    let url: URL
    let root: URL
    private let parentFD: Int32
    private let rootFD: Int32
    private let rootIdentity: FileIdentity
    private var receipts: [String: (identity: FileIdentity, directory: Bool)] = [:]
    private let lock = NSLock()
    private var retainedForClipboard = false

    private init(base: URL, name: String) throws {
        parentFD = try Self.prepare(base)
        let rootName = UUID().uuidString
        root = base.appendingPathComponent(rootName, isDirectory: true)
        url = root.appendingPathComponent(name)
        guard mkdirat(parentFD, rootName, 0o700) == 0 else { close(parentFD); throw POSIXError(.EIO) }
        rootFD = openat(parentFD, rootName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard rootFD >= 0, fstat(rootFD, &info) == 0 else {
            if rootFD >= 0 { close(rootFD) }
            // Without a captured identity cleanup must leave this name alone.
            close(parentFD); throw POSIXError(.EIO)
        }
        rootIdentity = .from(info)
        // Drop inherited access grants as well as archive metadata. Only this newly made scratch root changes.
        guard let empty = acl_init(0) else { throw POSIXError(.ENOMEM) }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(rootFD, empty, ACL_TYPE_EXTENDED) != 0, errno != ENOTSUP { throw POSIXError(.EIO) }
    }

    deinit {
        if !lock.withLock({ retainedForClipboard }) { clean() }
        close(rootFD)
        close(parentFD)
    }

    func keepForClipboard() { lock.withLock { retainedForClipboard = true } }

    @concurrent static func materialize(_ records: [PreviewArchiveRecord], member: [String], in base: URL,
                                       source: PreviewArchiveSource, preview: Bool) async throws -> PreviewArchiveLease {
        try buildLock.withLock { try build(records, member: member, in: base, source: source, preview: preview) }
    }

    private static func build(_ records: [PreviewArchiveRecord], member: [String], in base: URL,
                              source: PreviewArchiveSource, preview: Bool) throws -> PreviewArchiveLease {
        try validate(records, member: member)
        guard let name = member.last, !records.isEmpty else { throw PreviewArchiveError.unreadable }
        if preview {
            guard records.count == 1, records[0].kind == 1, records[0].size <= PreviewArchiveReader.previewLimit else { throw PreviewArchiveError.limit }
        }
        let file = try source.open()
        defer { try? file.close() }
        let quarantine = try quarantine(file.fileDescriptor)
        if preview {
            let baseFD = try prepare(base)
            defer { close(baseFD) }
            var remaining = 100_000
            let existing = try cacheBytes(baseFD, depth: 0, remaining: &remaining)
            guard existing <= cacheLimit - records[0].size else { throw PreviewArchiveError.limit }
        }
        let lease = try PreviewArchiveLease(base: base, name: name)
        for record in records {
            try Task.checkCancellation()
            let parts = Array(record.path.dropFirst(member.count-1))
            guard !parts.isEmpty, parts.first?.utf8.elementsEqual(name.utf8) == true else { throw PreviewArchiveError.unsafe }
            if record.kind == 2 { try lease.makeFolders(parts, quarantine: quarantine) }
            else {
                guard record.kind == 1, let body = record.body, body.count == record.size else { throw PreviewArchiveError.unreadable }
                try lease.makeFolders(Array(parts.dropLast()), quarantine: quarantine)
                try lease.write(body, path: parts, quarantine: quarantine)
            }
        }
        try Task.checkCancellation()
        try source.verify(file)
        try lease.verify()
        return lease
    }

    /// Refuse the entire batch before making anything, including aliases and a later unsafe child.
    static func validate(_ records: [PreviewArchiveRecord], member: [String]) throws {
        func safe(_ parts: [String]) -> Bool {
            !parts.isEmpty && parts.count <= 128 && parts.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
                    && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == "\\" }
            }
        }
        guard safe(member), !records.isEmpty, records.count <= 50_000 else { throw PreviewArchiveError.unsafe }
        var total = 0, names = ArchivePathNames()
        for record in records {
            guard safe(record.path), record.path.count >= member.count,
                  zip(record.path, member).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }),
                  record.kind == 1 || record.kind == 2,
                  record.kind == 1 ? record.size >= 0 && record.body.map({ Int64($0.count) }) == record.size : record.size == 0 && record.body == nil else {
                throw PreviewArchiveError.unsafe
            }
            let bytes = record.body?.count ?? 0
            guard bytes <= PreviewArchiveReader.memberLimit - total else { throw PreviewArchiveError.limit }
            total += bytes
            try names.add(record.path, kind: record.kind)
        }
    }

    func verify() throws {
        guard try ChosenFile(root, resolveParent: false).identity == rootIdentity,
              let receipt = receipts[url.lastPathComponent],
              try ChosenFile(url, resolveParent: false).identity == receipt.identity else { throw POSIXError(.ESTALE) }
    }

    /// Orphans after a crash count against the same ceiling. Unknown files are counted, never adopted or deleted.
    private static func cacheBytes(_ fd: Int32, depth: Int, remaining: inout Int) throws -> Int64 {
        guard depth < 128 else { throw PreviewArchiveError.limit }
        let copy = dup(fd)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }; throw POSIXError(.EIO)
        }
        defer { closedir(stream) }
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw POSIXError(.EIO) }
                return total
            }
            guard let name = DirectoryEntryName.read(entry) else { throw POSIXError(.EILSEQ) }
            if name == "." || name == ".." { continue }
            guard remaining > 0 else { throw PreviewArchiveError.limit }
            remaining -= 1
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.ESTALE) }
            var size = max(0, info.st_size)
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw POSIXError(.ESTALE) }
                defer { close(child) }
                size = try cacheBytes(child, depth: depth+1, remaining: &remaining)
            }
            guard size <= cacheLimit - total else { throw PreviewArchiveError.limit }
            total += size
        }
    }

    /// Provider exports share the same private root and identity-owned lifetime as archive members.
    @concurrent static func exporting(_ source: URL, in base: URL) async throws -> PreviewArchiveLease {
        try Task.checkCancellation()
        let lease = try PreviewArchiveLease(base: base, name: source.lastPathComponent)
        let control = TransferControl()
        let created = try await withTaskCancellationHandler {
            try await blocking { try TransferEngine.copyForExport(source, to: lease.url, control: control) }
        } onCancel: { control.cancel() }
        let prefix = lease.root.standardizedFileURL.path + "/"
        for (path, identity) in created {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard normalized.hasPrefix(prefix) else { throw POSIXError(.EINVAL) }
            let key = String(normalized.dropFirst(prefix.count))
            var info = stat()
            let directory = lstat(path, &info) == 0 && FileIdentity.from(info) == identity && info.st_mode & S_IFMT == S_IFDIR
            lease.receipts[key] = (identity, directory)
        }
        try Task.checkCancellation()
        try lease.verify()
        return lease
    }

    /// Create missing application-owned staging ancestors without following a replaced component.
    private static func prepare(_ base: URL) throws -> Int32 {
        guard base.isFileURL, base.path.hasPrefix("/") else { throw POSIXError(.EINVAL) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            for part in ChosenFile.systemSpelling(base.path).split(separator: "/") {
                let name = String(part)
                guard name != ".", name != ".." else { throw POSIXError(.EINVAL) }
                if mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw POSIXError(.EIO) }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw POSIXError(.ELOOP) }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
            return fd
        } catch { close(fd); throw error }
    }

    private func opened(_ parts: [String]) throws -> Int32 {
        var fd = dup(rootFD)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            for depth in parts.indices {
                let key = parts.prefix(depth+1).joined(separator: "/")
                guard let receipt = receipts[key], receipt.directory else { throw POSIXError(.ESTALE) }
                let next = openat(fd, parts[depth], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw POSIXError(.ESTALE) }
                var info = stat()
                guard fstat(next, &info) == 0, FileIdentity.from(info) == receipt.identity else {
                    close(next); throw POSIXError(.ESTALE)
                }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private func makeFolders(_ parts: [String], quarantine: Data?) throws {
        for depth in parts.indices {
            let prefix = Array(parts.prefix(depth+1)), key = prefix.joined(separator: "/")
            if receipts[key] != nil { continue }
            let parent = try opened(Array(prefix.dropLast()))
            defer { close(parent) }
            guard mkdirat(parent, parts[depth], 0o700) == 0 else { throw POSIXError(.EEXIST) }
            let fd = openat(parent, parts[depth], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
            receipts[key] = (.from(info), true)
            try Self.mark(fd, quarantine: quarantine)
        }
    }

    private func write(_ data: Data, path: [String], quarantine: Data?) throws {
        let parent = try opened(Array(path.dropLast()))
        defer { close(parent) }
        let fd = openat(parent, path.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EEXIST) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
        receipts[path.joined(separator: "/")] = (.from(info), false)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(65536, bytes.count-offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        try Self.mark(fd, quarantine: quarantine)
    }

    private static func quarantine(_ fd: Int32) throws -> Data? {
        let count = fgetxattr(fd, "com.apple.quarantine", nil, 0, 0, 0)
        if count < 0, errno == ENOATTR || errno == ENOTSUP { return nil }
        guard count >= 0, count <= 4096 else { throw POSIXError(.EIO) }
        guard count > 0 else { return nil }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { fgetxattr(fd, "com.apple.quarantine", $0.baseAddress, count, 0, 0) }
        guard read == count else { throw POSIXError(.EIO) }
        return data
    }

    private static func mark(_ fd: Int32, quarantine: Data?) throws {
        guard let quarantine else { return }
        let result = quarantine.withUnsafeBytes { fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, 0) }
        guard result == 0 || errno == ENOTSUP else { throw POSIXError(.EIO) }
    }

    private func clean() {
        var info = stat()
        guard fstatat(parentFD, root.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity.from(info) == rootIdentity else { return }
        for (key, receipt) in receipts.sorted(by: { $0.key.split(separator: "/").count > $1.key.split(separator: "/").count }) {
            let parts = key.components(separatedBy: "/")
            guard let parent = try? opened(Array(parts.dropLast())) else { continue }
            defer { close(parent) }
            guard fstatat(parent, parts.last!, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity.from(info) == receipt.identity else { continue }
            _ = unlinkat(parent, parts.last!, receipt.directory ? AT_REMOVEDIR : 0)
        }
        // A planted item is never owned; a nonempty folder stays behind rather than recursively deleting it.
        guard fstatat(parentFD, root.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity.from(info) == rootIdentity else { return }
        _ = unlinkat(parentFD, root.lastPathComponent, AT_REMOVEDIR)
    }
}
