import Foundation

/// Where a typed path leads, as the kernel walks it: a `..` is taken after the links on the way (`p/link/../notes.txt`
/// is beside the link's target), while the last item stays as named, so a link there is that link, never the file it
/// points to (`standardizedFileURL` resolves the whole path once a `..` is in it). It asks the disk.
package nonisolated enum TypedPath {
    /// `path` as typed in `folder` (a shell's working folder): a relative path goes on from there, its `..` kept for
    /// the walk rather than taken off its letters as a relative URL takes it. Either way a folder ends with a slash, as
    /// the system spells one, asked of the disk once the walk has found it.
    package static func location(of path: String, in folder: URL) -> URL {
        location(of: path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appending(path: path, directoryHint: .checkFileSystem))
    }

    package static func location(of url: URL) -> URL {
        let url = url.absoluteURL
        let last = url.lastPathComponent
        guard last != ".", last != ".." else { return url.standardizedFileURL }
        return url.deletingLastPathComponent().standardizedFileURL
            .appending(path: last, directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
    }
}
