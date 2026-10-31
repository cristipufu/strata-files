import Foundation

/// Folders made to hold an operation's items. Capture them when created, before a transfer or alert can suspend;
/// an empty replacement at the same path does not belong to the operation. Redo records any folders it makes again.
package final class CreatedFolders {
    package private(set) var urls: [URL] = []
    private var paths: Set<String> = []
    private var identities: [String: FileIdentity] = [:]
    package private(set) var historyIdentities: [String: String] = [:]

    package init(_ urls: [URL] = []) { record(urls) }

    /// Old History may lack folder identities. Restore its files, but leave unidentifiable folders alone.
    package init(paths: [String], recorded: [String: String]) {
        for path in paths where self.paths.insert(path).inserted { urls.append(URL(fileURLWithPath: path)) }
        for url in urls {
            guard let saved = recorded[url.path], let identity = FileIdentity.read(url.path),
                  FileIdentity.matchesHistory(saved, at: url.path), FileIdentity.read(url.path) == identity else { continue }
            identities[url.path] = identity
            historyIdentities[url.path] = saved
        }
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

    package func makeMissing(continueAfterFailure: Bool = false) throws {
        var firstError: Error?
        for url in urls.sorted(by: { $0.path.count < $1.path.count }) where !TransferEngine.exists(url) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                record([url])
            } catch {
                if !continueAfterFailure { throw error }
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    package func removeEmpty() { FileOps.removeEmptyFolders(urls, identities: identities) }

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

        package func prepare(continueAfterFailure: Bool = false) throws {
            if case .make(let folders) = self { try folders.makeMissing(continueAfterFailure: continueAfterFailure) }
        }
        package func finish() { if case .remove(let folders) = self { folders.removeEmpty() } }

        package var historyIdentities: [String: String] {
            if case .make(let folders) = self { folders.historyIdentities } else { [:] }
        }
    }
}
