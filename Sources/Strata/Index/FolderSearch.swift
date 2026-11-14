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
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var finished = false
    private var finishedAt: Date?

    /// Where a scan reads unless told otherwise: it blocks while it reads, so it runs on a queue rather than in the task
    /// pool.
    package static let scanQueue = DispatchQueue.global(qos: .userInitiated)

    /// `path`: where the folder searched really is (`FolderSearch.path(of:)`).
    /// Where `folder` really is, its links followed: asked of its disk, away from the main thread.
    @concurrent package static func path(of folder: URL) async -> String {
        folder.resolvingSymlinksInPath().lexicallyStandardized.path
    }

    /// `leftOut`: folders inside the one searched that are not to be read (`FileIndex.foldersLeftOut`).
    package init(path: String, indexed: IndexedParts?, leavingOut leftOut: Set<String> = [], queue: DispatchQueue) {
        folder = path
        self.indexed = indexed
        self.queue = queue
        // The index's own folders are skipped, and those it is told to leave out (they still show up as entries).
        // Build and cache folders count as noise, like in the index.
        scanner = IndexScanner(store: store, excluded: leftOut.union(indexed?.roots.map(\.path) ?? []), noiseFolders: [])
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
    /// Whether this scan can answer a search of the folder at `path` (`FolderSearch.path(of:)`).
    package func canServe(_ path: String) -> Bool {
        guard path == folder, !scanner.isCancelled else { return false }
        return lock.withLock { finishedAt.map { Date().timeIntervalSince($0) < 60 } ?? true }
    }

    package func cancel() {
        scanner.cancel()
    }

    /// Starts reading the folder on all cores (the scanner doesn't cross into other disks), then totals folder sizes so
    /// size filters work on folders too.
    package func start() {
        queue.async { [self] in
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
