import Foundation

/// Owns an expanded tree's native directory watchers and its share of the window-wide allowance.
@MainActor final class FolderWatchers {
    final class Budget {
        static let shared = Budget(limit: 96)
        let limit: Int
        fileprivate(set) var count = 0

        init(limit: Int) { self.limit = max(0, limit) }

        fileprivate func fits(_ requested: Int) -> Bool { requested <= limit - count }
    }

    private let budget: Budget
    private let limit: Int
    private let directories: ApplicationsFolders
    private var sources: [String: [DirectoryWatcher]] = [:]
    private var order: [String] = []

    init(budget: Budget, limit: Int = 48, directories: ApplicationsFolders = .standard) {
        self.budget = budget
        self.limit = max(0, limit)
        self.directories = directories
    }

    isolated deinit { removeAll() }

    func contains(_ url: URL) -> Bool { sources[url.fileViewKey] != nil }

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        let key = url.fileViewKey
        guard limit > 0, sources[key] == nil else { return }
        let folders = directories.directories(for: url)
        // Only this tree's oldest registrations can be replaced; another window keeps its watchers.
        while sources.count >= limit || !budget.fits(folders.count) {
            guard let oldest = order.first else { return }
            remove(oldest)
        }
        let opened = folders.compactMap { DirectoryWatcher(url: $0, onChange: onChange) }
        guard !opened.isEmpty else { return }
        sources[key] = opened
        order.append(key)
        budget.count += opened.count
    }

    /// Stops watching the folder and its descendants, including the physical system Applications tree.
    func remove(under url: URL) {
        let roots = directories.directories(for: url).map(\.fileViewKey)
        let removed = sources.keys.filter { path in
            roots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        }
        for key in removed { remove(key) }
    }

    func removeAll() {
        budget.count -= sources.values.reduce(0) { $0 + $1.count }
        sources.removeAll()
        order.removeAll()
    }

    private func remove(_ key: String) {
        guard let removed = sources.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        budget.count -= removed.count
    }
}
