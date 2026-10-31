import Foundation

/// Folders made to hold an operation's items. Capture them when created, before a transfer or alert can suspend;
/// an empty replacement at the same path does not belong to the operation. Redo records any folders it makes again.
package final class CreatedFolders {
    package private(set) var urls: [URL] = []
    private var paths: Set<String> = []
    private var identities: [String: FileIdentity] = [:]
    package private(set) var historyIdentities: [String: String] = [:]

    package init(_ urls: [URL] = []) { record(urls) }

    /// The folders History recorded at `paths` that are still the ones it made, read away from the main thread. Old
    /// History may lack folder identities: its files are restored, but unidentifiable folders are left alone.
    package static func recorded(paths: [String], recorded: [String: String]) async -> CreatedFolders {
        let unique = paths.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return CreatedFolders(paths: unique, matched: await matching(unique, recorded))
    }

    private init(paths: [String], matched: [String: (identity: FileIdentity, saved: String)]) {
        urls = paths.map { URL(fileURLWithPath: $0) }
        self.paths = Set(paths)
        identities = matched.mapValues(\.identity)
        historyIdentities = matched.mapValues(\.saved)
    }

    @concurrent private static func matching(_ paths: [String], _ recorded: [String: String]) async
        -> [String: (identity: FileIdentity, saved: String)] {
        var matched: [String: (identity: FileIdentity, saved: String)] = [:]
        for path in paths {
            guard let saved = recorded[path], let identity = FileIdentity.read(path),
                  FileIdentity.matchesHistory(saved, at: path), FileIdentity.read(path) == identity else { continue }
            matched[path] = (identity, saved)
        }
        return matched
    }

    /// A folder just made and what makes it that folder, read where it was made (off the main thread, say).
    package nonisolated struct Made: Sendable {
        package let url: URL
        package let identity: FileIdentity?
        package let historyIdentity: String?

        package init(_ url: URL) {
            let identity = FileIdentity.read(url.path)
            let saved = FileIdentity.historyKey(at: url.path)
            // A replacement during metadata lookup must not acquire either live or persistent ownership.
            let unchanged = identity != nil && FileIdentity.read(url.path) == identity
            self.url = url
            self.identity = unchanged ? identity : nil
            historyIdentity = unchanged ? saved : nil
        }
    }

    package func record(_ made: [URL]) { record(made.map(Made.init)) }

    package func record(_ made: [Made]) {
        for folder in made {
            if paths.insert(folder.url.path).inserted { urls.append(folder.url) }
            identities[folder.url.path] = folder.identity
            historyIdentities[folder.url.path] = folder.historyIdentity
        }
    }

    package func makeMissing(continueAfterFailure: Bool = false) async throws {
        let sorted = urls.sorted { $0.path.count < $1.path.count }
        let (made, failures) = await Self.make(sorted, intermediates: true, stopAtFailure: !continueAfterFailure,
                                               isThere: TransferEngine.exists)
        record(made)
        if let first = failures.first { throw first.error }
    }

    /// Makes those of `urls` that aren't there yet (`isThere`), in order, away from the main thread, each read as it's
    /// made so a replacement can't take its ownership; with `stopAtFailure` the first failure ends it.
    @concurrent package static func make(_ urls: [URL], intermediates: Bool, stopAtFailure: Bool,
                                         isThere: @Sendable (URL) -> Bool) async -> (made: [Made], failures: [(url: URL, error: Error)]) {
        var made: [Made] = [], failures: [(url: URL, error: Error)] = []
        for url in urls where !isThere(url) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: intermediates)
                made.append(Made(url))
            } catch {
                failures.append((url, error))
                if stopAtFailure { break }
            }
        }
        return (made, failures)
    }

    /// Removes those still empty, away from the main thread.
    package func removeEmpty() async {
        let urls = urls, identities = identities
        await Self.removeEmpty(urls, identities)
    }

    @concurrent private static func removeEmpty(_ urls: [URL], _ identities: [String: FileIdentity]) async {
        FileOps.removeEmptyFolders(urls, identities: identities)
    }

    /// Kept by both sides of an Undo/Redo pair, so folders recreated by Redo have fresh ownership before Undo runs.
    package enum Change {
        case none
        case make(CreatedFolders)
        case remove(CreatedFolders)

        package var inverse: Change {
            switch self {
            case .none: .none
            case .make(let folders): .remove(folders)
            case .remove(let folders): .make(folders)
            }
        }

        package func prepare(continueAfterFailure: Bool = false) async throws {
            if case .make(let folders) = self { try await folders.makeMissing(continueAfterFailure: continueAfterFailure) }
        }
        package func finish() async { if case .remove(let folders) = self { await folders.removeEmpty() } }

        package var historyIdentities: [String: String] {
            if case .make(let folders) = self { folders.historyIdentities } else { [:] }
        }
    }
}
