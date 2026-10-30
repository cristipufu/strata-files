import Foundation

/// Copies filled in as you browse: containers' files (`ContainerCopies`) and servers' (`RemoteCopies`). What they have
/// in common (a folder is listed when it's shown, files are fetched before they're opened, previewed, dragged or
/// copied, placeholders stand in until then) goes through here, whichever kind a path is in.
nonisolated enum LazyCopies {
    private static let providers = CopyProviders.live

    static func contains(_ url: URL) -> Bool { providers.contains(url) }
    static func isPlaceholder(_ url: URL) -> Bool { providers.isPlaceholder(url) }
    static func refresh(_ folder: URL) async { await providers.refresh(folder) }
    static func invalidate(_ folder: URL) async { await providers.invalidate(folder) }
    static func reveal(_ url: URL) async -> Bool { await providers.reveal(url) }
    static func fetch(_ urls: [URL]) async throws { try await providers.fetch(urls) }
    static func fetchSelection(_ urls: [URL], limit: Int64) async { await providers.fetchSelection(urls, limit: limit) }
    static func prepareForCopying(_ urls: [URL]) async throws { try await providers.prepareForCopying(urls) }
    static func message(for error: Error, about url: URL) -> String { providers.message(for: error, about: url) }
    static func displayPath(_ url: URL) -> String? { providers.displayPath(url) }

    /// Where items copied to the clipboard from a copy are staged (see `stageForClipboard`), next to the copies.
    static let clipboardRoot: URL = RemoteCopies.root.deletingLastPathComponent()
        .appending(path: "Clipboard.noindex", directoryHint: .isDirectory)

    /// What goes on the clipboard for `urls`: items from a container's or a server's copy as a staged copy of their own
    /// (an APFS clone, so it's instant), finished like anything copied out (links that would lead outside dropped,
    /// writable, still marked as downloaded). Pasting them anywhere, Finder included, gets ordinary files. Anything else
    /// is itself; a link chosen on its own is left out (from wherever it's pasted it would lead into this Mac's own
    /// folders). Staged items are removed at the next launch.
    static func stageForClipboard(_ urls: [URL], copies: CopyProviders, root: URL? = nil) -> [URL] {
        guard urls.contains(where: copies.contains) else { return urls }
        let clipboardRoot = root ?? copies.clipboardRoot
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

    /// Clipboard staging left from before (at launch).
    static func removeClipboardStaging() {
        guard FileManager.default.fileExists(atPath: clipboardRoot.path) else { return }
        Archiver.removeTree(clipboardRoot)
    }

    /// The container or server an item comes from, by name.
    static func sourceName(_ url: URL) -> String? {
        providers.sourceName(url)
    }
}
