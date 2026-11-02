import Foundation

/// Selection work owns one bounded preview lease and one explicit export. Detached completions only clean scratch.
@MainActor final class PreviewArchiveContent {
    private let previewRoot: URL
    private let clipboardRoot: URL
    private var previewID = UUID()
    private var commandID = UUID()
    private weak var archiveAccess: PreviewArchiveAccess?
    private(set) var task: Task<Void, Never>?
    private(set) var commandTask: Task<Void, Never>?
    private(set) var lease: PreviewArchiveLease?
    private(set) var error: Error?
    private(set) var isLoading = false
    var onChange: (() -> Void)?
    var onReady: ((PreviewItem, PreviewArchiveLease) -> Void)?

    init(copies: CopyProviders) {
        clipboardRoot = copies.clipboardRoot
        previewRoot = copies.previewRoot
    }

    isolated deinit { cancel() }

    /// Dragging a previewed page publishes the complete, verified copy and keeps it alive after the panel closes.
    func draggedPage(_ item: PreviewItem, in session: PreviewSession) -> URL? {
        guard !session.isClosed, session.selected === item, case .member = item.source, !item.isDirectory,
              BookFormat.images.contains((item.name as NSString).pathExtension.lowercased()),
              let lease, let source = session.archiveAccess.source else { return nil }
        do {
            let file = try source.open(); defer { try? file.close() }
            try source.verify(file)
            try lease.verify()
            lease.keepForClipboard()
            return lease.url
        } catch { return nil }
    }

    func select(in session: PreviewSession) {
        cancel()
        lease = nil
        error = nil
        guard case .member(_, let path) = session.selected?.source, let item = session.selected,
              !item.isDirectory, session.archiveAccess.source != nil else { return }
        let id = previewID, generation = session.generation, access = session.archiveAccess
        // Pages that can be dragged share the clipboard cache’s next-launch cleanup.
        let root = BookFormat.images.contains((item.name as NSString).pathExtension.lowercased()) ? clipboardRoot : previewRoot
        archiveAccess = access
        isLoading = true
        task = Task { [weak self, weak session] in
            let result: Result<PreviewArchiveLease, Error>
            do { result = .success(try await access.copy(member: path, into: root, cached: true)) }
            catch { result = .failure(error) }
            guard let self, let session, !Task.isCancelled, previewID == id,
                  !session.isClosed, session.generation == generation, session.selected === item else { return }
            task = nil
            archiveAccess = nil
            isLoading = false
            switch result {
            case .success(let lease): self.lease = lease; onReady?(item, lease)
            case .failure(let error): if !(error is CancellationError) { self.error = error }
            }
            onChange?()
        }
        onChange?()
    }

    func export(_ target: PreviewCommandTarget, session: PreviewSession, completion: @escaping (PreviewArchiveLease) -> Void) {
        guard target.matches(session), case .member(_, let path) = target.item?.source,
              let source = session.archiveAccess.source else { return }
        let previousTask = task, previousCommand = commandTask
        cancel()
        let id = commandID, access = session.archiveAccess, root = clipboardRoot, directory = target.item?.isDirectory == true
        archiveAccess = access
        isLoading = true
        error = nil
        commandTask = Task { [weak self, weak session] in
            // Finish both the selected preview and any older export before starting another command.
            await previousTask?.value
            await previousCommand?.value
            let result: Result<PreviewArchiveLease, Error>
            do {
                try Task.checkCancellation()
                if directory {
                    let records = try await access.read(member: path, directory: true)
                    result = .success(try await PreviewArchiveLease.materialize(records, member: path, in: root,
                                                                                source: source))
                } else {
                    result = .success(try await access.copy(member: path, into: root, cached: false))
                }
            } catch { result = .failure(error) }
            guard let self, let session, !Task.isCancelled, commandID == id, target.matches(session) else { return }
            commandTask = nil
            archiveAccess = nil
            isLoading = false
            switch result {
            case .success(let lease):
                completion(lease)
                if commandID == id, target.matches(session), !directory, let item = target.item {
                    onReady?(item, lease)
                    self.lease = lease
                }
            case .failure(let error): if !(error is CancellationError) { self.error = error }
            }
            onChange?()
        }
        onChange?()
    }

    func cancel() {
        let access = archiveAccess
        archiveAccess = nil
        previewID = UUID()
        commandID = UUID()
        task?.cancel(); task = nil
        commandTask?.cancel(); commandTask = nil
        isLoading = false
        // Release the sheet on this actor before a replacement can request another password.
        access?.cancelPassword?()
        onChange?()
    }

    func close() {
        cancel()
        lease = nil
        error = nil
        onReady = nil
        onChange = nil
    }
}
