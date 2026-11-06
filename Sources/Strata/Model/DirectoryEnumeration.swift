import Foundation
import Synchronization

// Only the request's current OwnThread read touches the enumerator. Cancellation changes its separate flag; it
// never closes an enumerator under a read that a sleeping disk may still hold.
nonisolated final class DirectoryEnumeration: @unchecked Sendable {
    private static let firstBatchSize = 256
    private static let maximumBatchSize = 8192
    private let cancelled = Mutex(false)
    private let folder: URL
    private let directories: [URL]
    private let options: FileManager.DirectoryEnumerationOptions
    private var current = 0
    private var iterator: FileManager.DirectoryEnumerator?
    private var failure: Error?
    private var batchSize = firstBatchSize

    init(_ requested: URL, showHidden: Bool, applications: ApplicationsFolders) {
        folder = FileEntry.openedFolder(requested)
        directories = applications.directories(for: folder)
        options = showHidden ? [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
            : [.skipsSubdirectoryDescendants, .skipsPackageDescendants, .skipsHiddenFiles]
    }

    func cancel() { cancelled.withLock { $0 = true } }

    func next() throws -> DirectoryLoader.Batch {
        var entries: [FileEntry] = []
        while current < directories.count {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            if iterator == nil {
                failure = nil
                iterator = FileManager.default.enumerator(at: directories[current], includingPropertiesForKeys: FileEntry.resourceKeys,
                    options: options, errorHandler: { [weak self] _, error in self?.failure = error; return false })
                if iterator == nil {
                    if current == 0 { throw CocoaError(.fileReadNoPermission) }
                    current += 1; continue
                }
            }
            let item = autoreleasepool { () -> (exists: Bool, entry: FileEntry?) in
                guard let url = iterator?.nextObject() as? URL else { return (false, nil) }
                return (true, FileEntry(url: url))
            }
            if !item.exists {
                if let failure, current == 0 { throw failure }
                iterator = nil; current += 1
                continue
            }
            if let entry = item.entry { entries.append(entry) }
            if entries.count == batchSize {
                batchSize = min(batchSize * 2, Self.maximumBatchSize)
                return DirectoryLoader.Batch(folder: folder, entries: entries, complete: false)
            }
        }
        return DirectoryLoader.Batch(folder: folder, entries: entries, complete: true)
    }
}
