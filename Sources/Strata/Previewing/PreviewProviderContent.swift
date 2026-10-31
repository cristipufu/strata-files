import Foundation

/// One preview's provider reads. Exploring a folder lists metadata; only an individual selected file is fetched.
@MainActor final class PreviewProviderContent {
    static let limit: Int64 = 32 << 20
    private let copies: CopyProviders
    private var request = UUID()
    private var closed = false
    private var precedingRead: Task<Void, Never>?
    private(set) var task: Task<Void, Never>?
    private(set) var commandTask: Task<Void, Never>?
    private(set) var isLoading = false
    private(set) var error: String?
    var onChange: (() -> Void)?
    var onReady: ((FileEntry) -> Void)?

    init(copies: CopyProviders) { self.copies = copies }
    isolated deinit { cancel() }

    static func permitsAutomaticFetch(_ entry: FileEntry, copies: CopyProviders) -> Bool {
        !entry.isDirectory && !entry.isSymlink && copies.contains(entry.url) && copies.isPlaceholder(entry.url)
            && entry.size.map { $0 >= 0 && $0 <= limit } == true
    }

    func select(_ session: PreviewSession) {
        cancel()
        error = nil
        guard !closed, !session.isClosed,
              let entry = session.selected?.entry ?? (session.selected == nil ? session.root : nil),
              copies.contains(entry.url), copies.isPlaceholder(entry.url), !entry.isDirectory, !entry.isSymlink else { return }
        guard Self.permitsAutomaticFetch(entry, copies: copies) else { error = String(localized: "Open this file to download it. It’s too large for an automatic preview."); onChange?(); return }
        let id = request, generation = session.generation, item = session.selected, copies = copies
        isLoading = true
        task = Task { [weak self, weak session] in
            let result: Result<FileEntry, Error>
            do {
                let parent = await Self.folder(of: entry.url)
                try Task.checkCancellation()
                try await copies.fetch([entry.url])
                try Task.checkCancellation()
                let fetched = try await Self.reread(entry.url, in: parent, copies: copies)
                guard fetched.isRegular else { throw ContainerAPIError.notFound }
                result = .success(fetched)
            } catch { result = .failure(error) }
            guard let self, let session, !Task.isCancelled, request == id, !session.isClosed,
                  session.generation == generation, session.selected === item else { return }
            task = nil
            isLoading = false
            switch result {
            case .success(let fetched): onReady?(fetched)
            case .failure(let error): if !(error is CancellationError) { self.error = copies.message(for: error, about: entry.url) }
            }
            onChange?()
        }
        onChange?()
    }

    /// Copy is explicit and may prepare a chosen folder; a preview selection never takes this path.
    func perform(_ action: PreviewAction, target: PreviewCommandTarget, session: PreviewSession,
                 completion: @escaping (FileEntry, PreviewArchiveLease?) -> Void) {
        guard !closed, target.matches(session), let entry = target.entry, copies.contains(entry.url), !entry.isSymlink else { return }
        let previousTask = task ?? precedingRead, previousCommand = commandTask
        task = nil
        precedingRead = nil
        cancel()
        precedingRead = previousTask
        let id = request, copies = copies
        isLoading = true
        error = nil
        commandTask = Task { [weak self, weak session] in
            // Its folder as it is when the command is asked for, before waiting for what came first.
            let parent = await Self.folder(of: entry.url)
            await previousTask?.value
            await previousCommand?.value
            let result: Result<(FileEntry, PreviewArchiveLease?), Error>
            do {
                try Task.checkCancellation()
                if action == .copy || entry.isDirectory { try await copies.prepareForCopying([entry.url]) }
                else if !entry.isDirectory { try await copies.fetch([entry.url]) }
                try Task.checkCancellation()
                guard await !copies.containsPlaceholderOffMain(in: [entry.url]) else { throw ContainerAPIError.notFound }
                let fresh = try await Self.reread(entry.url, in: parent, copies: copies)
                let lease = action == .copy ? try await PreviewArchiveLease.exporting(entry.url, in: copies.clipboardRoot) : nil
                result = .success((fresh, lease))
            } catch { result = .failure(error) }
            guard let self, let session, !Task.isCancelled, request == id, !session.isClosed, target.isActive(in: session) else { return }
            commandTask = nil
            precedingRead = nil
            isLoading = false
            switch result {
            case .success(let (fresh, lease)): completion(fresh, lease)
            case .failure(let error): if !(error is CancellationError) { self.error = copies.message(for: error, about: entry.url) }
            }
            onChange?()
        }
        onChange?()
    }

    func cancel() {
        request = UUID()
        task?.cancel(); task = nil
        precedingRead?.cancel(); precedingRead = nil
        commandTask?.cancel(); commandTask = nil
        isLoading = false
        onChange?()
    }

    func close() {
        closed = true
        cancel()
        error = nil
        onReady = nil
        onChange = nil
    }

    /// The folder `url` is in, taken before its item is fetched (nil when it can't be), away from the main thread.
    @concurrent private static func folder(of url: URL) async -> ChosenFile? { try? ChosenFile(url.deletingLastPathComponent()) }

    /// `url` as fetched into its copy, read again away from the main thread: still in the folder taken before
    /// (`parent`), and filled in.
    @concurrent private static func reread(_ url: URL, in parent: ChosenFile?, copies: CopyProviders) async throws -> FileEntry {
        guard let parent else { throw ContainerAPIError.notFound }
        try parent.withParent { _, _, _ in }
        guard !copies.isPlaceholder(url), let entry = FileEntry(url: url) else { throw ContainerAPIError.notFound }
        return entry
    }
}
