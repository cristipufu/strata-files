import Foundation

/// Executes local file commands with one owner for History, preferences, copy routing and transfers. AppKit keeps
/// selection, confirmation sheets and presentation; this layer receives the captured items and never rereads a view.
final class FileCommands {
    let transfers: TransferQueue
    var history: OperationLog { transfers.history }
    var copies: CopyProviders { transfers.copies }

    init(transfers: TransferQueue) { self.transfers = transfers }

    func newFolder(in directory: URL, undo: UndoManager?) throws -> URL {
        try FileOps.newFolder(in: directory, undo: undo, copies: copies, history: history)
    }

    func newFile(in directory: URL, undo: UndoManager?) throws -> URL {
        try FileOps.newFile(in: directory, extension: transfers.preferences.newFileExtension, undo: undo,
                            copies: copies, history: history)
    }

    func rename(_ url: URL, to name: String, undo: UndoManager?) async throws -> URL {
        try await FileOps.rename(url, to: name, undo: undo, copies: copies, history: history)
    }

    func trash(_ urls: [URL], undo: UndoManager?) async throws {
        try await FileOps.trashInBackground(urls, undo: undo, copies: copies, history: history)
    }

    func duplicate(_ urls: [URL], undo: UndoManager?) -> TransferJob {
        transfers.enqueue(moves: urls.map { TransferMove(from: $0, to: $0) }, mode: .copy,
                          undo: undo, conflicts: .keepBoth)
    }

    func transfer(_ urls: [URL], into directory: URL, move: Bool, undo: UndoManager?,
                  conflicts: ConflictResolver) -> TransferJob {
        transfers.enqueue(urls, to: directory, mode: move ? .move : .copy, undo: undo, conflicts: conflicts)
    }

    func apply(_ plan: Plan, actionName: String, undo: UndoManager?) async -> PlanExecutor.Outcome {
        await PlanExecutor.apply(plan, actionName: actionName, undo: undo, copies: copies, history: history)
    }
}
