import Foundation

package nonisolated enum CopyRoot {
    /// A copy store's root, spelled the way its disk spells the part that exists (`/var` as `/private/var`), even
    /// before the copy's own folders are made. Foundation standardizes such aliases only once a path exists, so the
    /// existing ancestor is standardized first: making the cache can't change its identity. The last component stays
    /// as written: a link at the copy's root must still be refused by preparing and removing, never adopted as
    /// another cache location.
    package static func spelled(_ root: URL) -> URL {
        let root = root.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/"), root.path != "/" else { return root }
        var parent = root.deletingLastPathComponent(), missing = [root.lastPathComponent]
        while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
            missing.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        return missing.reversed().reduce(parent.standardizedFileURL) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }
}
