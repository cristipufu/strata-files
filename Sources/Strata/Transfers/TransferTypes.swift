import AppKit

package nonisolated enum TransferMode: Sendable {
    case copy, move
}

package nonisolated enum TransferState: Sendable {
    case queued, scanning, running, paused, finished, failed, cancelled

    /// Still has work ahead of it (or is waiting on the user).
    package var isActive: Bool {
        switch self {
        case .queued, .scanning, .running, .paused: true
        case .finished, .failed, .cancelled: false
        }
    }
}

/// What to do with an item whose name is already taken at the destination.
package nonisolated enum ConflictDecision: Sendable {
    /// Move the existing item to the Trash, then write the incoming one in its place.
    case replace
    /// Write the incoming item next to the existing one as `name 2.ext`.
    case keepBoth
    /// Leave the existing item alone and don't transfer this one.
    case skip
    /// Copying a folder onto a folder: add what's missing and merge subfolders; where both have an item of the same
    /// name, the newer one wins (the older goes to the Trash).
    case merge
    /// Cancel the whole job.
    case stop
}

package nonisolated struct ConflictResolution: Sendable {
    package var decision: ConflictDecision
    /// Use the same decision for every remaining conflict in this job without asking again.
    package var applyToAll: Bool = false

    package init(decision: ConflictDecision, applyToAll: Bool = false) {
        self.decision = decision
        self.applyToAll = applyToAll
    }
}

package nonisolated struct TransferConflict: Sendable {
    package let mode: TransferMode
    /// The item being copied or moved.
    package let source: URL
    /// The item already at the destination.
    package let existing: URL
    /// Conflicts still to be decided in this job, this one included.
    package let remaining: Int

    /// Merge is offered when copying a folder onto a folder (like Finder's Option-drag).
    package var canMerge: Bool {
        mode == .copy && TransferEngine.isPlainFolder(source) && TransferEngine.isPlainFolder(existing)
    }
}

/// Answers conflicts for a job. Use `.sheet(for:)` in the UI; `.keepBoth` never asks.
package struct ConflictResolver {
    package let resolve: @MainActor (TransferConflict) async -> ConflictResolution

    package init(_ resolve: @escaping @MainActor (TransferConflict) async -> ConflictResolution) {
        self.resolve = resolve
    }

    package static let keepBoth = ConflictResolver { _ in ConflictResolution(decision: .keepBoth, applyToAll: true) }
    package static let skip = ConflictResolver { _ in ConflictResolution(decision: .skip, applyToAll: true) }
    package static let replace = ConflictResolver { _ in ConflictResolution(decision: .replace, applyToAll: true) }
}

/// One thing that went wrong. The job carries on with everything else and can retry these afterwards.
package nonisolated struct TransferFailure: Sendable {
    package enum Stage: Sendable {
        /// The whole item: missing source, can't trash the item it replaces, can't create the destination…
        case item
        /// One file or folder inside the item couldn't be copied.
        case copy
        /// The copy's contents differ from the original.
        case verify
        /// Everything was copied, but the original couldn't be removed afterwards (cross-volume moves).
        case removeSource
    }

    /// Index of the top-level item in the job.
    package let item: Int
    package let stage: Stage
    package let source: URL
    package let destination: URL?
    package let message: String
    package var retryTarget: TransferRetryTarget?

    package var displayName: String { source.lastPathComponent }
}

package nonisolated struct TransferMove: Sendable, Equatable {
    package var from: URL
    package var to: URL

    package init(from: URL, to: URL) {
        self.from = from
        self.to = to
    }

    package var reversed: TransferMove { TransferMove(from: to, to: from) }
}
