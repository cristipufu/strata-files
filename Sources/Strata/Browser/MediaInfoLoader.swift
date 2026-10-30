import Foundation
import UniformTypeIdentifiers

/// Only requested columns read media. Limit concurrent readers, reuse snapshots, and discard work on navigation.
@MainActor final class MediaInfoLoader {
    typealias Reader = @Sendable (FileEntry) async -> MediaInfo
    static let read: Reader = { await MediaInfo.read($0.url, contentType: $0.contentType) }

    var onUpdate: ((FileEntry) -> Void)?
    private var cache: [FileEntry: MediaInfo] = [:]
    private var pending: [FileEntry] = []
    private var requested: Set<FileEntry> = []
    private(set) var tasks: [FileEntry: Task<Void, Never>] = [:]
    private var generation = 0
    private let reader: Reader
    private let copies: CopyProviders

    init(copies: CopyProviders, reader: @escaping Reader = MediaInfoLoader.read) {
        self.copies = copies
        self.reader = reader
    }

    isolated deinit { tasks.values.forEach { $0.cancel() } }

    func cached(_ entry: FileEntry) -> MediaInfo? {
        guard canRead(entry) else { invalidate(entry); return nil }
        return cache[entry]
    }

    func canRead(_ entry: FileEntry) -> Bool { Self.canRead(entry, copies: copies) }

    nonisolated static func canRead(_ entry: FileEntry, copies: CopyProviders) -> Bool {
        !entry.isDirectory && !entry.isSymlink && !copies.isPlaceholder(entry.url)
            && (entry.contentType?.conforms(to: .image) == true || entry.contentType?.conforms(to: .audiovisualContent) == true)
    }

    func request(_ entry: FileEntry) {
        guard canRead(entry) else { invalidate(entry); return }
        guard cache[entry] == nil, requested.insert(entry).inserted else { return }
        pending.append(entry)
        startNext()
    }

    private func invalidate(_ entry: FileEntry) {
        cache[entry] = nil
        pending.removeAll { $0 == entry }
        requested.remove(entry)
        if let task = tasks.removeValue(forKey: entry) {
            task.cancel()
            startNext()
        }
    }

    func cancelPending() {
        generation += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        pending.removeAll()
        requested.removeAll()
        cache.removeAll()
    }

    private func startNext() {
        while tasks.count < 4, let entry = pending.popLast() {
            // Files can become placeholders while waiting behind another read.
            guard canRead(entry) else { requested.remove(entry); continue }
            let gen = generation
            let reader = reader, copies = copies
            tasks[entry] = Task { [weak self] in
                guard !Task.isCancelled else { return }
                // Scheduling the task yields too; its copy must still be readable when execution begins.
                let info = Self.canRead(entry, copies: copies) ? await reader(entry) : nil
                guard let self, !Task.isCancelled, gen == generation else { return }
                tasks[entry] = nil
                requested.remove(entry)
                // A provider may have invalidated its local copy while this read was running.
                if let info, canRead(entry) {
                    cache[entry] = info
                    onUpdate?(entry)
                }
                startNext()
            }
        }
    }
}
