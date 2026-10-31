import Foundation

/// Copies filled in as you browse: containers' files (`ContainerCopies`) and servers' (`RemoteCopies`). Reading them
/// goes through a window's `CopyProviders`; what's here is the clipboard staging they all share.
package nonisolated enum LazyCopies {
    /// What goes on the clipboard for `urls`: items from a container's or a server's copy as a staged copy of their own
    /// (an APFS clone, so it's instant), finished like anything copied out (links that would lead outside dropped,
    /// writable, still marked as downloaded). Pasting them anywhere, Finder included, gets ordinary files. Anything else
    /// is itself; a link chosen on its own is left out (from wherever it's pasted it would lead into this Mac's own
    /// folders). Staged items are removed at the next launch.
    package static func stageForClipboard(_ urls: [URL], copies: CopyProviders) -> [URL] {
        guard urls.contains(where: copies.contains) else { return urls }
        let clipboardRoot = copies.clipboardRoot
        let fm = FileManager.default
        func newFolder() -> URL? {
            let folder = clipboardRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                return folder
            } catch {
                return nil
            }
        }
        guard var folder = newFolder() else { return urls.filter { !copies.contains($0) } }
        return urls.compactMap { url in
            guard copies.contains(url) else { return url }
            guard !copies.containsPlaceholder(in: [url]) else { return nil }
            var info = stat()
            // Two chosen items with one name (from different folders) each get a folder of their own.
            if lstat(folder.appending(path: url.lastPathComponent).path, &info) == 0 {
                guard let another = newFolder() else { return nil }
                folder = another
            }
            let staged = folder.appending(path: url.lastPathComponent)
            guard (try? TransferEngine.copyForExport(url, to: staged)) != nil else { return nil }
            return lstat(staged.path, &info) == 0 ? staged : nil
        }
    }
}
