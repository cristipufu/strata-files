import Foundation

/// Going up a folder (Go ▸ Enclosing Folder), and which item a parent shows selected when you arrive from below it.
enum ParentFolder {
    enum Step: Equatable {
        case to(URL, selecting: URL)
        /// Already at the top of the disk.
        case none
        /// The top of the Containers folder or of a server: nothing of theirs is above it.
        case refused
    }

    /// Up from `current`: the folder it's in, with `current` selected; from the top of an archive's copy, the folder the
    /// archive is in, with the archive selected.
    static func up(from current: URL, containers: ContainerCopyStore, servers: RemoteCopyStore) -> Step {
        guard current.path != "/" else { return .none }
        if let (archive, top) = ArchiveCache.archive(containing: current), top.lexicallyStandardized == current.lexicallyStandardized {
            return .to(archive.deletingLastPathComponent(), selecting: archive)
        }
        // A container's `/` goes up to the Containers folder, which has nothing above it; nor has a server's `/`.
        if containers.engineFolder(current) != nil { return .refused }
        if let (_, top) = servers.server(containing: current), top.lexicallyStandardized == current.lexicallyStandardized { return .refused }
        return .to(current.deletingLastPathComponent(), selecting: current)
    }

    /// The item in `folder` on the way down to `origin`, when `origin` is inside it (going back up, or to an enclosing
    /// folder): it's shown selected. Paths are compared by their letters, a whole name at a time.
    static func child(of folder: URL, toward origin: URL) -> URL? {
        let parent = folder.lexicallyStandardized.path
        let path = origin.lexicallyStandardized.path
        guard path.hasPrefix(parent == "/" ? "/" : parent + "/") else { return nil }
        let rest = path.dropFirst(parent == "/" ? 1 : parent.count + 1)
        guard let first = rest.split(separator: "/").first else { return nil }
        return folder.appending(path: String(first)).lexicallyStandardized
    }
}
