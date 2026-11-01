import Foundation

/// Where items landed and what they are there, so an operation's undo moves or trashes only those very items: never
/// one put in an item's place since, however alike its name. Each is recorded as it lands (or, for a move on one
/// disk, before it starts), never later, when something else may already be there. Kept for this run only, so an
/// item is its disk, file number and birth time, read without following a link (History's `OperationLog.identity`
/// also outlives a disk being plugged in again).
package final class LandedFiles {
    private var identities: [String: FileIdentity] = [:]

    /// What's at each of `urls` now: for items that have just landed there.
    package init(_ urls: [URL] = []) { record(urls) }

    package func record(_ urls: [URL]) {
        for url in urls { identities[url.path] = FileIdentity.read(url.path) }
    }

    /// `identity` (from `FileIdentity.read`), read when the item landed at `url`.
    package func set(_ identity: FileIdentity?, at url: URL) {
        identities[url.path] = identity
    }

    /// Ownership already captured by the operation, carried to a worker without reading a later replacement.
    package func identity(at url: URL) -> FileIdentity? { identities[url.path] }

    /// Convert live ownership to History's persistent format only while the item still matches, away from the main
    /// thread. An empty key explicitly refuses Undo; omitting a key would invoke the compatibility rule for old,
    /// untracked records.
    package func historyKeys(for urls: [URL]) async -> [String: String] {
        let wanted = Set(urls.map(\.path))
        return await Self.historyKeys(identities.filter { wanted.contains($0.key) }, paths: urls.map(\.path))
    }

    /// History's keys for `identities` (each read where it is now), and an empty one for each of `paths` without one.
    @concurrent package static func historyKeys(_ identities: [String: FileIdentity], paths: [String] = []) async
        -> [String: String] {
        keys(identities, paths: paths)
    }

    /// `historyKeys`, converted at once: only for the one item New Folder or New File makes.
    package func historyKeysNow(for urls: [URL]) -> [String: String] {
        let wanted = Set(urls.map(\.path))
        return Self.keys(identities.filter { wanted.contains($0.key) }, paths: urls.map(\.path))
    }

    private nonisolated static func keys(_ identities: [String: FileIdentity], paths: [String]) -> [String: String] {
        var saved = Dictionary(paths.map { ($0, "") }) { first, _ in first }
        for (path, identity) in identities { saved[path] = identity.historyKey(at: path) ?? "" }
        return saved
    }

    /// `holds`, read at once: only for the one item an undo inside the UndoManager callback acts on, where its redo
    /// must be registered.
    package func holdsNow(_ url: URL) -> Bool { Self.holds(url, identities) }

    /// Whether `url` is still what landed there, read away from the main thread.
    package func holds(_ url: URL) async -> Bool {
        let held = await holding([url])
        return !held.isEmpty
    }

    /// What each item was when it landed, by its path.
    package var recorded: [String: FileIdentity] { identities }

    /// `holds`, for checking away from the main thread, item by item as each is about to change.
    package var owns: @Sendable (URL) -> Bool {
        let identities = identities
        return { Self.holds($0, identities) }
    }

    /// Those of `urls` that `holds`, read away from the main thread.
    package func holding(_ urls: [URL]) async -> [URL] {
        await Self.holding(urls, identities)
    }

    @concurrent private static func holding(_ urls: [URL], _ identities: [String: FileIdentity]) async -> [URL] {
        urls.filter { holds($0, identities) }
    }

    nonisolated private static func holds(_ url: URL, _ identities: [String: FileIdentity]) -> Bool {
        guard let identity = identities[url.path] else { return false }
        return FileIdentity.read(url.path) == identity
    }
}

