import Foundation

/// Owns a browser's folder reads and their lifetime. AppKit decides when to apply a delivered listing, including
/// deferring it while a native name editor is open; a read completing does not mean those entries are on screen.
@MainActor final class BrowserLoading {
    struct Delivery {
        let entries: [FileEntry]
        let fromTop: Bool
        /// The order the entries were read in, if they were sorted as they were read.
        let sortedBy: BrowserOrdering.Snapshot?
    }

    let reads: DirectoryReadSession
    private let reader: DirectoryReader
    private let capacity: @Sendable (URL) async -> Int64?
    private(set) var capacityTask: Task<Void, Never>?
    private struct ChildRead {
        let node: FileNode
        let session: DirectoryReadSession
    }
    private var children: [ObjectIdentifier: ChildRead] = [:]
    // Refresh may overtake the first read. Its eventual entries still start at the new folder’s top.
    private var opensAtTop = false
    private(set) var directory: URL?
    private(set) var error: Error?
    private(set) var isLoaded = false
    private(set) var isLoadingFolder = false
    private(set) var availableCapacity: Int64?

    init(reader: DirectoryReader, capacity: @escaping @Sendable (URL) async -> Int64? = BrowserLoading.freeSpace) {
        self.reader = reader
        self.capacity = capacity
        reads = DirectoryReadSession(reader: reader)
    }

    isolated deinit {
        reads.invalidate()
        capacityTask?.cancel()
        for child in children.values { child.session.invalidate() }
    }

    func navigate(to directory: URL, newFolder: Bool) {
        self.directory = directory
        if newFolder {
            opensAtTop = true
            isLoadingFolder = true
            availableCapacity = nil
        }
    }

    func reload(showHidden: Bool, applications: ApplicationsFolders, scrollToTop: Bool, invalidateCopy: Bool = false,
                sortedBy: BrowserOrdering.Snapshot?,
                receive: @escaping (Result<Delivery, Error>) -> Void, capacityChanged: @escaping () -> Void) {
        guard let directory else { return }
        cancelAuxiliaryReads()
        reads.load(directory, showHidden: showHidden, applications: applications, invalidateCopy: invalidateCopy,
                   sortedBy: sortedBy) { [weak self] result, generation in
            guard let self else { return }
            isLoadingFolder = false
            switch result {
            case .success(let entries):
                error = nil
                let fromTop = scrollToTop || opensAtTop
                opensAtTop = false
                receive(.success(Delivery(entries: entries, fromTop: fromTop, sortedBy: sortedBy)))
            case .failure(let failure):
                error = failure
                isLoaded = true
                receive(.failure(failure))
            }
            // Applying entries can synchronously navigate or replace the folder with results.
            guard reads.generation == generation else { return }
            let capacity = capacity
            capacityTask = Task { [weak self] in
                let value = await capacity(directory)
                guard let self, !Task.isCancelled, reads.generation == generation else { return }
                availableCapacity = value
                capacityTask = nil
                capacityChanged()
            }
        }
    }

    func applied() {
        cancelChildren()
        isLoaded = true
    }

    func showResults(loaded: Bool = true) {
        invalidate()
        isLoadingFolder = false
        error = nil
        isLoaded = loaded
    }

    func invalidate() {
        reads.invalidate()
        cancelAuxiliaryReads()
    }

    private func cancelAuxiliaryReads() {
        capacityTask?.cancel()
        capacityTask = nil
        cancelChildren()
    }

    private func cancelChildren() {
        for child in children.values { child.session.invalidate() }
        children.removeAll()
    }

    /// Coalesce native outline requests by row identity, not path. A replaced row can use the same path while an
    /// earlier read finishes. Root refreshes invalidate every child session before reusing any surviving rows.
    @discardableResult
    func loadChildren(of node: FileNode, showHidden: Bool, applications: ApplicationsFolders,
                      receive: @escaping ([FileEntry]) -> Void) -> Task<Void, Never> {
        let key = ObjectIdentifier(node)
        if let work = children[key]?.session.task { return work }
        let session = DirectoryReadSession(reader: reader)
        children[key] = ChildRead(node: node, session: session)
        return session.load(node.url, showHidden: showHidden, applications: applications) { [weak self, weak session] result, _ in
            guard let self, let session, children[key]?.session === session else { return }
            children.removeValue(forKey: key)
            receive((try? result.get()) ?? [])
        }
    }

    @concurrent
    nonisolated static func freeSpace(_ url: URL) async -> Int64? {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
