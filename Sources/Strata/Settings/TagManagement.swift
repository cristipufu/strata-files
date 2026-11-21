import Foundation
import Combine

/// Owns Settings' search, reviewed plan and Undo. Closing Settings cancels only this session's request.
@MainActor final class TagManagement: ObservableObject {
    enum Phase { case idle, searching, applying }
    struct Review {
        let entry: TagCatalog.Entry
        let replacement: FinderTag?
        let plan: TagStore.EditPlan
    }

    typealias Search = @MainActor (String) async throws -> [URL]
    let store: TagStore
    let undo = UndoManager()
    @Published private(set) var phase = Phase.idle
    var busy: Bool { phase != .idle }
    @Published private(set) var review: Review?
    @Published var error: String?
    private let search: Search
    private(set) var task: Task<Void, Never>?
    private var undoFailure: NSObjectProtocol?
    private var generation = 0

    init(store: TagStore, search: @escaping Search = TagManagement.search) {
        self.store = store
        self.search = search
        undo.groupsByEvent = false
        undoFailure = NotificationCenter.default.addObserver(forName: .tagUndoFailed, object: store, queue: .main) { [weak self] notice in
            let message = (notice.userInfo?["error"] as? Error)?.localizedDescription
            MainActor.assumeIsolated { self?.error = message }
        }
    }

    isolated deinit {
        task?.cancel()
        if let undoFailure { NotificationCenter.default.removeObserver(undoFailure) }
    }

    func cancel() {
        // An in-flight writer must publish its completed work and Undo receipt before another edit can begin.
        if phase == .applying { task?.cancel(); return }
        generation += 1
        task?.cancel()
        task = nil
        phase = .idle
        review = nil
    }

    func prepare(_ entry: TagCatalog.Entry, replacement: FinderTag?) {
        guard phase != .applying else { return }
        cancel()
        do { if let replacement { try store.catalog.validate(replacement, replacing: entry.id) } }
        catch { self.error = error.localizedDescription; return }
        phase = .searching
        let request = generation, search = search, store = store
        task = Task { [weak self] in
            do {
                let urls = try await search(entry.tag.name)
                try Task.checkCancellation()
                let plan = try await store.plan(urls, replacing: entry.tag, with: replacement)
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.review = Review(entry: entry, replacement: replacement, plan: plan)
                self.finished()
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.error = error.localizedDescription
                self.finished()
            }
        }
    }

    func apply() {
        guard !busy, let review else { return }
        // A catalog changed in another window invalidates the reviewed operation as well.
        guard store.catalog.entries.contains(review.entry) else { cancel(); return }
        self.review = nil
        phase = .applying
        let request = generation, store = store, undo = undo
        task = Task { [weak self] in
            var failure: Error?
            do { try await store.apply(review.plan, editing: review.entry.id, replacement: review.replacement, undo: undo) }
            catch is CancellationError {}
            catch { failure = error }
            guard let self, self.generation == request else { return }
            if let failure { self.error = failure.localizedDescription }
            self.finished()
        }
    }

    func undoChange() {
        guard !busy, undo.canUndo else { return }
        undo.undo()
        objectWillChange.send()
    }

    private func finished() { phase = .idle; task = nil }

    private static func search(_ name: String) async throws -> [URL] {
        let predicate = NSPredicate(format: "ANY %K ==[c] %@", "kMDItemUserTags", name)
        let result = await SpotlightSearch.run(predicate, scope: nil, limit: 10_001, timeout: 30)
        try Task.checkCancellation()
        guard !result.timedOut, result.total <= 10_000 else { throw SearchFailure() }
        return result.urls
    }

    private struct SearchFailure: LocalizedError {
        var errorDescription: String? {
            String(localized: "The tag search couldn’t finish. No tags were changed. Try again with fewer matching files.")
        }
    }
}
