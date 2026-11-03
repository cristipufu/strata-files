import Foundation
import StrataSupport

/// Two workers at a time. Space previews (covers, page grids, chapters) share one allowance; the preview pane's
/// listings, the surveys before Extract and copies of one file have one each, so none waits behind another.
/// Cancellation drains the actual worker before returning its slot.
package actor ArchiveReadAllowance {
    package static let shared = ArchiveReadAllowance()
    package static let listings = ArchiveReadAllowance()
    package static let surveys = ArchiveReadAllowance()
    package static let copies = ArchiveReadAllowance()
    private let slots = WorkAllowance(limit: 2)
    package func enter(_ id: UUID) async throws { try await slots.enter(id) }
    package func cancel(_ id: UUID) async { await slots.cancel(id) }
    package func leave(_ id: UUID) async { await slots.leave(id) }
}
