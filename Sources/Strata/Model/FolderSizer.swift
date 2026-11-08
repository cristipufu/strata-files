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
@MainActor package final class FolderSizer {
    private static var cache: [String: FolderSize] = [:]

    private struct Pending {
        let id: UUID
        let url: URL
        let operation: SizeOperation
    }

    package var onUpdate: ((URL) -> Void)?
    private let queue = OperationQueue()
    package typealias Reader = @Sendable (String, @Sendable () -> Bool) -> FolderSize?
    package typealias Delivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let deliver: Delivery
    private let reader: Reader
    private var pending: [String: Pending] = [:]

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
    package var hasPending: Bool { !pending.isEmpty }

    package func isPending(_ url: URL) -> Bool {
        !pending.isEmpty && pending[Self.key(url)] != nil
    }

    package func request(_ url: URL) {
        let key = Self.key(url)
        guard Self.cache[key] == nil, pending[key] == nil else { return }
        let id = UUID()
        let op = SizeOperation(path: url.path, reader: reader)
        pending[key] = Pending(id: id, url: url, operation: op)
        let deliver = deliver
        op.completionBlock = { [unowned op, weak self] in
            let result = op.result
            deliver { [weak self] in self?.finish(url, id: id, result) }
        }
        queue.addOperation(op)
    }

    package func cancel(_ url: URL) {
        guard !pending.isEmpty, let entry = pending.removeValue(forKey: Self.key(url)) else { return }
        entry.operation.cancel()
    }

    package func cancel(where shouldCancel: (URL) -> Bool) {
        guard !pending.isEmpty else { return }
        for (key, entry) in pending where shouldCancel(entry.url) {
            pending.removeValue(forKey: key)
            entry.operation.cancel()
        }
    }

    package func cancelPending() {
        queue.cancelAllOperations()
        pending.removeAll()
    }

    /// Drops cached sizes for `url` and every folder above it, since a change inside changes all of them.
    package static func invalidate(_ url: URL) {
        var current = url.lexicallyStandardized
        while current.path != "/" {
            cache[current.path] = nil
            current = current.deletingLastPathComponent()
        }
    }

    private func finish(_ url: URL, id: UUID, _ result: FolderSize?) {
        let key = Self.key(url)
        guard pending[key]?.id == id else { return }
        pending[key] = nil
        guard let result else { return }
        if Self.cache.count >= 4096 { Self.cache.removeAll(keepingCapacity: true) }
        Self.cache[key] = result
        onUpdate?(url)
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
        var visited = 0
        while let entry = fts_read(fts) {
            visited += 1
            if visited & 63 == 0, isCancelled() { return nil }
            switch Int32(entry.pointee.fts_info) {
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
    var result: FolderSize?
    private let reader: FolderSizer.Reader

    init(path: String, reader: @escaping FolderSizer.Reader) { self.path = path; self.reader = reader }

    override func main() {
        guard !isCancelled else { return }
        let measured = reader(path) { [unowned self] in isCancelled }
        if !isCancelled { result = measured }
    }
}
