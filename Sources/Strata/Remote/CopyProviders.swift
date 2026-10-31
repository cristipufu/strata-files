import Foundation

/// The read capabilities of a browsable copy. Providers keep their own listing format, permissions, fetching policy
/// and error messages. Server writes and container archives remain separate from this interface.
package nonisolated protocol CopyProvider: Sendable {
    func contains(_ url: URL) -> Bool
    func isPlaceholder(_ url: URL) -> Bool
    func previewFolder(_ folder: URL) async throws
    func refresh(_ folder: URL) async
    func invalidate(_ folder: URL) async
    func reveal(_ url: URL) async -> Bool
    func fetch(_ urls: [URL]) async throws
    func fetchSelection(_ urls: [URL], limit: Int64) async
    func prepareForCopying(_ urls: [URL]) async throws
    func message(for error: Error, about url: URL) -> String
    func displayPath(_ url: URL) -> String?
    func sourceName(_ url: URL) -> String?
}

extension CopyProvider {
    package func previewFolder(_ folder: URL) async throws { await refresh(folder) }
}

/// Routes each URL to its owner. The order is stable: explicit reads finish one provider before starting the next,
/// and the first owner of a path handles it exactly once. Independent environments can supply their own providers.
package nonisolated struct CopyProviders: Sendable {
    package static let previewEntryLimit = 50_000
    package static let live = CopyProviders(servers: .shared, containers: .shared)
    private let providers: [any CopyProvider]
    package let remoteCopies: RemoteCopyStore
    package let containerCopies: ContainerCopyStore
    package let clipboardRoot: URL

    package init(_ providers: [any CopyProvider], remoteCopies: RemoteCopyStore = RemoteCopies.store,
         containerCopies: ContainerCopyStore = ContainerCopies.store,
         clipboardRoot: URL = LazyCopies.clipboardRoot) {
        self.providers = providers
        self.remoteCopies = remoteCopies
        self.containerCopies = containerCopies
        self.clipboardRoot = clipboardRoot
    }

    package init(servers: RemoteFiles, containers: ContainerFiles, clipboardRoot: URL? = nil) {
        let defaultRoot = servers.copies.root == RemoteCopies.root
            ? LazyCopies.clipboardRoot
            : servers.copies.root.deletingLastPathComponent().appending(path: "Clipboard.noindex", directoryHint: .isDirectory)
        self.init([ServerCopyProvider(files: servers), ContainerCopyProvider(files: containers)],
                  remoteCopies: servers.copies, containerCopies: containers.copies,
                  clipboardRoot: clipboardRoot ?? defaultRoot)
    }

    private func provider(for url: URL) -> (any CopyProvider)? { providers.first { $0.contains(url) } }

    package func contains(_ url: URL) -> Bool { provider(for: url) != nil }
    package func isClipboardStaging(_ url: URL) -> Bool {
        let root = clipboardRoot.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
    package var previewRoot: URL { clipboardRoot.deletingLastPathComponent().appendingPathComponent("Previews.noindex", isDirectory: true) }
    package func isPlaceholder(_ url: URL) -> Bool { provider(for: url)?.isPlaceholder(url) ?? false }
    package func containsPlaceholder(in urls: [URL]) -> Bool { Self.containsPlaceholder(in: urls, providers: providers) }

    /// `containsPlaceholder` away from the main thread: it reads every item of a folder copied out of a server or a
    /// container, which can hold thousands.
    package func containsPlaceholderOffMain(in urls: [URL]) async -> Bool {
        await Self.containsPlaceholder(in: urls, of: providers)
    }

    @concurrent private static func containsPlaceholder(in urls: [URL], of providers: [any CopyProvider]) async -> Bool {
        containsPlaceholder(in: urls, providers: providers)
    }

    nonisolated private static func containsPlaceholder(in urls: [URL], providers: [any CopyProvider]) -> Bool {
        func check(_ url: URL) -> Bool {
            guard let provider = providers.first(where: { $0.contains(url) }) else { return false }
            if provider.isPlaceholder(url) { return true }
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
                if check(url.appending(path: name)) { return true }
            }
            return false
        }
        return urls.contains(where: check)
    }
    package func stageForClipboard(_ urls: [URL]) -> [URL] {
        LazyCopies.stageForClipboard(urls, copies: self, root: clipboardRoot)
    }
    package func previewFolder(_ folder: URL) async throws { try await provider(for: folder)?.previewFolder(folder) }
    package func refresh(_ folder: URL) async { await provider(for: folder)?.refresh(folder) }
    package func invalidate(_ folder: URL) async { await provider(for: folder)?.invalidate(folder) }
    package func reveal(_ url: URL) async -> Bool { await provider(for: url)?.reveal(url) ?? false }
    package func displayPath(_ url: URL) -> String? { provider(for: url)?.displayPath(url) }
    package func clipboardPath(_ url: URL) -> String? {
        if remoteCopies.contains(url) { return remoteCopies.displayPath(url) }
        if containerCopies.contains(url) {
            guard let (source, top) = containerCopies.copy(containing: url),
                  let path = ContainerCopies.containerPath(of: url, top: top) else { return nil }
            return top.standardizedFileURL == url.standardizedFileURL ? source.name : path
        }
        if contains(url) { return displayPath(url) }
        return url.path
    }
    package func sourceName(_ url: URL) -> String? { provider(for: url)?.sourceName(url) }
    package func message(for error: Error, about url: URL) -> String {
        provider(for: url)?.message(for: error, about: url) ?? error.localizedDescription
    }

    package func fetch(_ urls: [URL]) async throws {
        for (provider, items) in groups(urls) { try await provider.fetch(items) }
    }

    package func prepareForCopying(_ urls: [URL]) async throws {
        for (provider, items) in groups(urls) { try await provider.prepareForCopying(items) }
    }

    /// Selection prefetch is optional and bounded. Preserve the existing policy: only the first selected provider
    /// spends this budget; explicit opening or copying fetches every provider's items.
    package func fetchSelection(_ urls: [URL], limit: Int64) async {
        if let (provider, items) = groups(urls).first { await provider.fetchSelection(items, limit: limit) }
    }

    private func groups(_ urls: [URL]) -> [(any CopyProvider, [URL])] {
        var items = Array(repeating: [URL](), count: providers.count)
        for url in urls {
            if let index = providers.firstIndex(where: { $0.contains(url) }) { items[index].append(url) }
        }
        return providers.indices.compactMap { items[$0].isEmpty ? nil : (providers[$0], items[$0]) }
    }
}

package nonisolated struct ServerCopyProvider: CopyProvider {
    package let files: RemoteFiles
    package func contains(_ url: URL) -> Bool { files.copies.contains(url) }
    package func isPlaceholder(_ url: URL) -> Bool { files.copies.isPlaceholder(url) }
    package func previewFolder(_ folder: URL) async throws { try await files.previewFolder(folder) }
    package func refresh(_ folder: URL) async { await files.refresh(folder) }
    package func invalidate(_ folder: URL) async { await files.invalidate(folder) }
    package func reveal(_ url: URL) async -> Bool { await files.reveal(url) }
    package func fetch(_ urls: [URL]) async throws { try await files.fetch(urls) }
    package func fetchSelection(_ urls: [URL], limit: Int64) async { await files.fetchSelection(urls, limit: limit) }
    package func prepareForCopying(_ urls: [URL]) async throws { try await files.prepareForCopying(urls) }
    package func message(for error: Error, about url: URL) -> String { RemoteFiles.message(for: error) }
    package func displayPath(_ url: URL) -> String? { files.copies.displayPath(url) }
    package func sourceName(_ url: URL) -> String? { files.copies.server(containing: url)?.server.name }
}

private nonisolated struct ContainerCopyProvider: CopyProvider {
    let files: ContainerFiles
    func contains(_ url: URL) -> Bool { files.copies.contains(url) }
    func isPlaceholder(_ url: URL) -> Bool { files.copies.isPlaceholder(url) }
    func previewFolder(_ folder: URL) async throws { try await files.previewFolder(folder) }
    func refresh(_ folder: URL) async { await files.refresh(folder) }
    func invalidate(_ folder: URL) async { await files.invalidate(folder) }
    func reveal(_ url: URL) async -> Bool { await files.reveal(url) }
    func fetch(_ urls: [URL]) async throws { try await files.fetch(urls) }
    func fetchSelection(_ urls: [URL], limit: Int64) async { await files.fetchSelection(urls, limit: limit) }
    func prepareForCopying(_ urls: [URL]) async throws { try await files.prepareForCopying(urls) }
    func message(for error: Error, about url: URL) -> String {
        guard let source = files.copies.copy(containing: url)?.source else { return error.localizedDescription }
        return ContainerFiles.message(for: error, source: source)
    }
    func displayPath(_ url: URL) -> String? { files.copies.apparentPath(url) }
    func sourceName(_ url: URL) -> String? { files.copies.copy(containing: url)?.source.name }
}
