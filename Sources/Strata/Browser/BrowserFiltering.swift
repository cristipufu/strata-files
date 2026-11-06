import Foundation

/// What's typed to filter a pane's rows. A small folder shows its matches at once; a big one is matched away from the
/// main thread, and newer text, leaving the folder or showing results replaces the match still being worked out, so a
/// late match never shows over a newer one.
@MainActor final class BrowserFiltering {
    /// Folders with more items are matched away from the main thread.
    static let matchedAwayAbove = 2_000

    private let listing: BrowserListing
    private let show: (String, Bool) -> Void
    private let canPublish: () -> Bool
    private var deferredText: String?
    /// A big folder's rows being matched against what was typed, away from the main thread, and that text.
    private(set) var matching: (text: String, task: Task<Void, Never>)?

    /// `show`: the rows now show the matches for this text.
    init(listing: BrowserListing, canPublish: @escaping () -> Bool = { true }, show: @escaping (String, Bool) -> Void) {
        self.listing = listing
        self.canPublish = canPublish
        self.show = show
    }

    isolated deinit {
        matching?.task.cancel()
    }

    /// What was typed to filter the rows by: they show it once it's matched, in a big folder a moment later.
    var typed: String { matching?.text ?? deferredText ?? listing.filter }

    func set(_ text: String) {
        guard text != listing.filter else { return cancel() }
        match(text, preservingSelection: false)
    }

    func refresh() {
        match(typed, preservingSelection: true)
    }

    func resumeDeferredMatch() {
        if deferredText != nil { refresh() }
    }

    private func match(_ text: String, preservingSelection: Bool) {
        cancel()
        guard !text.isEmpty, listing.nodes.count > Self.matchedAwayAbove else {
            listing.setFilter(text)
            return show(text, preservingSelection)
        }
        let listing = listing
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            guard let matches = await listing.matches(for: text), !Task.isCancelled, let self else { return }
            matching = nil
            guard canPublish() else { deferredText = text; return }
            // The rows changed meanwhile (a refresh): matched again against them.
            guard listing.show(matches) else { return match(text, preservingSelection: preservingSelection) }
            show(text, preservingSelection)
        }
        matching = (text, task)
    }

    func cancel() {
        matching?.task.cancel()
        matching = nil
        deferredText = nil
    }

    /// Return acts on the rows for what was typed: a match still being worked out is made now, once.
    func finish() {
        guard let text = matching?.text else { return }
        cancel()
        listing.setFilter(text)
        show(text, false)
    }

    /// No filter at all, without showing anything: the rows are about to change (another folder, results).
    func clear() {
        cancel()
        listing.setFilter("")
    }
}
