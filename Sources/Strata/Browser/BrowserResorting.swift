import Foundation

/// Sorting a pane's rows again once metadata settles (folder sizes, tags or media details arriving while sorted by
/// them): one pass a moment after the last arrival, held while a name is edited in place and run when the edit ends.
@MainActor final class BrowserResorting {
    private var work: DispatchWorkItem?
    private var heldForEditing = false
    private let resort: () -> Void

    init(resort: @escaping () -> Void) {
        self.resort = resort
    }

    isolated deinit {
        work?.cancel()
    }

    var isScheduled: Bool { work != nil }

    func schedule() {
        work?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.work = nil
                self?.resort()
            }
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    /// A pass came while a name is edited in place: it runs once the edit ends.
    func holdForEditing() {
        heldForEditing = true
    }

    func editingEnded() {
        guard heldForEditing else { return }
        heldForEditing = false
        resort()
    }
}
