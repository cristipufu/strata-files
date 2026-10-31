import Foundation

/// Searches a folder the index doesn't cover (outside your home folder and Applications, another disk, a folder left
/// out of the index) by reading it into a temporary store with the index's own scanner and running the index's own
/// search over that, so the same queries match and rank the same way. Matches can be read while the scan runs.
///
/// One scan serves every search typed in the same folder for a while, so refining a query doesn't read the folder again.
package nonisolated final class FolderSearch: @unchecked Sendable {
    /// Indexed folders inside the searched one (your home folder inside `/Users`): not read again, taken from the index.
    package struct IndexedParts: Sendable {
        package struct Root: Sendable {
            package let path: String
            /// Levels below the searched folder.
            package let depth: Int
        }

        package let store: IndexStore
        package let roots: [Root]
    }

    package let folder: String
    private let indexed: IndexedParts?
    private let store = IndexStore()
    private let scanner: IndexScanner
    /// The index's part of the answer, per query: it doesn't change while the folder is read.
    private let indexResults = IndexSearch.ResultCache()
    private let lock = NSLock()
    private var finished = false
    private var finishedAt: Date?

    package init(folder: URL, indexed: IndexedParts? = nil) {
        self.folder = folder.resolvingSymlinksInPath().standardizedFileURL.path
        self.indexed = indexed
        // Only the index's own folders are skipped (they still show up as entries). Build and cache folders count as
        // noise, like in the index.
        scanner = IndexScanner(store: store, excluded: Set(indexed?.roots.map(\.path) ?? []), noiseFolders: [])
    }

    /// Items read so far.
    package var scannedCount: Int { scanner.scannedCount }

    /// Whether part of the answer comes from the index (an indexed folder inside this one).
    package var usesIndex: Bool { indexed != nil }

    package var isFinished: Bool {
        lock.withLock { finished }
    }

    /// Whether another search in `folder` can use this scan instead of reading the folder again: while it's still
    /// reading, and for a minute after it's done (counted from the end, so a slow network share stays reusable too).
    package func canServe(_ folder: URL) -> Bool {
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == self.folder, !scanner.isCancelled else { return false }
        return lock.withLock { finishedAt.map { Date().timeIntervalSince($0) < 60 } ?? true }
    }

    package func cancel() {
        scanner.cancel()
    }

    /// Starts reading the folder on all cores (the scanner doesn't cross into other disks), then totals folder sizes so
    /// size filters work on folders too. The scan blocks while it reads, so it runs on its own queue rather than in the
    /// task pool.
    package func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let root = store.write { store in store.addRoot(path: folder, mtime: 0) }
            scanner.scan([(id: root, path: folder)], threads: IndexScanner.threadCount(for: folder))
            if !scanner.isCancelled {
                // Skipped folders were listed but not read: their totals come from the index, so sizes above them add up.
                let totals = indexed.map { parts in
                    parts.store.read { store in
                        parts.roots.compactMap { root in
                            store.lookup(root.path).map { (root.path, store.size[Int($0)], store.fileCount[Int($0)]) }
                        }
                    }
                } ?? []
                store.write { store in
                    for (path, size, files) in totals {
                        guard let id = store.lookup(path) else { continue }
                        store.size[Int(id)] = size
                        store.fileCount[Int(id)] = files
                    }
                    store.aggregate()
                }
            }
            lock.withLock {
                finished = true
                finishedAt = Date()
            }
        }
    }

    /// The best `limit` matches read so far (all of them once `isFinished`), merged with the index's for the parts it
    /// has.
    package func search(_ text: String, limit: Int = 500) async -> (hits: [IndexHit], total: Int, interpretation: SearchFilter?) {
        var sources = [IndexSearch.Source(store: store, scopePath: nil, depth: 0)]
        if let indexed {
            sources += indexed.roots.map {
                IndexSearch.Source(store: indexed.store, scopePath: $0.path, depth: $0.depth, cache: indexResults)
            }
        }
        return await IndexSearch.understand(text, sources: sources, limit: limit)
    }
}
