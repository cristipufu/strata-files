import Foundation

/// Where a typed path leads, as the kernel walks it: a `..` is taken after the links on the way (`p/link/../notes.txt`
/// is beside the link's target), while the last item stays as named, so a link there is that link, never the file it
/// points to (`standardizedFileURL` resolves the whole path once a `..` is in it). It asks the disk.
package nonisolated enum TypedPath {
    package static func location(of url: URL) -> URL {
        let url = url.absoluteURL
        let last = url.lastPathComponent
        guard last != ".", last != ".." else { return url.standardizedFileURL }
        return url.deletingLastPathComponent().standardizedFileURL
            .appending(path: last, directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
    }
}
