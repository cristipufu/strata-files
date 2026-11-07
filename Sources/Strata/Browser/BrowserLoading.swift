import Foundation

nonisolated struct VolumeSpace: Sendable, Equatable {
    let free: Int64
    let total: Int64?
    let availableIncludingReclaimable: Int64?

    init(free: Int64, total: Int64? = nil, availableIncludingReclaimable: Int64? = nil) {
        self.free = max(0, free)
        self.total = total
        self.availableIncludingReclaimable = availableIncludingReclaimable
    }
}

/// Owns a browser's folder reads and their lifetime. AppKit decides when to apply a delivered listing, including
/// deferring it while a native name editor is open; a read completing does not mean those entries are on screen.
@MainActor final class BrowserLoading {
    struct Delivery {
        /// The folder the read listed: the one asked for, or where a link or alias to a folder led.
        let folder: URL
        let entries: [FileEntry]
        /// The first listing since the browser went to this folder: where it has arrived.
        let landed: Bool
        let fromTop: Bool
        /// The order the entries were read in, if they were sorted as they were read.
        let sortedBy: BrowserOrdering.Snapshot?
        var complete = true
        var progressive = false
    }

    let reads: DirectoryReadSession
    private let reader: DirectoryReader
    private let capacity: @Sendable (URL) async -> VolumeSpace?
    private let now: @Sendable () -> Date
    private var capacityReadAt: Date?
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
    private(set) var volumeSpace: VolumeSpace?
    private(set) var hasPartialListing = false

    init(reader: DirectoryReader, capacity: @escaping @Sendable (URL) async -> VolumeSpace? = BrowserLoading.readVolumeSpace,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.reader = reader
        self.capacity = capacity
        self.now = now
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
            hasPartialListing = false
            isLoaded = false
            error = nil
            opensAtTop = true
            isLoadingFolder = true
            volumeSpace = nil
            capacityReadAt = nil
        }
    }

    func reload(showHidden: Bool, applications: ApplicationsFolders, scrollToTop: Bool, invalidateCopy: Bool = false,
                sortedBy: BrowserOrdering.Snapshot?, after: Task<Void, Never>? = nil,
                receive: @escaping @MainActor @Sendable (Result<Delivery, Error>) -> Void, capacityChanged: @escaping () -> Void) {
        guard let directory else { return }
        cancelAuxiliaryReads()
        let progressive = opensAtTop
        reads.load(directory, showHidden: showHidden, applications: applications, invalidateCopy: invalidateCopy,
                   sortedBy: sortedBy, after: after, progressive: progressive,
                   progress: { [weak self] listing, _ in
                       self?.deliver(listing, complete: false, progressive: true, scrollToTop: scrollToTop, sortedBy: sortedBy, receive: receive)
                   }) { [weak self] result, generation in
            guard let self else { return }
            isLoadingFolder = false
            switch result {
            case .success(let listing):
                deliver(listing, complete: true, progressive: progressive, scrollToTop: scrollToTop, sortedBy: sortedBy, receive: receive)
            case .failure(let failure):
                error = failure
                isLoaded = true
                receive(.failure(failure))
            }
            // Applying entries can synchronously navigate or replace the folder with results.
            guard reads.generation == generation else { return }
            refreshVolumeSpace(force: true, changed: capacityChanged)
        }
    }

    private func deliver(_ listing: Listing, complete: Bool, progressive: Bool, scrollToTop: Bool, sortedBy: BrowserOrdering.Snapshot?,
                         receive: (Result<Delivery, Error>) -> Void) {
        error = nil
        directory = listing.folder
        isLoadingFolder = false
        let landed = opensAtTop, fromTop = opensAtTop || (scrollToTop && !hasPartialListing)
        opensAtTop = false
        if !complete { hasPartialListing = true }
        receive(.success(Delivery(folder: listing.folder, entries: listing.entries, landed: landed,
                                  fromTop: fromTop, sortedBy: sortedBy, complete: complete, progressive: progressive)))
    }

    func refreshVolumeSpace(force: Bool = false, changed: @escaping () -> Void) {
        guard let directory else { return }
        let instant = now()
        if !force {
            guard capacityTask == nil else { return }
            if let capacityReadAt {
                let elapsed = instant.timeIntervalSince(capacityReadAt)
                if elapsed >= 0, elapsed < 5 { return }
            }
        }
        capacityTask?.cancel()
        capacityReadAt = instant
        let generation = reads.generation, capacity = capacity
        capacityTask = Task { [weak self] in
            let value = await capacity(directory)
            guard let self, !Task.isCancelled, reads.generation == generation, self.directory == directory else { return }
            let didChange = volumeSpace != value
            volumeSpace = value
            capacityTask = nil
            if didChange || force { changed() }
        }
    }

    func applied(preservingChildren: Bool = false, complete: Bool = true) {
        if !preservingChildren { cancelChildren() }
        isLoaded = true
        hasPartialListing = !complete
    }

    func showResults(loaded: Bool = true) {
        invalidate()
        isLoadingFolder = false
        error = nil
        isLoaded = loaded
        hasPartialListing = false
    }

    func invalidate() {
        reads.invalidate()
        cancelAuxiliaryReads()
    }

    private func cancelAuxiliaryReads() {
        if capacityTask != nil { capacityReadAt = nil }
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
            receive((try? result.get())?.entries ?? [])
        }
    }

    @concurrent
    nonisolated static func readVolumeSpace(_ url: URL) async -> VolumeSpace? {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let free = values?.volumeAvailableCapacity else { return nil }
        return VolumeSpace(free: Int64(free), total: values?.volumeTotalCapacity.map(Int64.init),
                           availableIncludingReclaimable: values?.volumeAvailableCapacityForImportantUsage)
    }
}
