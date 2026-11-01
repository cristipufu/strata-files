import AppKit

@MainActor protocol LocalFileCommandContext: AnyObject {
    var navigationRevision: Int { get }
    var targetDirectory: URL? { get }
    var selectedURLs: [URL] { get }
    var rowURLs: [URL] { get }
    var commandWindow: NSWindow? { get }
    var undoManager: UndoManager? { get }
    var commandWork: Task<Void, Never>? { get set }
    func selectWhenShown(_ urls: [URL])
    func renameWhenShown(_ url: URL, in directory: URL)
    func refresh()
    func presentFileError(_ error: Error)
}

/// Local file workflows keep their file owner through completion; their presentation belongs to one pane visit.
final class LocalFileCommands {
    private weak var context: (any LocalFileCommandContext)?
    private let files: FileCommands

    init(context: any LocalFileCommandContext, files: FileCommands) {
        self.context = context
        self.files = files
    }

    @discardableResult
    func newFolder(in directory: URL) -> URL? {
        create(in: directory, using: files.newFolder)
    }

    @discardableResult
    func newFile(in directory: URL) -> URL? {
        create(in: directory, using: files.newFile)
    }

    private func create(in directory: URL, using make: (URL, UndoManager?) throws -> URL) -> URL? {
        guard let context else { return nil }
        let revision = context.navigationRevision
        do {
            let url = try make(directory, context.undoManager)
            guard context.navigationRevision == revision else { return url }
            context.renameWhenShown(url, in: directory)
            return url
        } catch {
            if context.navigationRevision == revision { context.presentFileError(error) }
            return nil
        }
    }

    @discardableResult
    func duplicate(_ urls: [URL]) -> TransferJob? {
        guard let context, !urls.isEmpty else { return nil }
        let revision = context.navigationRevision
        let job = files.duplicate(urls, undo: context.undoManager)
        selectWhenFinished(job, in: nil, revision: revision)
        return job
    }

    @discardableResult
    func transfer(_ urls: [URL], into target: URL, move: Bool) -> TransferJob? {
        guard let context, !urls.isEmpty else { return nil }
        let revision = context.navigationRevision
        let job = files.transfer(urls, into: target, move: move, undo: context.undoManager,
                                 conflicts: .sheet(for: context.commandWindow))
        selectWhenFinished(job, in: target, revision: revision)
        return job
    }

    private func selectWhenFinished(_ job: TransferJob, in target: URL?, revision: Int) {
        job.onFinish = { [weak context] job in
            guard let context, context.navigationRevision == revision else { return }
            let shown = target == nil || target?.lexicallyStandardized == context.targetDirectory?.lexicallyStandardized
            if shown, !job.createdItems.isEmpty { context.selectWhenShown(job.createdItems) }
            else { context.refresh() }
        }
    }

    @discardableResult
    func trash(_ urls: [URL]) -> Task<Void, Never>? {
        guard let context, !urls.isEmpty else { return nil }
        let copies = files.copies
        guard urls.allSatisfy({ FileOps.canTrash(spelled: $0, copies: copies) }) else { Sounds.beep(); return nil }
        let removed = Set(urls.map(\.path))
        let next = TrashedSelection.next(after: removed, in: context.rowURLs)
        let undo = context.undoManager, revision = context.navigationRevision
        let window = context.commandWindow, asked = window != nil
        let files = files
        let work = Task { [weak context, weak window] in
            do {
                try await files.trash(urls, undo: undo)
                guard let context, context.navigationRevision == revision else { return }
                if let next, TrashedSelection.stillTrashed(context.selectedURLs, removed, listed: context.rowURLs) {
                    context.selectWhenShown([next])
                } else {
                    context.refresh()
                }
            } catch let noTrash as FileOps.NoTrash {
                guard let context, context.navigationRevision == revision,
                      !asked || FileAlerts.canStillAsk(in: window) else { return }
                Deletion.confirm(noTrash.urls, in: window, noTrash: true, copies: copies) { [weak context] in
                    guard let context, context.navigationRevision == revision else { return }
                    context.refresh()
                }
                context.refresh()
            } catch {
                guard let context, context.navigationRevision == revision else { return }
                context.presentFileError(error)
                context.refresh()
            }
        }
        context.commandWork = work
        return work
    }
}

extension BrowserViewController: LocalFileCommandContext {
    var rowURLs: [URL] { rows.map(\.url) }
}
