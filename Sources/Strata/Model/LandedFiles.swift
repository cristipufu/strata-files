import Foundation

/// Where items landed and what they are there, so an operation's undo moves or trashes only those very items: never
/// one put in an item's place since, however alike its name. Each is recorded as it lands (or, for a move on one
/// disk, before it starts), never later, when something else may already be there. Kept for this run only, so an
/// item is its disk, file number and birth time, read without following a link (History's `OperationLog.identity`
/// also outlives a disk being plugged in again).
final class LandedFiles {
    private var identities: [String: FileIdentity] = [:]

    /// What's at each of `urls` now: for items that have just landed there.
    init(_ urls: [URL] = []) { record(urls) }

    func record(_ urls: [URL]) {
        for url in urls { identities[url.path] = FileIdentity.read(url.path) }
    }

    /// `identity` (from `FileIdentity.read`), read when the item landed at `url`.
    func set(_ identity: FileIdentity?, at url: URL) {
        identities[url.path] = identity
    }

    /// Ownership already captured by the operation, carried to a worker without reading a later replacement.
    func identity(at url: URL) -> FileIdentity? { identities[url.path] }

    /// The item at `url` is about to move to `destination`: a move on one disk keeps what it is, so it's expected
    /// there already. Call `arrived` once it's moved.
    func expect(_ url: URL, at destination: URL) {
        identities[destination.path] = FileIdentity.read(url.path)
    }

    /// An expected item has moved to `destination`. Moved across disks, it's a new file there, recorded now; on one
    /// disk the expectation stands, so a file swapped in meanwhile is never taken for it.
    func arrived(_ destination: URL) {
        guard let expected = identities[destination.path], let now = FileIdentity.read(destination.path) else { return }
        if expected.device != now.device { identities[destination.path] = now }
    }

    /// Convert live ownership to History's persistent format only while the item still matches. An empty key
    /// explicitly refuses Undo; omitting a key would invoke the compatibility rule for old, untracked records.
    func historyIdentities(for urls: [URL]) -> [String: String] {
        var saved: [String: String] = [:]
        for url in urls {
            saved[url.path] = identities[url.path]?.historyKey(at: url.path) ?? ""
        }
        return saved
    }

    func holds(_ url: URL) -> Bool {
        Self.holds(url, identities)
    }

    /// `holds`, for checking away from the main thread, item by item as each is about to change.
    var owns: @Sendable (URL) -> Bool {
        let identities = identities
        return { Self.holds($0, identities) }
    }

    /// Those of `urls` that `holds`, read away from the main thread.
    func holding(_ urls: [URL]) async -> [URL] {
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

