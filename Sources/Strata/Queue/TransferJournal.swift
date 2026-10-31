import Foundation

/// Keeps a transfer's completed results together across retries. Results are applied only when a pass finishes,
/// so an existing Undo action never sees a half-updated record while the worker is still running.
package final class TransferJournal {
    private struct Update {
        let source: URL
        let result: TransferItemResult
        let originalKept: Bool
    }

    private var pending: [Update] = []
    private var receipt = Receipt()

    package func append(_ result: TransferItemResult, source: URL, originalKept: Bool) {
        pending.append(Update(source: source, result: result, originalKept: originalKept))
    }

    package func finish(actionName: String, undo: UndoManager?, logHistory: Bool, containers: CreatedFolders, queue: TransferQueue) {
        guard !pending.isEmpty else { return }
        // Undo, Clear History, or eviction can retire the previous record while a retry is working. Its later
        // results belong to a new action; they must not revive the retired record or adopt its other files.
        if !receipt.canExtend(in: queue.history) { receipt = Receipt() }
        for update in pending {
            receipt.apply(update.result, source: update.source, originalKept: update.originalKept)
        }
        pending = []
        TransferUndo.register(receipt: receipt, actionName: actionName, undo: undo, logHistory: logHistory,
                              containers: containers, queue: queue)
    }

    /// Shared by persisted History and the native Undo action. Only completed worker receipts can change ownership.
    package final class Receipt {
        private enum Placement {
            case created(URL)
            case moved(TransferMove)
        }

        private var order: [String] = []
        private var placements: [String: Placement] = [:]
        package private(set) var replaced: [TransferMove] = []
        package let landed: LandedFiles
        package var historyEntry: UUID?
        package var undoRegistered = false
        package var wasUndone = false

        package init(created: [URL] = [], moved: [TransferMove] = [], replaced: [TransferMove] = [], landed: LandedFiles = LandedFiles()) {
            self.landed = landed
            for url in created { place(.created(url), at: url) }
            for move in moved { place(.moved(move), at: move.to) }
            self.replaced = replaced
        }

        package var created: [URL] {
            order.compactMap { if case .created(let url) = placements[$0] { return url }; return nil }
        }

        package var moved: [TransferMove] {
            order.compactMap { if case .moved(let move) = placements[$0] { return move }; return nil }
        }

        package var isEmpty: Bool { placements.isEmpty && replaced.isEmpty }

        package func canExtend(in history: OperationLog) -> Bool {
            guard !wasUndone else { return false }
            guard let historyEntry else { return true }
            return history.canUpdateTransfer(historyEntry)
        }

        fileprivate func apply(_ result: TransferItemResult, source: URL, originalKept: Bool) {
            // A move whose original couldn't be removed may leave its only complete copy here. Until that move
            // finishes, neither the old partial-copy action nor a new one may trash that destination.
            landed.set(originalKept ? nil : result.landed, at: result.destination)
            if result.sourceRemoved {
                place(.moved(TransferMove(from: source, to: result.destination)), at: result.destination)
            } else if !originalKept {
                place(.created(result.destination), at: result.destination)
            }
            if let replaced = result.replaced {
                landed.set(result.replacedIdentity, at: replaced.to)
                self.replaced.append(replaced)
            }
        }

        private func place(_ placement: Placement, at url: URL) {
            if placements[url.path] == nil { order.append(url.path) }
            placements[url.path] = placement
        }

    }
}
