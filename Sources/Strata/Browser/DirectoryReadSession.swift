import Foundation

/// Reading a folder is independent of the AppKit view that presents it. Production keeps the existing disk/remote
/// loader; tests can hold a read open and deliver success or failure in a chosen order.
nonisolated struct DirectoryReader: Sendable {
    static let previewLimit = 50_000
    let read: @Sendable (URL, Bool, ApplicationsFolders) async throws -> Listing
    private let previewRead: @Sendable (URL, Bool, ApplicationsFolders) async throws -> Listing
    private let readBatches: @Sendable (URL, Bool, ApplicationsFolders, @escaping DirectoryLoader.Receive) async throws -> Void
    let invalidate: @Sendable (URL) async -> Void

    static let live = DirectoryReader(copies: .live)

    /// A reader of folders that are what they're asked as (no links among them), handing back their items.
    init(invalidate: @escaping @Sendable (URL) async -> Void = { _ in },
         read: @escaping @Sendable (URL, Bool, ApplicationsFolders) async throws -> [FileEntry]) {
        self.init(invalidate: invalidate, listing: { folder, hidden, applications in
            Listing(folder: folder, entries: try await read(folder, hidden, applications))
        })
    }

    init(invalidate: @escaping @Sendable (URL) async -> Void = { _ in },
         listing: @escaping @Sendable (URL, Bool, ApplicationsFolders) async throws -> Listing,
         batches: (@Sendable (URL, Bool, ApplicationsFolders, @escaping DirectoryLoader.Receive) async throws -> Void)? = nil) {
        self.read = listing
        self.previewRead = listing
        self.invalidate = invalidate
        readBatches = batches ?? { folder, hidden, applications, receive in
            let value = try await listing(folder, hidden, applications)
            try await receive(.init(folder: value.folder, entries: value.entries, complete: true))
        }
    }

    init(copies: CopyProviders) {
        invalidate = { await copies.invalidate($0) }
        read = { folder, hidden, applications in
            try await DirectoryLoader.load(folder, showHidden: hidden, applications: applications, copies: copies)
        }
        previewRead = { folder, hidden, applications in
            try await DirectoryLoader.loadPreview(folder, showHidden: hidden, applications: applications, copies: copies,
                                                  limit: Self.previewLimit)
        }
        readBatches = { folder, hidden, applications, receive in
            try await DirectoryLoader.stream(folder, showHidden: hidden, applications: applications, copies: copies, receive: receive)
        }
    }

    var forPreview: DirectoryReader { DirectoryReader(invalidate: invalidate, listing: previewRead) }

    func load(_ folder: URL, showHidden: Bool, applications: ApplicationsFolders) async throws -> Listing {
        try await read(folder, showHidden, applications)
    }

    func batches(_ folder: URL, showHidden: Bool, applications: ApplicationsFolders, receive: @escaping DirectoryLoader.Receive) async throws {
        try await readBatches(folder, showHidden, applications, receive)
    }
}

/// One presentation's current read. Replaced or detached presentations discard late successes and errors, even if
/// the underlying reader cannot stop its I/O when cancelled. The view owns presentation state and applying entries.
@MainActor final class DirectoryReadSession {
    private let reader: DirectoryReader
    private(set) var generation = 0
    private(set) var task: Task<Void, Never>?

    init(reader: DirectoryReader) { self.reader = reader }

    isolated deinit { task?.cancel() }

    func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
    }

    @discardableResult
    func load(_ folder: URL, showHidden: Bool, applications: ApplicationsFolders,
              invalidateCopy: Bool = false, sortedBy: BrowserOrdering.Snapshot? = nil, after: Task<Void, Never>? = nil,
              progressive: Bool = false, progress: (@MainActor @Sendable (Listing, Int) -> Void)? = nil,
              receive: @escaping (Result<Listing, Error>, Int) -> Void) -> Task<Void, Never> {
        invalidate()
        let generation = generation, reader = reader
        let work = Task { [weak self] in
            let result: Result<Listing, Error>
            // What has to be ready first: the folder's watchers, so no change made while it's read is missed.
            await after?.value
            do {
                if invalidateCopy {
                    await reader.invalidate(folder)
                }
                try Task.checkCancellation()
                if progressive, let sortedBy, let progress {
                    result = .success(try await Self.stream(reader, folder: folder, showHidden: showHidden,
                        applications: applications, sortedBy: sortedBy) { [weak self] listing in
                            await self?.deliverPartial(listing, generation: generation, receive: progress)
                        })
                } else {
                    result = .success(try await Self.read(reader, folder: folder, showHidden: showHidden,
                                                         applications: applications, sortedBy: sortedBy))
                }
            }
            catch { result = .failure(error) }
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            task = nil
            receive(result, generation)
        }
        task = work
        return work
    }

    @concurrent private static func read(_ reader: DirectoryReader, folder: URL, showHidden: Bool,
                                         applications: ApplicationsFolders, sortedBy: BrowserOrdering.Snapshot?) async throws -> Listing {
        let listing = try await reader.load(folder, showHidden: showHidden, applications: applications)
        if let sortedBy {
            return Listing(folder: listing.folder, entries: await BrowserOrdering.sorted(listing.entries, by: sortedBy))
        }
        return listing
    }

    @concurrent private static func stream(_ reader: DirectoryReader, folder: URL, showHidden: Bool,
                                           applications: ApplicationsFolders, sortedBy: BrowserOrdering.Snapshot,
                                           receive: @escaping @Sendable (Listing) async -> Void) async throws -> Listing {
        let accumulator = DirectoryReadAccumulator(sortedBy: sortedBy)
        try await reader.batches(folder, showHidden: showHidden, applications: applications) { batch in
            let listing = try await accumulator.append(batch)
            try Task.checkCancellation()
            if !batch.complete { await receive(listing) }
        }
        return try await accumulator.finish()
    }

    private func deliverPartial(_ listing: Listing, generation: Int, receive: @MainActor (Listing, Int) -> Void) {
        guard self.generation == generation, task != nil, !Task.isCancelled else { return }
        receive(listing, generation)
    }
}

private actor DirectoryReadAccumulator {
    private let sortedBy: BrowserOrdering.Snapshot
    private var folder: URL?
    private var entries: [FileEntry] = []
    private var keys: Set<String> = []
    private var complete = false
    init(sortedBy: BrowserOrdering.Snapshot) { self.sortedBy = sortedBy }

    func append(_ batch: DirectoryLoader.Batch) throws -> Listing {
        try Task.checkCancellation()
        guard !complete, folder == nil || folder == batch.folder else { throw CocoaError(.coderReadCorrupt) }
        var incoming: Set<String> = []
        for entry in batch.entries {
            guard !keys.contains(entry.locationKey), incoming.insert(entry.locationKey).inserted else { throw CocoaError(.coderReadCorrupt) }
        }
        let merged = BrowserOrdering.merged(entries, adding: batch.entries, by: sortedBy)
        try Task.checkCancellation()
        folder = batch.folder; entries = merged; complete = batch.complete
        keys.formUnion(incoming)
        return Listing(folder: batch.folder, entries: entries)
    }
    func finish() throws -> Listing {
        guard complete, let folder else { throw CocoaError(.coderReadCorrupt) }
        return Listing(folder: folder, entries: entries)
    }
}
