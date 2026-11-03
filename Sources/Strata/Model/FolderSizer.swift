import Foundation
import StrataSupport
import Synchronization

nonisolated package struct FolderSize: Sendable {
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
@MainActor package final class FolderSizer {
    private static var cache: [String: FolderSize] = [:]
    /// Orders changes and walks. It only moves forward, and each change and each walk as it starts reading moves it on,
    /// so a total is stale when a change inside its folder came after its walk began, and of two walks the later one
    /// wins. Walks start on their own threads, hence the lock.
    nonisolated private static let clock = Mutex<UInt64>(0)
    nonisolated fileprivate static func tick() -> UInt64 { clock.withLock { $0 += 1; return $0 } }
    private static var measuredAt: [String: UInt64] = [:]
    private static var changedAt: [String: UInt64] = [:]
    /// Where anything below may have changed: checked for every folder under it, measured or still being walked.
    private static var subtreeChangedAt: [String: UInt64] = [:]
    /// When the latest change inside each folder was seen, for waiting until a folder is quiet before walking it again.
    private static var changedWhen: [String: Date] = [:]
    private static var subtreeChangedWhen: [String: Date] = [:]
    /// Changes recorded before this were forgotten to bound their memory, so totals walked before it count as stale.
    private static var forgottenBefore: UInt64 = 0
    /// Large enough for any one listing's folders: a sort by size or contents asks for all of them.
    private static let capacity = 65_536

    package var onUpdate: ((URL) -> Void)?
    /// Whether a folder overtaken by a change is still worth walking again; asked when the walk would start.
    package var wantsRewalk: (URL) -> Bool = { _ in true }
    private let queue = OperationQueue()
    package typealias Reader = @Sendable (String, @Sendable () -> Bool) -> FolderSize?
    package typealias Delivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let deliver: Delivery
    private let reader: Reader
    private var pending: [String: UUID] = [:]
    private var cancellations = 0

    package init(reader: @escaping Reader = FolderSizer.measure,
                 deliver: @escaping Delivery = { action in Task { @MainActor in action() } }) {
        self.reader = reader
        self.deliver = deliver
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
    }

    isolated deinit { queue.cancelAllOperations() }

    private static func key(_ url: URL) -> String { url.lexicallyStandardized.path }
    package static func cached(_ url: URL) -> FolderSize? { cache[key(url)] }
    package static func isStale(_ url: URL) -> Bool { isStale(key(url)) }

    private static func isStale(_ key: String) -> Bool {
        guard cache[key] != nil, let measured = measuredAt[key] else { return false }
        return lastChange(inside: key) > measured
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

    package func isMeasuring(_ url: URL) -> Bool { pending[Self.key(url)] != nil }

    package func request(_ url: URL) {
        let key = Self.key(url)
        guard Self.cache[key] == nil || Self.isStale(key), pending[key] == nil else { return }
        let id = UUID()
        pending[key] = id
        start(url, id: id)
    }

    private func start(_ url: URL, id: UUID) {
        let op = SizeOperation(path: url.path, reader: reader)
        let deliver = deliver
        op.completionBlock = { [unowned op, weak self] in
            let result = op.result, startedAt = op.startedAt, duration = op.duration
            deliver { [weak self] in self?.finish(url, id: id, result, startedAt: startedAt, duration: duration) }
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
        let replaced = folders.filter { folder in
            guard let listed = folder.identifier, let walked = cache[key(folder.url)]?.identifier else { return false }
            return listed != walked
        }
        changed(replaced.map { ($0.url, true) })
    }

    package func cancelPending() {
        cancellations += 1
        queue.cancelAllOperations()
        pending.removeAll()
    }

    /// Drops cached sizes for `url` and every folder above it, since a change inside changes all of them. A walk
    /// already under way counts as overtaken.
    package static func invalidate(_ url: URL) {
        let time = tick()
        var current = url.lexicallyStandardized
        let now = Date()
        while current.path != "/" {
            cache[current.path] = nil
            measuredAt[current.path] = nil
            changedAt[current.path] = time
            changedWhen[current.path] = now
            current = current.deletingLastPathComponent()
        }
        boundChanges()
    }

    private static func boundChanges() {
        if changedAt.count + subtreeChangedAt.count >= capacity { forgetChanges() }
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

    private func finish(_ url: URL, id: UUID, _ result: FolderSize?, startedAt: UInt64, duration: TimeInterval) {
        let key = Self.key(url)
        guard let walk = pending[key], walk == id else { return }
        pending[key] = nil
        guard let result else { return }
        // Another pane's sizer may already have published a total walked after this one began: keep it, but still
        // tell this sizer's owner, whose rows are waiting.
        let newer = Self.cache[key] != nil && (Self.measuredAt[key] ?? 0) > startedAt
        if !newer {
            if Self.cache[key] == nil, Self.cache.count >= Self.capacity {
                for evicted in Array(Self.cache.keys.prefix(Self.capacity / 4)) {
                    Self.cache[evicted] = nil
                    Self.measuredAt[evicted] = nil
                }
            }
            Self.cache[key] = result
            Self.measuredAt[key] = startedAt
        }
        let cancelled = cancellations
        onUpdate?(url)
        // Overtaken by a change: walk again once the folder has been quiet for twice as long as this walk took (at least
        // a second), so one that keeps changing isn't walked back to back. Stopped work stays stopped.
        guard Self.isStale(key), cancellations == cancelled else { return }
        pending[key] = id
        rewalk(url, id: id, quiet: max(1, 2 * duration))
    }

    private func rewalk(_ url: URL, id: UUID, quiet: TimeInterval) {
        let key = Self.key(url)
        let since = Self.quietSince(key).map { Date().timeIntervalSince($0) } ?? quiet
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, quiet - since)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending[key] == id else { return }
                // Measured meanwhile by another pane, or no longer shown: nothing to walk.
                guard Self.isStale(key), self.wantsRewalk(url) else { self.pending[key] = nil; return }
                let quietFor = Self.quietSince(key).map { Date().timeIntervalSince($0) } ?? quiet
                if quietFor < quiet { return self.rewalk(url, id: id, quiet: quiet) }
                self.start(url, id: id)
            }
        }
    }

    nonisolated package static func measure(_ path: String, isCancelled: @Sendable () -> Bool) -> FolderSize? {
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
        while let entry = fts_read(fts) {
            visited += 1
            if visited & 63 == 0, isCancelled() { return nil }
            switch Int32(entry.pointee.fts_info) {
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
                if entry.pointee.fts_level == 0 { identifier = entry.pointee.fts_statp.map { UInt64($0.pointee.st_ino) } }
                // Marks a hidden folder so what's inside it counts as hidden too; the folder measured is never hidden.
                entry.pointee.fts_number = entry.pointee.fts_level > 0 && isHidden(entry) ? 1 : 0
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
    var result: FolderSize?
    private(set) var startedAt: UInt64 = 0
    private(set) var duration: TimeInterval = 0
    private let reader: FolderSizer.Reader

    init(path: String, reader: @escaping FolderSizer.Reader) { self.path = path; self.reader = reader }

    override func main() {
        guard !isCancelled else { return }
        startedAt = FolderSizer.tick()
        let began = Date()
        let measured = reader(path) { [unowned self] in isCancelled }
        duration = Date().timeIntervalSince(began)
        if !isCancelled { result = measured }
    }
}
