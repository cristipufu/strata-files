import CryptoKit
import Foundation

nonisolated extension TransferEngine {
    // MARK: - Scanning

    /// Files and bytes under `url` (one cheap walk, no xattrs), or nil when cancelled.
    package static func scan(_ url: URL, control: TransferControl) -> FolderSize? {
        FolderSizer.measure(url.path) { control.isCancelled }
    }

    package static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    package static func device(_ url: URL) -> dev_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_dev : nil
    }

    // MARK: - Copying

    package struct EntryError: Sendable {
        package let source: String
        package let destination: String
        package let message: String
        package var identity: FileIdentity?
    }

    package struct CopyOutcome: Sendable {
        package var errors: [EntryError] = []
        package var cancelled = false
        /// Nothing could be copied at all.
        package var fatal: String?
        /// The copy was refused because something already sits at the destination: that item isn't ours to remove.
        package var destinationExisted = false
        /// Made as one APFS clone of the whole item (no per-file progress was reported).
        package var cloned = false
        package var created: [String: FileIdentity] = [:]
        package var sourceIdentities: [String: FileIdentity] = [:]
    }

    /// Recursive `copyfile(3)` with every piece of metadata, APFS clones where possible, per-file progress, and
    /// pause/cancel at block granularity. Files that fail are recorded and skipped; copyfile removes their partial data.
    package static func copy(_ source: URL, to destination: URL, replacingOwned: [String: FileIdentity]? = nil,
                     clone: Bool, control: TransferControl, progress: TransferProgress) -> CopyOutcome {
        if let owned = replacingOwned {
            return copyfile(source, to: destination, replacingOwned: owned, clone: clone, control: control, progress: progress)
        }
        guard !exists(destination) else {
            // copyfile would copy *into* an existing folder; the planner guarantees this never happens.
            return CopyOutcome(fatal: describe(EEXIST), destinationExisted: true)
        }
        let start = progress.snapshot
        let first = copyfile(source, to: destination, clone: clone, control: control, progress: progress)
        // copyfile's per-file cloning keeps every ACL and xattr, but fails inside folders without write permission
        // (it clones a read-only folder before filling it). For a folder that hit errors, start over with one clone of
        // the whole tree, then with a plain copy, which both cope with that.
        var isDirectory: ObjCBool = false
        guard clone, !first.errors.isEmpty, !first.cancelled, first.fatal == nil,
              FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              canRestart(destination, created: first.created)
        else { return first }
        removeIfPresent(destination, in: destination, created: first.created)   // Ours: COPYFILE_EXCL guaranteed nothing was there.
        guard !exists(destination) else { return first }
        progress.update {
            $0.files = start.files
            $0.bytes = start.bytes
        }
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW | CLONE_ACL)) == 0 {
            return CopyOutcome(cloned: true, created: snapshotIdentities(destination),
                               sourceIdentities: snapshotIdentities(source))
        }
        if errno == EEXIST { return CopyOutcome(fatal: describe(EEXIST), destinationExisted: true) }
        return copyfile(source, to: destination, clone: false, control: control, progress: progress)
    }

    /// File promises and clipboard staging use the same creation receipts as queued transfers.
    @discardableResult
    package static func copyForExport(_ source: URL, to destination: URL, control: TransferControl = TransferControl()) throws -> [String: FileIdentity] {
        let copied = copy(source, to: destination, clone: true, control: control, progress: TransferProgress())
        do {
            guard copied.fatal == nil, copied.errors.isEmpty, !copied.cancelled else { throw CocoaError(.fileWriteUnknown) }
            try ContainerCopies.finishCopyingOut(destination, owned: copied.created)
            return copied.created
        } catch {
            removeIfPresent(destination, in: destination, created: copied.created)
            throw error
        }
    }

    /// One recursive `copyfile` pass (see `copy`).
    package static func copyfile(_ source: URL, to destination: URL, replacingOwned: [String: FileIdentity]? = nil,
                         clone: Bool, control: TransferControl, progress: TransferProgress) -> CopyOutcome {
        if let owned = replacingOwned {
            return repairOwnedDirectory(source, to: destination, owned: owned, clone: clone, control: control, progress: progress)
        }

        let hooks = hooks
        let session = CopySession(control: control, progress: progress, throttle: hooks.throttleBytesPerSecond,
                                  copyFailure: hooks.copyFailure)
        if let id = FileIdentity.read(source.path) { session.sourceIdentities[source.path] = id }
        guard let state = copyfile_state_alloc() else { return CopyOutcome(fatal: describe(ENOMEM)) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = copyCallback
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(session).toOpaque())
        var flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL
        if clone { flags |= COPYFILE_CLONE }
        let status = Darwin.copyfile(source.path, destination.path, state, copyfile_flags_t(flags))
        let code = errno
        withExtendedLifetime(session) {}

        var outcome = CopyOutcome(errors: session.errors, created: session.created,
                                  sourceIdentities: session.sourceIdentities)
        if session.quit || control.isCancelled {
            outcome.cancelled = true
        } else if status != 0, session.errors.isEmpty {
            outcome.fatal = describe(code)
            // Something appeared at the destination meanwhile (COPYFILE_EXCL refused): leave it alone.
            outcome.destinationExisted = code == EEXIST
        } else if !exists(destination), session.errors.contains(where: { $0.source == source.path }) {
            // The top-level item itself failed (unreadable file, folder that can't be listed…).
            outcome.fatal = session.errors.first { $0.source == source.path }?.message
            outcome.errors.removeAll { $0.source == source.path }
        }
        if !outcome.destinationExisted {
            let failedDestinations = Set(session.errors.map(\.destination))
            for (path, id) in snapshotIdentities(destination) where outcome.created[path] == nil && !failedDestinations.contains(path) {
                outcome.created[path] = id
            }
            for (path, id) in snapshotIdentities(source) where outcome.sourceIdentities[path] == nil {
                outcome.sourceIdentities[path] = id
            }
        }
        return outcome
    }

    private static let copyCallback: copyfile_callback_t = { what, stage, state, source, destination, context in
        let code = errno
        guard let context else { return Int32(COPYFILE_CONTINUE) }
        let session = Unmanaged<CopySession>.fromOpaque(context).takeUnretainedValue()
        return session.handle(what: what, stage: stage, state: state, source: source, destination: destination, code: code)
    }

    // MARK: - Verifying

    package struct VerifyOutcome: Sendable {
        package var mismatches: [EntryError] = []
        package var cancelled = false
    }

    /// SHA-256 of every regular file under `source` against its counterpart under `destination`, streamed in 1 MB
    /// chunks; symlinks must point at the same place. Paths in `skipping` (already failed) are left out.
    package static func verify(_ source: URL, against destination: URL, created: [String: FileIdentity] = [:],
                       skipping: Set<String> = [], control: TransferControl,
                       progress: TransferProgress) -> VerifyOutcome {
        progress.update { $0.isVerifying = true }
        defer { progress.update { $0.isVerifying = false } }
        var outcome = VerifyOutcome()
        let root = source.path
        guard let cpath = strdup(root) else { return outcome }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return outcome }
        defer { fts_close(fts) }
        let buffers = (UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16),
                       UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16))
        defer {
            buffers.0.deallocate()
            buffers.1.deallocate()
        }
        while let entry = fts_read(fts) {
            let path = String(cString: entry.pointee.fts_path)
            if skipping.contains(path) {
                if Int32(entry.pointee.fts_info) == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                continue
            }
            let relative = path.count > root.count ? String(path.dropFirst(root.count)) : ""
            let target = destination.path + relative
            let currentIdentity = FileIdentity.read(target)
            let expectedIdentity = created[target]
            let identity = expectedIdentity ?? currentIdentity
            if let expectedIdentity, currentIdentity != expectedIdentity {
                if Int32(entry.pointee.fts_info) == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                let message = currentIdentity == nil
                    ? String(localized: "The copy can’t be read back")
                    : String(localized: "The copy doesn’t match the original")
                outcome.mismatches.append(EntryError(source: path, destination: target, message: message, identity: identity))
                continue
            }
            switch Int32(entry.pointee.fts_info) {
            case FTS_F:
                progress.update { $0.currentName = (path as NSString).lastPathComponent }
                switch compareFile(path, with: target, expected: expectedIdentity, buffers: buffers, control: control,
                                   progress: progress) {
                case .cancelled:
                    outcome.cancelled = true
                    return outcome
                case .different(let message):
                    outcome.mismatches.append(EntryError(source: path, destination: target, message: message, identity: identity))
                case .same:
                    break
                }
            case FTS_SL, FTS_SLNONE:
                if !linkMatches(path, target, expected: expectedIdentity) {
                    outcome.mismatches.append(EntryError(source: path, destination: target,
                                                         message: String(localized: "The copied alias points somewhere else"), identity: identity))
                }
            default:
                break
            }
        }
        return outcome
    }

    private enum FileCheck {
        case same
        case different(String)
        case cancelled
    }

    /// The original's and the copy's SHA-256, the copy read only while it's still `expected` (when known).
    private static func compareFile(_ path: String, with target: String, expected: FileIdentity?,
                                    buffers: (UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer),
                                    control: TransferControl, progress: TransferProgress) -> FileCheck {
        let original = sha256(path, buffer: buffers.0, control: control) { n in
            progress.update { $0.verifiedBytes += Int64(n) }
        }
        if control.isCancelled { return .cancelled }
        let copy = sha256(target, expected: expected, buffer: buffers.1, control: control) { _ in }
        if control.isCancelled { return .cancelled }
        guard original == nil || copy == nil || original != copy else { return .same }
        if original == nil { return .different(String(localized: "The original can’t be read")) }
        return .different(copy == nil ? String(localized: "The copy can’t be read back")
                          : String(localized: "The copy doesn’t match the original"))
    }

    /// Whether the copied link points where the original does, and is still the link this job made.
    private static func linkMatches(_ path: String, _ target: String, expected: FileIdentity?) -> Bool {
        readLink(path) == readLink(target) && (expected == nil || FileIdentity.read(target) == expected)
    }

    package static func sha256(_ path: String, expected: FileIdentity? = nil, buffer: UnsafeMutableRawBufferPointer,
                       control: TransferControl, onRead: (Int) -> Void) -> SHA256.Digest? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if let expected {
            var info = stat()
            guard fstat(fd, &info) == 0, FileIdentity.from(info) == expected else { return nil }
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        while true {
            guard control.checkpoint() else { return nil }
            let n = read(fd, buffer.baseAddress, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            onRead(n)
        }
        return hasher.finalize()
    }

    static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, buffer.count - 1)
        guard n >= 0 else { return nil }
        return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
