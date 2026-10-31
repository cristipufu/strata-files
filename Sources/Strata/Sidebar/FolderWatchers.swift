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

    /// A folder's watchers, or its share of the allowance held while its folders open away from the main thread.
    private enum Registration {
        case opening(token: UUID, task: Task<Void, Never>, reserved: Int)
        case watching([DirectoryWatcher])

        var held: Int {
            switch self {
            case .opening(_, _, let reserved): reserved
            case .watching(let watchers): watchers.count
            }
        }
    }

    private let budget: Budget
    private let limit: Int
    private let directories: ApplicationsFolders
    private var sources: [String: Registration] = [:]
    private var order: [String] = []

    init(budget: Budget, limit: Int = 48, directories: ApplicationsFolders = .standard) {
        self.budget = budget
        self.limit = max(0, limit)
        self.directories = directories
    }

    isolated deinit { removeAll() }

    func contains(_ url: URL) -> Bool { sources[url.fileViewKey] != nil }

    func watch(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        let key = url.fileViewKey
        guard limit > 0, sources[key] == nil else { return }
        let folders = directories.directories(for: url)
        // Only this tree's oldest registrations can be replaced; another window keeps its watchers.
        while sources.count >= limit || !budget.fits(folders.count) {
            guard let oldest = order.first else { return }
            remove(oldest)
        }
        // Held while its folders open, so another tree can't take it meanwhile; what doesn't open is given back.
        let token = UUID()
        budget.count += folders.count
        order.append(key)
        let task = Task { [weak self] in
            let opened = await DirectoryWatcher.watching(folders, onChange: onChange)
            self?.opened(opened, for: key, token: token)
        }
        sources[key] = .opening(token: token, task: task, reserved: folders.count)
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
        for key in Array(sources.keys) { remove(key) }
    }

    /// Once every folder asked for has opened, or failed to.
    func settled() async {
        while let task = sources.values.lazy.compactMap({ registration -> Task<Void, Never>? in
            if case .opening(_, let task, _) = registration { task } else { nil }
        }).first {
            await task.value
        }
    }

    /// A folder removed, or asked for again, while it opened has given its share back already: what opened is dropped.
    private func opened(_ watchers: [DirectoryWatcher], for key: String, token: UUID) {
        guard case .opening(let current, _, let reserved) = sources[key], current == token else { return }
        budget.count -= reserved - watchers.count
        if watchers.isEmpty {
            sources[key] = nil
            order.removeAll { $0 == key }
        } else {
            sources[key] = .watching(watchers)
        }
    }

    private func remove(_ key: String) {
        guard let removed = sources.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        if case .opening(_, let task, _) = removed { task.cancel() }
        budget.count -= removed.held
    }
}
