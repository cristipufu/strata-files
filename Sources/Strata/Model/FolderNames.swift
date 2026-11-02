import Foundation
import StrataSupport

extension Notification.Name {
    /// A `FolderNames` read found Finder names other than folders' own (object: the `FolderNames`, userInfo `paths`:
    /// a `Set<String>` of those folders' paths).
    package static let folderNamesRead = Notification.Name("StrataFolderNamesRead")
}

/// What Finder calls the folders along the path on show (in the path bar, the window's title and a pane's header),
/// read away from the main thread: each name asks the disk, a round trip per folder on a server, every time you move.
/// Until it's read, a folder goes by its own name.
package final class FolderNames {
    private var names: [String: String] = [:]
    private var reads: BatchedReads<String>!

    package init(read: @escaping @Sendable ([String]) -> [String: String]) {
        reads = BatchedReads(read: read) { [weak self] found in self?.keep(found) }
    }

    /// Finder's name for the folder, as last read; its own name until then.
    package func name(_ url: URL) -> String {
        if let name = names[url.path] { return name }
        reads.request(url.path)
        return url.lastPathComponent
    }

    package func settled() async {
        await reads.settled()
    }

    /// Only names other than the folders' own are announced: those are what was shown until now.
    private func keep(_ found: [String: String]) {
        if names.count > 5_000 { names.removeAll(keepingCapacity: true) }
        var renamed: Set<String> = []
        for (path, name) in found {
            if name != (path as NSString).lastPathComponent { renamed.insert(path) }
            names[path] = name
        }
        if !renamed.isEmpty {
            NotificationCenter.default.post(name: .folderNamesRead, object: self, userInfo: ["paths": renamed])
        }
    }

    package nonisolated static func read(_ paths: [String]) -> [String: String] {
        var names: [String: String] = [:]
        for path in paths { names[path] = FileManager.default.displayName(atPath: path) }
        return names
    }
}
