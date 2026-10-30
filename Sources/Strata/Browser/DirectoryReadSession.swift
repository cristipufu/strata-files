import Foundation

/// Reading a folder is independent of the AppKit view that presents it. Production keeps the existing disk/remote
/// loader; tests can hold a read open and deliver success or failure in a chosen order.
nonisolated struct DirectoryReader: Sendable {
    static let previewLimit = 50_000
    let read: @Sendable (URL, Bool, ApplicationsFolders) async throws -> [FileEntry]
    private let previewRead: @Sendable (URL, Bool, ApplicationsFolders) async throws -> [FileEntry]
    let invalidate: @Sendable (URL) async -> Void

    static let live = DirectoryReader(copies: .live)

    init(invalidate: @escaping @Sendable (URL) async -> Void = { _ in },
         read: @escaping @Sendable (URL, Bool, ApplicationsFolders) async throws -> [FileEntry]) {
        self.read = read
        self.previewRead = read
        self.invalidate = invalidate
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
    }

    var forPreview: DirectoryReader { DirectoryReader(invalidate: invalidate, read: previewRead) }

    func load(_ folder: URL, showHidden: Bool, applications: ApplicationsFolders) async throws -> [FileEntry] {
        try await read(folder, showHidden, applications)
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
              invalidateCopy: Bool = false, sortedBy: BrowserOrdering.Snapshot? = nil,
              receive: @escaping (Result<[FileEntry], Error>, Int) -> Void) -> Task<Void, Never> {
        invalidate()
        let generation = generation, reader = reader
        let work = Task { [weak self] in
            let result: Result<[FileEntry], Error>
            do {
                if invalidateCopy {
                    await reader.invalidate(folder)
                    try Task.checkCancellation()
                }
                let entries = try await reader.load(folder, showHidden: showHidden, applications: applications)
                // Sorted here, away from the main thread: a folder of thousands of files took the list seconds.
                if let sortedBy {
                    result = .success(await BrowserOrdering.sorted(entries, by: sortedBy))
                } else {
                    result = .success(entries)
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
}
