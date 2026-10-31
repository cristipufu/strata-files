import Foundation
import StrataSupport

nonisolated package struct FolderSize: Sendable {
    package let bytes: Int64
    package let files: Int

    package init(bytes: Int64, files: Int) {
        self.bytes = bytes
        self.files = files
    }
}

/// Computes folder sizes in the background. Results are shared by every window; each browser owns
/// its own queue so leaving a folder cancels only that browser's pending walks.
package final class FolderSizer {
    private static var cache: [URL: FolderSize] = [:]

    package var onUpdate: ((URL) -> Void)?
    private let queue = OperationQueue()
    private var pending: Set<URL> = []

    package init() {
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
    }

    package static func cached(_ url: URL) -> FolderSize? { cache[url] }

    package func request(_ url: URL) {
        guard Self.cache[url] == nil, pending.insert(url).inserted else { return }
        let op = SizeOperation(path: url.path)
        op.completionBlock = { [unowned op, weak self] in
            let result = op.result
            Task { @MainActor in self?.finish(url, result) }
        }
        queue.addOperation(op)
    }

    package func cancelPending() {
        queue.cancelAllOperations()
        pending.removeAll()
    }

    /// Drops cached sizes for `url` and every folder above it, since a change inside changes all of them.
    package static func invalidate(_ url: URL) {
        var current = url.standardizedFileURL
        while current.path != "/" {
            cache[current] = nil
            current = current.deletingLastPathComponent()
        }
    }

    private func finish(_ url: URL, _ result: FolderSize?) {
        pending.remove(url)
        guard let result else { return }
        Self.cache[url] = result
        onUpdate?(url)
    }

    nonisolated package static func measure(_ path: String, isCancelled: () -> Bool) -> FolderSize? {
        guard let cpath = strdup(path) else { return nil }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }
        var bytes: Int64 = 0
        var files = 0
        var visited = 0
        while let entry = fts_read(fts) {
            visited += 1
            if visited & 2047 == 0, isCancelled() { return nil }
            switch Int32(entry.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let stat = entry.pointee.fts_statp { bytes = bytes.saturatingAdd(max(0, Int64(stat.pointee.st_size))) }
                files += 1
            default:
                break
            }
        }
        return FolderSize(bytes: bytes, files: files)
    }
}

nonisolated private final class SizeOperation: Operation, @unchecked Sendable {
    let path: String
    var result: FolderSize?

    init(path: String) { self.path = path }

    override func main() {
        result = FolderSizer.measure(path) { [unowned self] in isCancelled }
    }
}
