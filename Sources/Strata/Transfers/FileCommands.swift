import Foundation

/// Executes local file commands with one owner for History, preferences, copy routing and transfers. AppKit keeps
/// selection, confirmation sheets and presentation; this layer receives the captured items and never rereads a view.
package final class FileCommands {
    package let transfers: TransferQueue
    package var history: OperationLog { transfers.history }
    package var copies: CopyProviders { transfers.copies }

    package init(transfers: TransferQueue) { self.transfers = transfers }

    package func newFolder(in directory: URL, undo: UndoManager?) throws -> URL {
        try FileOps.newFolder(in: directory, undo: undo, copies: copies, history: history)
    }

    package func newFile(in directory: URL, undo: UndoManager?) throws -> URL {
        try FileOps.newFile(in: directory, extension: transfers.preferences.newFileExtension, undo: undo,
                            copies: copies, history: history)
    }

    package func rename(_ url: URL, to name: String, undo: UndoManager?) async throws -> URL {
        try await FileOps.rename(url, to: name, undo: undo, copies: copies, history: history)
    }

    package func trash(_ urls: [URL], undo: UndoManager?) async throws {
        try await FileOps.trashInBackground(urls, undo: undo, copies: copies, history: history)
    }

    package func duplicate(_ urls: [URL], undo: UndoManager?) -> TransferJob {
        transfers.enqueue(moves: urls.map { TransferMove(from: $0, to: $0) }, mode: .copy,
                          undo: undo, conflicts: .keepBoth)
    }

    package func transfer(_ urls: [URL], into directory: URL, move: Bool, undo: UndoManager?,
                  conflicts: ConflictResolver) -> TransferJob {
        transfers.enqueue(urls, to: directory, mode: move ? .move : .copy, undo: undo, conflicts: conflicts)
    }
}
