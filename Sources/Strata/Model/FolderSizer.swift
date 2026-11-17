import Foundation
import StrataSupport
import Synchronization

nonisolated package struct FolderSize: Equatable, Sendable {
    package let bytes: Int64
    package let files: Int
    package let allocatedBytes: Int64?
    package let allocationComplete: Bool
    /// When the most recently changed file anywhere inside was modified; nil when there are no files, or when the
    /// size came from somewhere that didn't look (the index). Finder's .DS_Store records don't count: Finder rewrites
    /// them when a folder is only looked at.
    package let newestFile: Date?
    /// The same, leaving out hidden files and anything inside a hidden folder, such as a repository's `.git`, whose
    /// bookkeeping changes without anything visible changing.
    package let newestVisibleFile: Date?
    /// The file system's number for the folder walked: another folder put in its place has a different one.
    package let identifier: UInt64?

    package init(bytes: Int64, files: Int, allocatedBytes: Int64? = nil, allocationComplete: Bool = true,
                 newestFile: Date? = nil, newestVisibleFile: Date? = nil, identifier: UInt64? = nil) {
        self.bytes = bytes
        self.files = files
        self.allocatedBytes = allocatedBytes
        self.allocationComplete = allocationComplete
        self.newestFile = newestFile
        self.newestVisibleFile = newestVisibleFile
        self.identifier = identifier
    }
}

/// Computes folder sizes in the background. Results are shared by every window; each browser owns
/// its own queue so leaving a folder cancels only that browser's pending walks.
///
/// A walk nobody asked for, the kind a list starts for its rows, fetches nothing: it measures nothing of a folder
/// that is only in the cloud, and passes over one deeper in. A walk you asked for (the Inspector, Disk Usage)
/// fetches what it needs, measures everything, and is not stopped because the index took the folder over.
@MainActor package final class FolderSizer {
    private struct Measured {
        let size: FolderSize
        /// A walk you asked for measured it, so it is of everything.
        let asked: Bool
        /// When its walk began reading, on `clock`.
        let startedAt: UInt64
    }

    private static var measured: [String: Measured] = [:]
    /// Orders changes and walks. It only moves forward, and each change and each walk as it starts reading moves it on,
    /// so a total is stale when a change inside its folder came after its walk began, and of two walks the later one
    /// wins. Walks start on their own threads, hence the lock.
    nonisolated private static let clock = Mutex<UInt64>(0)
    nonisolated fileprivate static func tick() -> UInt64 { clock.withLock { $0 += 1; return $0 } }
    private static var changedAt: [String: UInt64] = [:]
    /// Where anything below may have changed: checked for every folder under it, measured or still being walked.
    private static var subtreeChangedAt: [String: UInt64] = [:]
    /// When the latest change inside each folder was seen, for waiting until a folder is quiet before walking it again.
    private static var changedWhen: [String: Date] = [:]
    private static var subtreeChangedWhen: [String: Date] = [:]
    /// Changes recorded before this were forgotten to bound their memory, so totals walked before it count as stale.
    private static var forgottenBefore: UInt64 = 0
    /// Large enough for any one listing's folders: a sort by size or contents asks for all of them.
    private static let changeCapacity = 65_536

    /// Who asks for a size. A walk asked for goes on while one of them still wants it.
    package enum Asker: Hashable, Sendable {
        case inspector, diskUsage
    }

    private struct Pending {
        let id: UUID
        let url: URL
        /// None while the walk waits for its folder to be quiet before walking it again.
        var operation: SizeOperation?
        /// Empty for a walk nobody asked for.
        var askers: Set<Asker>
        var asked: Bool { !askers.isEmpty }
    }

    package var onUpdate: ((URL) -> Void)?
    /// Whether a folder overtaken by a change is still worth walking again; asked when the walk would start.
    package var wantsRewalk: (URL) -> Bool = { _ in true }
    private let queue = OperationQueue()
    package typealias Reader = @Sendable (String, @Sendable () -> Bool) -> FolderSize?
    package typealias Delivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let deliver: Delivery
    private let reader: Reader
    private let kept: Int
    private var pending: [String: Pending] = [:]
    /// The sizes this sizer measured: each browser lets go of its own.
    private var recorded: Set<String> = []
    private var cancellations = 0

    /// `kept`: how many sizes this sizer keeps in the record when its browser leaves a folder, before it lets go of
    /// them.
    package init(reader: @escaping Reader = FolderSizer.measure, keeping kept: Int = 4096,
                 deliver: @escaping Delivery = { action in Task { @MainActor in action() } }) {
        self.reader = reader
        self.kept = kept
        self.deliver = deliver
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
    }

    isolated deinit {
        queue.cancelAllOperations()
        letGoOfSizes()
    }

    private static func key(_ url: URL) -> String { url.lexicallyStandardized.path }

    /// The size measured for `url`. One you ask for is of everything: a size measured without fetching stands for it
    /// only if nothing was passed over.
    package static func cached(_ url: URL, asked: Bool = false) -> FolderSize? {
        guard let known = measured[key(url)] else { return nil }
        return !asked || known.asked || known.size.allocationComplete ? known.size : nil
    }

    /// Whether a change inside `url` came after the walk that measured it began.
    package static func isStale(_ url: URL) -> Bool { isStale(key(url)) }

    private static func isStale(_ key: String) -> Bool {
        guard let known = measured[key] else { return false }
        return lastChange(inside: key) > known.startedAt
    }

    private static func lastChange(inside key: String) -> UInt64 {
        var latest = max(forgottenBefore, changedAt[key] ?? 0)
        var folder = Substring(key)
        while true {
            if let time = subtreeChangedAt[String(folder)] { latest = max(latest, time) }
            guard folder != "/", let slash = folder.lastIndex(of: "/") else { return latest }
            folder = slash == folder.startIndex ? "/" : folder[..<slash]
        }
    }

    /// The size a walk you asked for measured for `url`.
    package static func askedSize(_ url: URL) -> FolderSize? {
        guard !measured.isEmpty, let known = measured[key(url)], known.asked else { return nil }
        return known.size
    }

    /// The index has read all of `url`, so its total is the one from now on: what a walk you asked for measured
    /// before does not stand in for a total the index gives later. Its dates, which the index doesn't know, stay.
    package static func indexHoldsAll(of url: URL) {
        guard let known = measured[key(url)], known.asked else { return }
        measured[key(url)] = Measured(size: known.size, asked: false, startedAt: known.startedAt)
    }

    /// The size to show for a folder the index answers for: its total, or, while that leaves part of the folder
    /// out, what a walk you asked for measured.
    nonisolated package static func shown(indexed: FolderSize, asked: FolderSize?) -> FolderSize {
        indexed.allocationComplete ? indexed : asked ?? indexed
    }

    /// What walks you asked for measured for the folders directly in `folder`, by path.
    package static func askedSizes(in folder: URL) -> [String: FolderSize] {
        guard !measured.isEmpty else { return [:] }
        let parent = key(folder)
        let prefix = parent == "/" ? parent : parent + "/"
        return measured.reduce(into: [:]) { sizes, known in
            guard known.value.asked, known.key.hasPrefix(prefix), !known.key.dropFirst(prefix.count).contains("/") else { return }
            sizes[known.key] = known.value.size
        }
    }

    package var hasPending: Bool { !pending.isEmpty }

    package func isPending(_ url: URL) -> Bool {
        !pending.isEmpty && pending[Self.key(url)] != nil
    }

    /// Whether a walk of `url` that you asked for is under way.
    package func isAskedFor(_ url: URL) -> Bool {
        pending[Self.key(url)]?.asked == true
    }

    /// Measures `url` unless its size is known. `asker`: who asked for this size, so the walk fetches what is only
    /// in the cloud and takes the place of one that may not.
    package func request(_ url: URL, askedBy asker: Asker? = nil) {
        let key = Self.key(url), asked = asker != nil
        guard Self.cached(url, asked: asked) == nil || Self.isStale(key) else { return }
        if let walking = pending[key] {
            if walking.asked, let asker { pending[key]?.askers.insert(asker) }
            guard asked, !walking.asked else { return }
            walking.operation?.cancel()
        }
        let id = UUID()
        pending[key] = Pending(id: id, url: url, operation: nil, askers: asker.map { [$0] } ?? [])
        start(url, id: id)
    }

    private func start(_ url: URL, id: UUID) {
        let key = Self.key(url)
        guard pending[key]?.id == id, let asked = pending[key]?.asked else { return }
        let op = SizeOperation(path: url.path, reader: reader, fetches: asked)
        pending[key]?.operation = op
        let deliver = deliver
        op.completionBlock = { [unowned op, weak self] in
            let size = op.size, startedAt = op.startedAt, duration = op.duration
            deliver { [weak self] in
                self?.finish(url, id: id, size, asked: asked, startedAt: startedAt, duration: duration)
            }
        }
        queue.addOperation(op)
    }

    /// Something changed inside `url` (and anywhere below it, with `everywhere`): its total and those of the folders
    /// above it are stale. A walk under way may already have passed the change, so it walks once more after delivering.
    package static func changed(inside url: URL, everywhere: Bool = false) {
        changed([(url, everywhere)])
    }

    /// A batch of changes, recorded as one moment.
    package static func changed(_ changes: [(folder: URL, everywhere: Bool)]) {
        guard !changes.isEmpty else { return }
        let time = tick(), now = Date()
        for change in changes {
            let folder = change.folder.lexicallyStandardized
            if change.everywhere {
                subtreeChangedAt[folder.path] = time
                subtreeChangedWhen[folder.path] = now
            }
            var current = folder
            while current.path != "/" {
                changedAt[current.path] = time
                changedWhen[current.path] = now
                current = current.deletingLastPathComponent()
            }
        }
        boundChanges()
    }

    /// Folders listed again: one whose number differs from the folder walked at its path was put in its place (moved
    /// in, or copied over by Replace, which can keep its dates), so nothing measured below it applies.
    package static func listed(_ folders: [(url: URL, identifier: UInt64?)]) {
        guard !measured.isEmpty else { return }
        let replaced = folders.filter { folder in
            guard let listed = folder.identifier, let walked = measured[key(folder.url)]?.size.identifier else { return false }
            return listed != walked
        }
        changed(replaced.map { ($0.url, true) })
    }

    /// Stops the walk of `url` that nobody asked for. One you asked for goes on: that the index took the folder
    /// over, or is busy, is no reason to take back what you asked for.
    package func cancel(_ url: URL) {
        let key = Self.key(url)
        guard !pending.isEmpty, let entry = pending[key], !entry.asked else { return }
        pending[key] = nil
        entry.operation?.cancel()
    }

    /// The same for every walk nobody asked for that `shouldCancel` names.
    package func cancel(where shouldCancel: (URL) -> Bool) {
        guard !pending.isEmpty else { return }
        for (key, entry) in pending where !entry.asked && shouldCancel(entry.url) {
            pending.removeValue(forKey: key)
            entry.operation?.cancel()
        }
    }

    /// `asker` asks only about `wanted` from now on: a walk it asked for, and nobody else wants, stops.
    package func keepOnly(_ wanted: Set<URL>, askedBy asker: Asker) {
        let wanted = Set(wanted.map(Self.key))
        for (key, entry) in pending where entry.askers.contains(asker) && !wanted.contains(key) {
            pending[key]?.askers.remove(asker)
            guard entry.askers.count == 1 else { continue }
            pending[key] = nil
            entry.operation?.cancel()
        }
    }

    /// Stops every walk, asked for or not: their browser has left the folder. Once this sizer has measured many
    /// sizes it lets go of them here, and never as sizes arrive: a view that needs more sizes than are kept would
    /// have them measured over and over, each letting go starting its walks again. Another window's are not its to
    /// let go of.
    package func cancelPending() {
        cancellations += 1
        queue.cancelAllOperations()
        pending.removeAll()
        if recorded.count >= kept { letGoOfSizes() }
    }

    private func letGoOfSizes() {
        for key in recorded { Self.measured[key] = nil }
        recorded.removeAll()
    }

    /// Drops what is known of the size of `url` and of every folder above it, since a change inside changes all of
    /// them. A walk already under way counts as overtaken.
    package static func invalidate(_ url: URL) {
        let time = tick(), now = Date()
        var current = url.lexicallyStandardized
        while current.path != "/" {
            measured[current.path] = nil
            changedAt[current.path] = time
            changedWhen[current.path] = now
            current = current.deletingLastPathComponent()
        }
        boundChanges()
    }

    private static func boundChanges() {
        if changedAt.count + subtreeChangedAt.count >= changeCapacity { forgetChanges() }
    }

    /// When the latest change that makes the folder's total stale was seen.
    private static func quietSince(_ key: String) -> Date? {
        var latest = changedWhen[key]
        var folder = Substring(key)
        while true {
            if let when = subtreeChangedWhen[String(folder)] { latest = max(latest ?? when, when) }
            guard folder != "/", let slash = folder.lastIndex(of: "/") else { return latest }
            folder = slash == folder.startIndex ? "/" : folder[..<slash]
        }
    }

    /// Forgets the recorded changes to bound their memory: what was walked before now counts as stale, never as current.
    package static func forgetChanges() {
        changedAt.removeAll(keepingCapacity: true)
        subtreeChangedAt.removeAll(keepingCapacity: true)
        changedWhen.removeAll(keepingCapacity: true)
        subtreeChangedWhen.removeAll(keepingCapacity: true)
        forgottenBefore = tick()
    }

    private func finish(_ url: URL, id: UUID, _ size: FolderSize?, asked: Bool, startedAt: UInt64, duration: TimeInterval) {
        let key = Self.key(url)
        guard let walk = pending[key], walk.id == id else { return }
        pending[key] = nil
        guard let size else { return }
        // Another pane's sizer may already have published a total walked after this one began: keep it, but still
        // tell this sizer's owner, whose rows are waiting. A walk you asked for measured everything, so only a later
        // one you asked for takes its place; another window's walk that may not fetch doesn't replace it until a
        // change has overtaken it.
        let known = Self.measured[key]
        let newer = known.map { $0.startedAt > startedAt } ?? false
        let keepsKnown = asked ? known?.asked == true && newer : newer || (known?.asked == true && !Self.isStale(key))
        if !keepsKnown {
            Self.measured[key] = Measured(size: size, asked: asked, startedAt: startedAt)
            recorded.insert(key)
        }
        // Overtaken by a change: walk again once the folder has been quiet for twice as long as this walk took (at least
        // a second), so one that keeps changing isn't walked back to back. The walk is pending again before its owner
        // hears of this one, so what the owner stops then stops it too.
        let again = Self.isStale(key)
        if again { pending[key] = Pending(id: id, url: url, operation: nil, askers: walk.askers) }
        let cancelled = cancellations
        onUpdate?(url)
        guard again, cancellations == cancelled, let waiting = pending[key], waiting.id == id, waiting.operation == nil else { return }
        rewalk(url, id: id, quiet: max(1, 2 * duration))
    }

    private func rewalk(_ url: URL, id: UUID, quiet: TimeInterval) {
        let key = Self.key(url)
        let since = Self.quietSince(key).map { Date().timeIntervalSince($0) } ?? quiet
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, quiet - since)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let walk = self.pending[key], walk.id == id, walk.operation == nil else { return }
                // Measured meanwhile by another pane, or no longer shown: nothing to walk. Dropped meanwhile (an
                // operation changed the folder): walked now, as a row asking for it would.
                guard Self.measured[key] == nil || Self.isStale(key), walk.asked || self.wantsRewalk(url) else {
                    self.pending[key] = nil
                    return
                }
                let quietFor = Self.quietSince(key).map { Date().timeIntervalSince($0) } ?? quiet
                if quietFor < quiet { return self.rewalk(url, id: id, quiet: quiet) }
                self.start(url, id: id)
            }
        }
    }

    nonisolated package static func measure(_ path: String, isCancelled: @Sendable () -> Bool) -> FolderSize? {
        measure(path, isOnlyInTheCloud: { $0.fts_statp.map { DatalessFile.isDataless($0.pointee) } ?? false },
                isCancelled: isCancelled)
    }

    /// `isOnlyInTheCloud`: whether a folder the walk comes to has its contents with its cloud provider.
    nonisolated package static func measure(_ path: String, isOnlyInTheCloud: (FTSENT) -> Bool,
                                            isCancelled: @Sendable () -> Bool) -> FolderSize? {
        guard !isCancelled(), let cpath = strdup(path) else { return nil }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }
        var bytes: Int64 = 0
        var allocated: Int64 = 0
        var allocationKnown = true
        var files = 0
        var identifier: UInt64?
        var newest: timespec?
        var newestVisible: timespec?
        var visited = 0
        let fetchesNothing = DatalessFile.materializesNothing
        while let entry = fts_read(fts) {
            visited += 1
            if visited & 63 == 0, isCancelled() { return nil }
            switch Int32(entry.pointee.fts_info) {
            case FTS_D where fetchesNothing && isOnlyInTheCloud(entry.pointee):
                // Left to fts, a folder it may not fetch reads as an empty one. Nothing of the folder asked about is
                // measured then; one deeper in is passed over, and the size says it is not of everything.
                if entry.pointee.fts_level == FTS_ROOTLEVEL { return nil }
                allocationKnown = false
                fts_set(fts, entry, FTS_SKIP)
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let stat = entry.pointee.fts_statp {
                    bytes = bytes.saturatingAdd(max(0, Int64(stat.pointee.st_size)))
                    allocated = allocated.saturatingAdd(max(0, Int64(stat.pointee.st_blocks)).saturatingMultiply(512))
                    let modified = stat.pointee.st_mtimespec
                    if !isFinderRecord(entry), newest.map({ isEarlier($0, than: modified) }) ?? true { newest = modified }
                    if !isHidden(entry), newestVisible.map({ isEarlier($0, than: modified) }) ?? true { newestVisible = modified }
                } else { allocationKnown = false }
                files += 1
            case FTS_DNR, FTS_ERR, FTS_NS:
                allocationKnown = false
            case FTS_D:
                if entry.pointee.fts_level == FTS_ROOTLEVEL {
                    identifier = entry.pointee.fts_statp.map { UInt64($0.pointee.st_ino) }
                }
                // Marks a hidden folder so what's inside it counts as hidden too; the folder measured is never hidden.
                entry.pointee.fts_number = entry.pointee.fts_level > FTS_ROOTLEVEL && isHidden(entry) ? 1 : 0
            default:
                break
            }
        }
        return isCancelled() ? nil : FolderSize(bytes: bytes, files: files, allocatedBytes: allocated, allocationComplete: allocationKnown,
                                                newestFile: newest.map(date), newestVisibleFile: newestVisible.map(date),
                                                identifier: identifier)
    }

    /// The entry's name: the end of its path, which `FTS_NOCHDIR` keeps whole.
    nonisolated private static func name(_ entry: UnsafeMutablePointer<FTSENT>) -> UnsafeBufferPointer<CChar>? {
        guard let path = entry.pointee.fts_path else { return nil }
        let length = Int(entry.pointee.fts_namelen)
        return UnsafeBufferPointer(start: path + Int(entry.pointee.fts_pathlen) - length, count: length)
    }

    nonisolated private static func isFinderRecord(_ entry: UnsafeMutablePointer<FTSENT>) -> Bool {
        guard entry.pointee.fts_namelen == 9, let name = name(entry)?.baseAddress else { return false }
        return memcmp(name, ".DS_Store", 9) == 0
    }

    /// Hidden as the list judges it: a name starting with a dot, the hidden flag, or a hidden folder above it.
    nonisolated private static func isHidden(_ entry: UnsafeMutablePointer<FTSENT>) -> Bool {
        if let parent = entry.pointee.fts_parent, parent.pointee.fts_level >= 0, parent.pointee.fts_number == 1 { return true }
        if name(entry)?.first == CChar(bitPattern: UInt8(ascii: ".")) { return true }
        return entry.pointee.fts_statp.map { $0.pointee.st_flags & UInt32(UF_HIDDEN) != 0 } ?? false
    }

    nonisolated private static func isEarlier(_ a: timespec, than b: timespec) -> Bool {
        a.tv_sec != b.tv_sec ? a.tv_sec < b.tv_sec : a.tv_nsec < b.tv_nsec
    }

    nonisolated private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}

nonisolated private final class SizeOperation: Operation, @unchecked Sendable {
    let path: String
    var size: FolderSize?
    private(set) var startedAt: UInt64 = 0
    private(set) var duration: TimeInterval = 0
    private let reader: FolderSizer.Reader
    private let fetches: Bool

    init(path: String, reader: @escaping FolderSizer.Reader, fetches: Bool) {
        self.path = path
        self.reader = reader
        self.fetches = fetches
    }

    override func main() {
        guard !isCancelled else { return }
        startedAt = FolderSizer.tick()
        let began = Date()
        // Without fetching for this walk alone: the thread is the queue's, and goes on to others.
        let measured = fetches ? measure() : DatalessFile.withoutMaterializing { measure() }
        duration = Date().timeIntervalSince(began)
        if !isCancelled { size = measured }
    }

    private func measure() -> FolderSize? {
        reader(path) { [unowned self] in isCancelled }
    }
}
