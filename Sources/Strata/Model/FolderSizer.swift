import Foundation
import StrataSupport

nonisolated package struct FolderSize: Equatable, Sendable {
    package let bytes: Int64
    package let files: Int
    package let allocatedBytes: Int64?
    package let allocationComplete: Bool

    package init(bytes: Int64, files: Int, allocatedBytes: Int64? = nil, allocationComplete: Bool = true) {
        self.bytes = bytes
        self.files = files
        self.allocatedBytes = allocatedBytes
        self.allocationComplete = allocationComplete
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
    }

    private static var measured: [String: Measured] = [:]

    /// Who asks for a size. A walk asked for goes on while one of them still wants it.
    package enum Asker: Hashable, Sendable {
        case inspector, diskUsage
    }

    private struct Pending {
        let id: UUID
        let url: URL
        let operation: SizeOperation
        /// Empty for a walk nobody asked for.
        var askers: Set<Asker>
        var asked: Bool { !askers.isEmpty }
    }

    package var onUpdate: ((URL) -> Void)?
    private let queue = OperationQueue()
    package typealias Reader = @Sendable (String, @Sendable () -> Bool) -> FolderSize?
    package typealias Delivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let deliver: Delivery
    private let reader: Reader
    private let kept: Int
    private var pending: [String: Pending] = [:]
    /// The sizes this sizer measured: each browser lets go of its own.
    private var recorded: Set<String> = []

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

    /// The size a walk you asked for measured for `url`.
    package static func askedSize(_ url: URL) -> FolderSize? {
        guard !measured.isEmpty, let known = measured[key(url)], known.asked else { return nil }
        return known.size
    }

    /// The index has read all of `url`, so its total is the one from now on: what a walk you asked for measured
    /// before does not stand in for a total the index gives later.
    package static func indexHoldsAll(of url: URL) {
        if askedSize(url) != nil { measured[key(url)] = nil }
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
        guard Self.cached(url, asked: asked) == nil else { return }
        if let walking = pending[key] {
            if walking.asked, let asker { pending[key]?.askers.insert(asker) }
            guard asked, !walking.asked else { return }
            walking.operation.cancel()
        }
        let id = UUID()
        let op = SizeOperation(path: url.path, reader: reader, fetches: asked)
        pending[key] = Pending(id: id, url: url, operation: op, askers: asker.map { [$0] } ?? [])
        let deliver = deliver
        op.completionBlock = { [unowned op, weak self] in
            let size = op.size
            deliver { [weak self] in self?.finish(url, id: id, size, asked: asked) }
        }
        queue.addOperation(op)
    }

    /// Stops the walk of `url` that nobody asked for. One you asked for goes on: that the index took the folder
    /// over, or is busy, is no reason to take back what you asked for.
    package func cancel(_ url: URL) {
        let key = Self.key(url)
        guard !pending.isEmpty, let entry = pending[key], !entry.asked else { return }
        pending[key] = nil
        entry.operation.cancel()
    }

    /// The same for every walk nobody asked for that `shouldCancel` names.
    package func cancel(where shouldCancel: (URL) -> Bool) {
        guard !pending.isEmpty else { return }
        for (key, entry) in pending where !entry.asked && shouldCancel(entry.url) {
            pending.removeValue(forKey: key)
            entry.operation.cancel()
        }
    }

    /// `asker` asks only about `wanted` from now on: a walk it asked for, and nobody else wants, stops.
    package func keepOnly(_ wanted: Set<URL>, askedBy asker: Asker) {
        let wanted = Set(wanted.map(Self.key))
        for (key, entry) in pending where entry.askers.contains(asker) && !wanted.contains(key) {
            pending[key]?.askers.remove(asker)
            guard entry.askers.count == 1 else { continue }
            pending[key] = nil
            entry.operation.cancel()
        }
    }

    /// Stops every walk, asked for or not: their browser has left the folder. Once this sizer has measured many
    /// sizes it lets go of them here, and never as sizes arrive: a view that needs more sizes than are kept would
    /// have them measured over and over, each letting go starting its walks again. Another window's are not its to
    /// let go of.
    package func cancelPending() {
        queue.cancelAllOperations()
        pending.removeAll()
        if recorded.count >= kept { letGoOfSizes() }
    }

    private func letGoOfSizes() {
        for key in recorded { Self.measured[key] = nil }
        recorded.removeAll()
    }

    /// Drops what is known of the size of `url` and of every folder above it, since a change inside changes all of
    /// them.
    package static func invalidate(_ url: URL) {
        var current = url.lexicallyStandardized
        while current.path != "/" {
            measured[current.path] = nil
            current = current.deletingLastPathComponent()
        }
    }

    private func finish(_ url: URL, id: UUID, _ size: FolderSize?, asked: Bool) {
        let key = Self.key(url)
        guard pending[key]?.id == id else { return }
        pending[key] = nil
        guard let size else { return }
        // Another window's walk of the folder, asked for, may have ended first: what it measured is of everything,
        // and what this one measured is not.
        if asked || Self.askedSize(url) == nil {
            Self.measured[key] = Measured(size: size, asked: asked)
            recorded.insert(key)
        }
        onUpdate?(url)
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
                } else { allocationKnown = false }
                files += 1
            case FTS_DNR, FTS_ERR, FTS_NS:
                allocationKnown = false
            default:
                break
            }
        }
        return isCancelled() ? nil : FolderSize(bytes: bytes, files: files, allocatedBytes: allocated, allocationComplete: allocationKnown)
    }
}

nonisolated private final class SizeOperation: Operation, @unchecked Sendable {
    let path: String
    var size: FolderSize?
    private let reader: FolderSizer.Reader
    private let fetches: Bool

    init(path: String, reader: @escaping FolderSizer.Reader, fetches: Bool) {
        self.path = path
        self.reader = reader
        self.fetches = fetches
    }

    override func main() {
        guard !isCancelled else { return }
        // Without fetching for this walk alone: the thread is the queue's, and goes on to others.
        let measured = fetches ? measure() : DatalessFile.withoutMaterializing { measure() }
        if !isCancelled { size = measured }
    }

    private func measure() -> FolderSize? {
        reader(path) { [unowned self] in isCancelled }
    }
}
