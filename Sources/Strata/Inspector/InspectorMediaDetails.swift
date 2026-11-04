import Foundation
import StrataFiles
import StrataModel
import UniformTypeIdentifiers

@MainActor final class InspectorMediaDetails {
    private struct Key: Equatable {
        let url: URL
        let modified: Date?
        let size: Int64?
    }

    private let copies: CopyProviders
    private let read: MediaDetails.Reader
    private var key: Key?
    private var revision = 0
    private(set) var task: Task<Void, Never>?
    private(set) var value: MediaDetails?
    var url: URL? { key?.url }
    var onChange: (() -> Void)?

    init(copies: CopyProviders, read: @escaping MediaDetails.Reader) {
        self.copies = copies
        self.read = read
    }

    isolated deinit { task?.cancel() }

    func show(_ entry: FileEntry?) {
        guard let entry, entry.isRegular, !entry.isSymlink, !copies.isPlaceholder(entry.url),
              entry.contentType.map({ $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) }) == true else {
            cancel()
            return
        }
        let key = Key(url: entry.url, modified: entry.modified, size: entry.size)
        guard self.key != key else { return }
        let previous = task
        revision += 1
        value = nil
        self.key = key
        let read = read, revision = revision, url = entry.url, type = entry.contentType
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let value = await read(url, type)
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            task = nil
            guard !copies.isPlaceholder(url) else { self.key = nil; self.value = nil; return }
            self.value = value
            onChange?()
        }
        previous?.cancel()
    }

    func cancel() {
        revision += 1
        let previous = task
        task = nil
        key = nil
        value = nil
        previous?.cancel()
    }
}
