import Foundation

extension Notification.Name {
    /// A `FolderNames` read found Finder names other than folders' own (object: the `FolderNames`, userInfo `paths`:
    /// a `Set<String>` of those folders' paths).
    static let folderNamesRead = Notification.Name("StrataFolderNamesRead")
}

/// What Finder calls the folders along the path on show (in the path bar, the window's title and a pane's header),
/// read away from the main thread: each name asks the disk, a round trip per folder on a server, every time you move.
/// Until it's read, a folder goes by its own name.
final class FolderNames {
    private var names: [String: String] = [:]
    private var requested: Set<String> = []
    private let read: @Sendable ([String]) async -> [String: String]
    private(set) var task: Task<Void, Never>?

    init(read: @escaping @Sendable ([String]) async -> [String: String]) {
        self.read = read
    }

    isolated deinit { task?.cancel() }

    /// Finder's name for the folder, as last read; its own name until then.
    func name(_ url: URL) -> String {
        if let name = names[url.path] { return name }
        requested.insert(url.path)
        if task == nil { readRequested() }
        return url.lastPathComponent
    }

    private func readRequested() {
        let read = read
        task = Task { [weak self] in
            // The other folders along the path ask too, and are read with this one.
            await Task.yield()
            guard let paths = self?.takeRequested() else { return }
            let found = await read(paths)
            guard !Task.isCancelled, let self else { return }
            task = nil
            keep(found, for: paths)
            if !requested.isEmpty { readRequested() }
        }
    }

    private func takeRequested() -> [String] {
        defer { requested.removeAll() }
        if names.count > 5_000 { names.removeAll(keepingCapacity: true) }
        return Array(requested)
    }

    /// Only names other than the folders' own are announced: those are what was shown until now.
    private func keep(_ found: [String: String], for paths: [String]) {
        var renamed: Set<String> = []
        for path in paths {
            let own = URL(fileURLWithPath: path).lastPathComponent
            let name = found[path] ?? own
            if name != own { renamed.insert(path) }
            names[path] = name
        }
        if !renamed.isEmpty {
            NotificationCenter.default.post(name: .folderNamesRead, object: self, userInfo: ["paths": renamed])
        }
    }

    @concurrent static func read(_ paths: [String]) async -> [String: String] {
        var names: [String: String] = [:]
        for path in paths { names[path] = FileManager.default.displayName(atPath: path) }
        return names
    }
}
