import Foundation

/// Two workers at a time. Space previews (covers, page grids, chapters) share one allowance; the preview pane's listings
/// and the surveys before Extract have one each, so none waits behind another. Cancellation drains the actual worker
/// before returning its slot.
package actor ArchiveReadAllowance {
    package static let shared = ArchiveReadAllowance()
    package static let listings = ArchiveReadAllowance()
    package static let surveys = ArchiveReadAllowance()
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    package func enter(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
    }
    package func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    package func leave() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume() }
    }
}
