import Foundation
import StrataModel

/// Pause and cancel switches shared by a job (main actor) and the thread doing its work.
nonisolated final class TransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    var isCancelled: Bool { condition.withLock { cancelled } }
    var isPaused: Bool { condition.withLock { paused && !cancelled } }

    func pause() { condition.withLock { paused = true } }

    func resume() {
        condition.withLock {
            paused = false
            condition.broadcast()
        }
    }

    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    /// Blocks while paused. Returns false once the job is cancelled.
    func checkpoint() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        return !cancelled
    }
}

/// Counters the worker bumps as it goes; the job samples them a few times a second.
nonisolated final class TransferProgress: @unchecked Sendable {
    struct Snapshot: Sendable {
        var bytes: Int64 = 0
        var files = 0
        var verifiedBytes: Int64 = 0
        var currentName: String?
        var isVerifying = false
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot { lock.withLock { value } }

    func update(_ body: (inout Snapshot) -> Void) {
        lock.withLock { body(&value) }
    }

    func reset() {
        lock.withLock { value = Snapshot() }
    }
}

/// Runs blocking file work on its own serial queue, off the cooperative pool, so a paused or slow copy never
/// starves Swift concurrency.
nonisolated final class TransferWorker: Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// One top-level item of a job, as planned on the main actor and carried out by `TransferEngine.perform`.
nonisolated struct TransferItem: Sendable {
    enum Operation: Sendable {
        /// Same-volume move: one `rename(2)`.
        case rename
        /// `copyfile(3)`, cloning when the volume allows it.
        case copy
        /// Cross-volume move: copy, verify if asked, then remove the original.
        case copyThenDelete
    }

    enum Outcome: Sendable {
        case pending, done, partial, failed, skipped, cancelled
    }

    let source: URL
    /// Where it goes. For "keep both" and same-folder copies the final name is picked right before writing.
    var destination: URL
    var operation: Operation
    var decision: ConflictDecision?
    /// Same-folder copy: name it like Finder's duplicates ("name copy.ext").
    var copyStyleName = false
    var bytes: Int64 = 0
    var files = 1
    /// What the item must be (for an undo or redo, the item it means): one put in its place since is left where it
    /// is. Nil for any item there.
    var expected: FileIdentity?
    var outcome: Outcome = .pending
}

/// What `perform` did to one item.
nonisolated struct TransferItemResult: Sendable {
    var outcome: TransferItem.Outcome
    var destination: URL
    var failures: [TransferFailure] = []
    /// The item it replaced, now in the Trash.
    var replaced: TransferMove?
    /// Captured before moving the replaced item into the Trash, never inferred at the later worker handoff.
    var replacedIdentity: FileIdentity?
    /// The original is gone (move finished).
    var sourceRemoved = false
    /// What the item is where it landed (see `LandedFiles`), read as it was put there: for undo.
    var landed: FileIdentity?
    var created: [String: FileIdentity] = [:]
}

/// State for one `copyfile` call, reached from the C callback through its context pointer.
nonisolated final class CopySession: @unchecked Sendable {
    let control: TransferControl
    let progress: TransferProgress
    let throttle: Int64?
    var errors: [TransferEngine.EntryError] = []
    var created: [String: FileIdentity] = [:]
    var sourceIdentities: [String: FileIdentity] = [:]
    var quit = false
    private var fileSize: Int64 = 0
    private var fileReported: Int64 = 0
    private var failedPaths: Set<String> = []
    private var directories: [String: DirectoryDescriptor] = [:]
    private let copyFailure: (@Sendable (URL) -> Int32?)?

    init(control: TransferControl, progress: TransferProgress, throttle: Int64?, copyFailure: (@Sendable (URL) -> Int32?)?) {
        self.control = control
        self.progress = progress
        self.throttle = throttle
        self.copyFailure = copyFailure
    }

    func handle(what: Int32, stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?,
                destination: UnsafePointer<CChar>?, code: Int32) -> Int32 {
        let quitCode = Int32(COPYFILE_QUIT)
        if quit { return quitCode }

        if let source, stage == COPYFILE_START {
            let src = String(cString: source)
            if sourceIdentities[src] == nil, let id = Self.sourceIdentity(state, path: src) {
                sourceIdentities[src] = id
            }
        }

        if stage == COPYFILE_ERR {
            if code == ECANCELED || control.isCancelled {
                quit = true
                return quitCode
            }
            // Extended attributes the destination won't take (protected or unsupported) don't fail the file.
            if what == COPYFILE_COPY_XATTR { return Int32(COPYFILE_CONTINUE) }
            recordError(what: what, state: state, source: source, destination: destination, code: code)
            if what == COPYFILE_RECURSE_FILE || what == COPYFILE_COPY_DATA {
                finishFile()
            }
            return Int32(COPYFILE_SKIP)
        }

        if what == COPYFILE_RECURSE_DIR && stage == COPYFILE_FINISH, let destination {
            let dst = String(cString: destination)
            let descriptor = DirectoryDescriptor(state)
            directories[dst] = descriptor
            if let id = descriptor?.identity ?? FileIdentity.read(dst) { created[dst] = id }
        }
        if what == COPYFILE_RECURSE_DIR_CLEANUP && stage == COPYFILE_FINISH, let destination {
            let dst = String(cString: destination)
            if let id = directories[dst]?.identity { created[dst] = id }
        }
        if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH, let destination {
            let dst = String(cString: destination)
            if let id = Self.destinationIdentity(state) ?? FileIdentity.read(dst) { created[dst] = id }
        }
        if stage == COPYFILE_FINISH && (what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR_CLEANUP),
           let destination, let code = copyFailure?(URL(fileURLWithPath: String(cString: destination))) {
            recordError(what: what, state: state, source: source, destination: destination, code: code)
        }
        if what == COPYFILE_RECURSE_DIR_CLEANUP && stage == COPYFILE_FINISH, let destination {
            directories.removeValue(forKey: String(cString: destination))
        }

        switch (what, stage) {
        case (COPYFILE_RECURSE_FILE, COPYFILE_START):
            var info = stat()
            fileSize = source.map { lstat($0, &info) == 0 ? Int64(info.st_size) : 0 } ?? 0
            fileReported = 0
            if let source {
                let name = (String(cString: source) as NSString).lastPathComponent
                progress.update { $0.currentName = name }
            }
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            let delta = Int64(copied) - fileReported
            if delta > 0 {
                fileReported = Int64(copied)
                progress.update { $0.bytes += delta }
                if let throttle, throttle > 0 { usleep(useconds_t(min(Double(delta) / Double(throttle), 2) * 1_000_000)) }
            }
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            finishFile()
        default:
            break
        }
        // Block here while paused; stop at the next block once cancelled.
        if !control.checkpoint() {
            quit = true
            return quitCode
        }
        return Int32(COPYFILE_CONTINUE)
    }

    private func recordError(what: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?,
                             destination: UnsafePointer<CChar>?, code: Int32) {
        let src = source.map { String(cString: $0) } ?? ""
        let dst = destination.map { String(cString: $0) } ?? ""
        // Directory metadata cleanup reopens a pathname, so retain the identity from its exclusive creation instead.
        // The dictionary contains only directories still on copyfile's depth-first traversal stack.
        let identity = what == COPYFILE_RECURSE_DIR_CLEANUP ? directories.removeValue(forKey: dst)?.identity : Self.destinationIdentity(state)
        if let identity { created[dst] = identity }
        if failedPaths.insert(src).inserted {
            errors.append(.init(source: src, destination: dst, message: TransferEngine.describe(code), identity: identity))
        }
    }

    /// Keep the originally opened directory alive through metadata cleanup. copyfile changes its birth time there,
    /// so read the final identity from that descriptor, never from the cleanup pass's reopened pathname.
    final class DirectoryDescriptor {
        let fd: Int32

        init?(_ state: copyfile_state_t?) {
            var original: Int32 = -1
            guard let state, copyfile_state_get(state, UInt32(COPYFILE_STATE_DST_FD), &original) == 0,
                  original >= 0 else { return nil }
            let duplicate = fcntl(original, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { return nil }
            fd = duplicate
        }

        private init(fd: Int32) {
            self.fd = fd
        }

        static func openDirectory(_ path: String) -> DirectoryDescriptor? {
            let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { return nil }
            return DirectoryDescriptor(fd: opened)
        }

        deinit { close(fd) }

        var identity: FileIdentity? {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            return FileIdentity.from(info)
        }
    }

    private static func destinationIdentity(_ state: copyfile_state_t?) -> FileIdentity? {
        var fd: Int32 = -1, info = stat()
        guard let state, copyfile_state_get(state, UInt32(COPYFILE_STATE_DST_FD), &fd) == 0,
              fd >= 0, fstat(fd, &info) == 0 else { return nil }
        return FileIdentity.from(info)
    }

    private static func sourceIdentity(_ state: copyfile_state_t?, path: String) -> FileIdentity? {
        var fd: Int32 = -1, info = stat()
        if let state, copyfile_state_get(state, UInt32(COPYFILE_STATE_SRC_FD), &fd) == 0,
           fd >= 0, fstat(fd, &info) == 0 {
            return FileIdentity.from(info)
        }
        return FileIdentity.read(path)
    }

    private func finishFile() {
        let rest = max(0, fileSize - fileReported)
        fileReported = fileSize
        progress.update {
            $0.bytes += rest
            $0.files += 1
        }
    }
}

nonisolated extension TransferEngine {
    static func canRestart(_ destination: URL, created: [String: FileIdentity]) -> Bool {
        let current = snapshotIdentities(destination)
        guard !current.isEmpty else { return true }
        return current.allSatisfy { created[$0.key] == $0.value }
    }

    static func canRepair(_ source: URL, into destination: URL, owned: [String: FileIdentity]) -> Bool {
        var srcRoot = stat(), dstRoot = stat()
        guard lstat(source.path, &srcRoot) == 0, srcRoot.st_mode & S_IFMT == S_IFDIR,
              lstat(destination.path, &dstRoot) == 0, dstRoot.st_mode & S_IFMT == S_IFDIR,
              let expectedRoot = owned[destination.path], FileIdentity.from(dstRoot) == expectedRoot else { return false }
        guard let cpath = strdup(source.path) else { return false }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return false }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            if info == FTS_DNR || info == FTS_ERR || info == FTS_NS { return false }
            let srcPath = String(cString: entry.pointee.fts_path)
            let relative = srcPath.count > source.path.count ? String(srcPath.dropFirst(source.path.count)) : ""
            let dstPath = destination.path + relative
            var dstInfo = stat()
            if lstat(dstPath, &dstInfo) == 0 {
                guard let expected = owned[dstPath], FileIdentity.from(dstInfo) == expected else { return false }
                let srcIsDir = info == FTS_D
                let dstIsDir = dstInfo.st_mode & S_IFMT == S_IFDIR
                if srcIsDir != dstIsDir { return false }
            }
        }
        return true
    }

    static func snapshotIdentities(_ root: URL) -> [String: FileIdentity] {
        var result: [String: FileIdentity] = [:]
        guard let cpath = strdup(root.path) else { return result }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return result }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            if Int32(entry.pointee.fts_info) == FTS_DP { continue }
            let path = String(cString: entry.pointee.fts_path)
            if let id = FileIdentity.read(path) { result[path] = id }
        }
        return result
    }

    /// Repairs an owned partial directory tree in place without touching unowned siblings (see `copy`).
    static func repairOwnedDirectory(_ source: URL, to destination: URL, owned: [String: FileIdentity],
                                     clone: Bool, control: TransferControl, progress: TransferProgress) -> CopyOutcome {
        guard canRepair(source, into: destination, owned: owned) else {
            return CopyOutcome(fatal: String(localized: "The items have moved or been changed since."),
                               destinationExisted: true)
        }
        var outcome = CopyOutcome()
        guard let cpath = strdup(source.path) else { return CopyOutcome(fatal: describe(ENOMEM)) }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            return CopyOutcome(fatal: describe(errno))
        }
        defer { fts_close(fts) }
        let hooks = hooks
        var directories: [String: CopySession.DirectoryDescriptor] = [:]
        while let entry = fts_read(fts) {
            guard control.checkpoint() else { outcome.cancelled = true; break }
            let info = Int32(entry.pointee.fts_info)
            let srcPath = String(cString: entry.pointee.fts_path)
            let relative = srcPath.count > source.path.count ? String(srcPath.dropFirst(source.path.count)) : ""
            let dstPath = destination.path + relative
            let srcURL = URL(fileURLWithPath: srcPath), dstURL = URL(fileURLWithPath: dstPath)
            switch info {
            case FTS_D:
                if let id = FileIdentity.read(srcPath) { outcome.sourceIdentities[srcPath] = id }
                if exists(dstURL) {
                    guard let expected = owned[dstPath], FileIdentity.read(dstPath) == expected,
                          let descriptor = CopySession.DirectoryDescriptor.openDirectory(dstPath),
                          descriptor.identity == expected else {
                        outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                         message: String(localized: "The items have moved or been changed since."),
                                                         identity: owned[dstPath]))
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                    directories[dstPath] = descriptor
                    var dirInfo = stat()
                    if fstat(descriptor.fd, &dirInfo) == 0, (dirInfo.st_mode & S_IRWXU) != S_IRWXU {
                        _ = fchmod(descriptor.fd, (dirInfo.st_mode & 0o7777) | S_IRWXU)
                    }
                    outcome.created[dstPath] = expected
                } else {
                    guard mkdir(dstPath, 0o700) == 0 else {
                        outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                         message: describe(errno), identity: nil))
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                    let descriptor = CopySession.DirectoryDescriptor.openDirectory(dstPath)
                    directories[dstPath] = descriptor
                    if let id = descriptor?.identity ?? FileIdentity.read(dstPath) { outcome.created[dstPath] = id }
                }
            case FTS_DP:
                let descriptor = directories.removeValue(forKey: dstPath)
                if let expected = descriptor?.identity, FileIdentity.read(dstPath) == expected {
                    _ = Darwin.copyfile(srcPath, dstPath, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
                }
                if let id = descriptor?.identity { outcome.created[dstPath] = id }
                if let code = hooks.copyFailure?(dstURL) {
                    outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                     message: describe(code), identity: outcome.created[dstPath]))
                }
            case FTS_F, FTS_SL, FTS_SLNONE:
                if exists(dstURL) {
                    removeIfPresent(dstURL, in: destination, created: owned.merging(outcome.created) { _, new in new })
                    if exists(dstURL) {
                        outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                         message: String(localized: "The items have moved or been changed since."),
                                                         identity: owned[dstPath]))
                        continue
                    }
                }
                let single = copyfile(srcURL, to: dstURL, clone: clone, control: control, progress: progress)
                for (path, id) in single.created { outcome.created[path] = id }
                for (path, id) in single.sourceIdentities { outcome.sourceIdentities[path] = id }
                outcome.errors += single.errors
                if single.cancelled { outcome.cancelled = true; return outcome }
                if let fatal = single.fatal {
                    outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                     message: fatal, identity: single.created[dstPath]))
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                 message: describe(entry.pointee.fts_errno), identity: owned[dstPath]))
            default:
                break
            }
        }
        return outcome
    }
}
