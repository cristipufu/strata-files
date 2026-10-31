import Foundation

/// Finder includes built-in apps alongside installed apps. Entries keep their physical URLs, including duplicate
/// names and Utilities folders: file commands must never turn a system app into a path inside /Applications.
package nonisolated struct ApplicationsFolders: Sendable {
    package let installed: URL
    package let system: URL

    package static let standard = Self(installed: URL(fileURLWithPath: "/Applications", isDirectory: true),
                               system: URL(fileURLWithPath: "/System/Applications", isDirectory: true))

    package func directories(for directory: URL) -> [URL] {
        guard directory.standardizedFileURL.path == installed.standardizedFileURL.path,
              installed.standardizedFileURL.path != system.standardizedFileURL.path else { return [directory] }
        return [directory, system]
    }

    /// The requested folder must be readable. A missing or unreadable supplementary system folder is optional.
    package func contents(of directory: URL, keys: [URLResourceKey], options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        let directories = directories(for: directory)
        var urls = try FileManager.default.contentsOfDirectory(at: directories[0], includingPropertiesForKeys: keys, options: options)
        for extra in directories.dropFirst() {
            urls += (try? FileManager.default.contentsOfDirectory(at: extra, includingPropertiesForKeys: keys, options: options)) ?? []
        }
        return urls
    }

    /// Columns can reveal a system app through a folder actually listed at their root, including Applications itself.
    /// The chain chooses rows; their entries supply the physical URLs used by commands.
    package func revealChain(to url: URL, from root: URL, listed: [FileEntry]) -> [URL]? {
        let path = url.standardizedFileURL.path, rootPath = root.standardizedFileURL.path
        func inside(_ path: String, _ parent: String) -> Bool { path.hasPrefix(parent == "/" ? "/" : parent + "/") }
        let boundary: String
        let first: URL?
        if inside(path, rootPath) {
            boundary = rootPath
            first = nil
        } else if let ancestor = listed.first(where: { $0.isFolder && inside(path, $0.url.standardizedFileURL.path) }) {
            boundary = ancestor.url.standardizedFileURL.path
            first = ancestor.url
        } else if inside(path, system.standardizedFileURL.path),
                  let applications = listed.first(where: { $0.isFolder && $0.url.standardizedFileURL.path == installed.standardizedFileURL.path }) {
            boundary = system.standardizedFileURL.path
            first = applications.url
        } else {
            return nil
        }
        var chain: [URL] = []
        var current = url
        while current.standardizedFileURL.path != boundary, current.path != "/" {
            chain.insert(current, at: 0)
            current = current.deletingLastPathComponent()
        }
        if let first { chain.insert(first, at: 0) }
        return chain
    }
}
