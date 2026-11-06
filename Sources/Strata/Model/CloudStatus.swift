import Foundation
import StrataSupport

/// iCloud Drive and File Provider (Dropbox, OneDrive, Google Drive…) state of an item: in the cloud only, on its way
/// down or up, or here. Read only for items in such folders, so ordinary folders pay nothing.
package nonisolated enum CloudStatus: Sendable, Equatable {
    /// Only in the cloud (Download Now brings it here).
    case cloudOnly
    /// A File Provider placeholder. Its provider owns upload state and eviction.
    case providerOnly
    /// Local File Provider content; this does not assert it has finished uploading.
    case local
    case downloading
    case uploading
    /// Here, not uploaded yet (its download can't be removed until it is).
    case waitingToUpload
    /// Here, and in the cloud (Remove Download frees the space).
    case downloaded

    package static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey,
    ]

    /// The item's state, or nil when it isn't a cloud item.
    package static func read(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CloudStatus? {
        var info = stat()
        guard lstat(url.path, &info) == 0, [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else { return nil }
        // A fresh URL: resource values are cached per URL object, and these change while you watch.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: keys) else { return nil }
        guard values.isUbiquitousItem == true else {
            guard CloudFolders.providerRoot(for: url, home: home) != nil else { return nil }
            return providerStatus(flags: info.st_flags)
        }
        return ubiquitousStatus(downloading: values.ubiquitousItemIsDownloading, uploading: values.ubiquitousItemIsUploading,
                                downloadStatus: values.ubiquitousItemDownloadingStatus, uploaded: values.ubiquitousItemIsUploaded)
    }

    package static func ubiquitousStatus(downloading: Bool?, uploading: Bool?, downloadStatus: URLUbiquitousItemDownloadingStatus?,
                                 uploaded: Bool?) -> CloudStatus {
        if downloading == true { return .downloading }
        if uploading == true { return .uploading }
        if downloadStatus == .notDownloaded { return .cloudOnly }
        if uploaded == false { return .waitingToUpload }
        return uploaded == true ? .downloaded : .local
    }

    package static func providerStatus(flags: UInt32) -> CloudStatus {
        flags & UInt32(SF_DATALESS) != 0 ? .providerOnly : .local
    }

    /// Whether `folder` holds cloud items: iCloud Drive, a File Provider folder (`~/Library/CloudStorage`), or anything
    /// the system reports as ubiquitous.
    package static func isCloudFolder(_ folder: URL) -> Bool {
        let path = folder.lexicallyStandardized.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if CloudFolders.contains(folder, in: URL(fileURLWithPath: home + "/Library/Mobile Documents"))
            || CloudFolders.contains(folder, in: URL(fileURLWithPath: home + "/Library/CloudStorage")) { return true }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    package var symbolName: String {
        switch self {
        case .cloudOnly, .providerOnly: "icloud"
        case .local: "arrow.down.circle"
        case .downloading: "icloud.and.arrow.down"
        case .uploading, .waitingToUpload: "icloud.and.arrow.up"
        case .downloaded: "checkmark.icloud"
        }
    }

    package var label: String {
        switch self {
        // Neutral words: the same states appear in Dropbox, OneDrive and Google Drive folders.
        case .cloudOnly, .providerOnly: String(localized: "Only in the cloud", comment: "Cloud status of an item")
        case .local: String(localized: "Downloaded", comment: "Cloud status: local content; does not assert an upload has completed")
        case .downloading: String(localized: "Downloading", comment: "Cloud status of an item")
        case .uploading: String(localized: "Uploading", comment: "Cloud status of an item")
        case .waitingToUpload: String(localized: "Waiting to upload", comment: "Cloud status of an item")
        case .downloaded: String(localized: "Downloaded", comment: "Cloud status of an item: here and in the cloud")
        }
    }

    /// Whether it's mid-transfer (worth checking again soon).
    package var isActive: Bool { self == .downloading || self == .uploading || self == .waitingToUpload }
    package var isPlaceholder: Bool { self == .cloudOnly || self == .providerOnly }
}

/// Asks the cloud provider to bring items here, or to free their space (they stay in the cloud). Each returns the items
/// it couldn't ask about, with why (an item not uploaded yet can't have its download removed).
package enum CloudActions {
    package nonisolated struct Download: Sendable {
        package let chosen: ChosenFile
        package let provider: Bool

        package init(_ url: URL, status: CloudStatus?) throws {
            guard url.isFileURL, status == .cloudOnly || status == .providerOnly else { throw POSIXError(.EINVAL) }
            chosen = try ChosenFile(url, resolveParent: false)
            provider = status == .providerOnly
            try chosen.withDescriptor { _, info in
                guard info.st_mode & S_IFMT == S_IFREG || (!provider && info.st_mode & S_IFMT == S_IFDIR) else {
                    throw POSIXError(.ENOTSUP)
                }
            }
        }

        package func perform(request: (ChosenFile, Bool) throws -> Void) throws {
            try chosen.withDescriptor { _, _ in try request(chosen, provider) }
        }

        package static func request(_ chosen: ChosenFile, provider: Bool) throws {
            let url = chosen.url
            if !provider {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                return
            }
            // File coordination asks the installed provider to materialize the file before handing it to a reader.
            // NSFileProviderManager itself is restricted to the provider's own app and extensions.
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var readError: (any Error)?
            var accessed = false
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { visible in
                accessed = true
                do {
                    guard visible.lexicallyStandardized == url.lexicallyStandardized else { throw POSIXError(.ESTALE) }
                    try chosen.withDescriptor { _, info in
                        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw POSIXError(.EAGAIN) }
                    }
                } catch { readError = error }
            }
            if let error = coordinationError { throw error }
            if let error = readError { throw error }
            guard accessed else { throw POSIXError(.EIO) }
        }
    }

    package static func download(_ choices: [Download]) async -> [(URL, Error)] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let failures: [(URL, Error)] = choices.compactMap { choice in
                    do { try choice.perform(request: Download.request) }
                    catch { return (choice.chosen.url, error) }
                    return nil
                }
                continuation.resume(returning: failures)
            }
        }
    }

    /// What Remove Download frees: only items that are both here and in the cloud (one still uploading, or waiting to,
    /// exists only here), never through a link (that would free what it points to), each once.
    package nonisolated static func removable(_ urls: [URL], status: (URL) -> CloudStatus?) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK, status(url) == .downloaded else { return false }
            return seen.insert(url.lexicallyStandardized.path).inserted
        }
    }

    /// Remove Download for `urls` away from the main thread, where each item's state is read and its space freed: those
    /// it chose (`known`: their states as the folder's listing last read them) and what failed.
    @concurrent package static func removeDownloads(_ urls: [URL], known: [URL: CloudStatus]) async
        -> (chosen: [URL], failures: [(URL, Error)]) {
        let chosen = removable(urls) { known[$0] }
        return (chosen, chosen.isEmpty ? [] : removeDownload(chosen))
    }

    /// Asks for each item's space to be freed, going on past failures. `evict` is the system's (a test's records).
    package nonisolated static func removeDownload(_ urls: [URL], status: (URL) -> CloudStatus? = { CloudStatus.read($0) },
                               evict: (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) }) -> [(URL, Error)] {
        let choices = urls.map { url in (url, Result { try ChosenFile(url, resolveParent: false) }) }
        return choices.compactMap { url, choice in
            do {
                let chosen = try choice.get()
                guard status(url) == .downloaded else { throw POSIXError(.EPERM) }
                try chosen.withDescriptor { _, info in
                    guard info.st_mode & S_IFMT != S_IFLNK else { throw POSIXError(.EPERM) }
                }
                // An open target can make the provider refuse eviction; keep the chosen parent, release the leaf.
                try evict(url)
            } catch { return (url, error) }
            return nil
        }
    }
}

extension Notification.Name {
    /// Cloud states were read (or changed) for items in a shown folder (object: the store); visible cells redraw their
    /// badges.
    package static let cloudStatusChanged = Notification.Name("StrataCloudStatusChanged")
}

/// The cloud states of the items in the folders being shown, read off the main thread and only for cloud folders (others
/// cost one check per folder). Folders a window shows are kept; while anything in them is moving, they're read again
/// every couple of seconds, so badges follow the transfer.
@MainActor package final class CloudStore {
    package static let shared = CloudStore()

    /// The folders the app's windows show, as the app tells it at launch: only those are polled and kept.
    package var foldersShown: () -> Set<String> = { [] }

    package typealias Reader = @concurrent @Sendable ([String], String) async -> (paths: [String], statuses: [String: CloudStatus])?
    private let reader: Reader
    private let allowance = WorkAllowance(limit: 2)
    private final class FolderRead {
        let id = UUID()
        var paths: [String] = []
        var known: Set<String> = []
        func append(_ additions: [String]) -> [String] {
            additions.filter { path in
                guard known.insert(path).inserted else { return false }
                paths.append(path)
                return true
            }
        }
    }
    private var generations: [String: FolderRead] = [:]
    private var requests: [UUID: (folder: String, task: Task<Void, Never>)] = [:]

    package init(reader: @escaping Reader = CloudStore.read) { self.reader = reader }
    isolated deinit { poll?.invalidate(); for request in requests.values { request.task.cancel() } }

    private var statuses: [String: CloudStatus] = [:]
    /// Cloud folders read, most recently loaded last.
    private var folders: [String] = []
    private var items: [String: [String]] = [:]
    private var poll: Timer?
    /// Folders to read again for a few rounds after Download Now or Remove Download (the change may take a moment to
    /// start), with the rounds left.
    private var forced: [String: Int] = [:]
    /// Past this many folders, the least recently loaded that no window shows are forgotten.
    private static let keptFolders = 48

    package func status(for url: URL) -> CloudStatus? {
        statuses[url.lexicallyStandardized.path]
    }

    /// Reads listed items by their captured, lexically normalized path keys, without renormalizing URLs on the UI thread.
    @discardableResult package func load(paths: [String], in folder: URL) -> Task<Void, Never>? {
        let key = folder.lexicallyStandardized.path
        let generation = FolderRead()
        generations[key] = generation
        let added = generation.append(paths)
        cancelReads(in: key)
        guard generations[key] === generation else { return nil }
        return enqueue(added, in: key, generation: generation.id)
    }

    @discardableResult package func append(paths: [String], in folder: URL) -> Task<Void, Never>? {
        let key = folder.lexicallyStandardized.path
        guard let generation = generations[key] else { return load(paths: paths, in: folder) }
        let added = generation.append(paths)
        return added.isEmpty ? nil : enqueue(added, in: key, generation: generation.id)
    }

    @discardableResult private func enqueue(_ paths: [String], in key: String, generation: UUID) -> Task<Void, Never> {
        let id = UUID(), reader = reader, allowance = allowance
        let task = Task { [weak self] in
            defer { self?.requests[id] = nil }
            guard !Task.isCancelled else { return }
            let result = await allowance.run { await reader(paths, key) }
            guard let self else { return }
            guard !Task.isCancelled, generations[key]?.id == generation, let result else { return }
            guard let result else {
                let hadStates = items[key]?.contains { statuses[$0] != nil } == true
                forget(key)
                if hadStates { NotificationCenter.default.post(name: .cloudStatusChanged, object: self) }
                return
            }
            remember(key, paths: generations[key]?.paths ?? [], checked: result.paths, result.statuses)
        }
        requests[id] = (key, task)
        return task
    }

    private func cancelReads(in key: String) {
        let old = requests.filter { $0.value.folder == key }
        for id in old.keys { requests[id] = nil }
        for request in old.values { request.task.cancel() }
    }

    /// Reads these folders again (after Download Now or Remove Download), and keeps reading them for a while.
    package func refresh(_ folders: Set<URL>) {
        for folder in folders {
            let key = folder.lexicallyStandardized.path
            guard items[key] != nil else { continue }
            forced[key] = 5
            readAgain(key)
        }
    }

    private func remember(_ key: String, paths: [String], checked: [String], _ read: [String: CloudStatus]) {
        let previous = items[key] ?? []
        let changed = previous != paths || checked.contains { statuses[$0] != read[$0] }
        let wanted = generations[key]?.known ?? Set(paths)
        for path in previous where !wanted.contains(path) { statuses[path] = nil }
        for path in checked where wanted.contains(path) { statuses[path] = read[path] }
        items[key] = paths
        folders.removeAll { $0 == key }
        folders.append(key)
        trim()
        if changed { NotificationCenter.default.post(name: .cloudStatusChanged, object: self) }
        schedulePoll()
    }

    /// Forgets the oldest folders no window shows, past the limit.
    private func trim() {
        guard folders.count > Self.keptFolders else { return }
        let shown = foldersShown()
        for key in folders where folders.count > Self.keptFolders && !shown.contains(key) { forget(key) }
    }

    private func forget(_ key: String) {
        generations[key] = nil
        cancelReads(in: key)
        for path in items.removeValue(forKey: key) ?? [] { statuses[path] = nil }
        folders.removeAll { $0 == key }
        forced[key] = nil
    }

    /// Polls while a transfer is under way in a shown folder, or one was just asked for.
    private func schedulePoll() {
        guard poll == nil, !foldersToPoll().isEmpty else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFired() }
        }
    }

    private func foldersToPoll() -> [String] {
        let shown = foldersShown()
        return folders.filter { key in
            forced[key] != nil || shown.contains(key) && items[key]?.contains { statuses[$0]?.isActive == true } == true
        }
    }

    private func pollFired() {
        poll = nil
        for key in foldersToPoll() {
            if let rounds = forced[key] { forced[key] = rounds > 1 ? rounds - 1 : nil }
            readAgain(key)
        }
    }

    private func readAgain(_ key: String) {
        guard let paths = items[key], let generation = generations[key], !requests.values.contains(where: { $0.folder == key }) else { return }
        enqueue(paths, in: key, generation: generation.id)
    }

    /// The listed paths and their states, or nil when `folder` isn't a cloud folder (checked first: ordinary
    /// folders cost nothing more).
    @concurrent
    package static func read(_ paths: [String], in folder: String) async -> (paths: [String], statuses: [String: CloudStatus])? {
        guard CloudStatus.isCloudFolder(URL(fileURLWithPath: folder)) else { return nil }
        var result: [String: CloudStatus] = [:]
        for path in paths {
            if Task.isCancelled { return nil }
            if let status = CloudStatus.read(URL(fileURLWithPath: path)) { result[path] = status }
        }
        return (paths, result)
    }
}
