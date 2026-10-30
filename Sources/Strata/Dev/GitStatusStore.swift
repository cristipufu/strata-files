import AppKit
import CoreServices

extension Notification.Name {
    /// Posted on the main thread when a repository's status changed. `userInfo["root"]` is the work tree URL.
    static let gitStatusDidChange = Notification.Name("StrataGitStatusDidChange")
}

/// Caches `git status` per repository and answers per-URL questions for the file list.
///
/// Status always runs in the background (see `GitStatusLoader`); lookups are synchronous dictionary reads against the
/// last snapshot. Refreshes coalesce: while one runs for a repository, further requests queue a single follow-up, and
/// runs are spaced at least `minimumInterval` apart. A run that times out leaves the repository alone for
/// `timeoutBackoff` unless a refresh is forced (⌘R).
final class GitStatusStore {
    static let shared = GitStatusStore()

    var timeout: TimeInterval = 3
    var ignoredMode: GitIgnoredMode = .matching
    var minimumInterval: TimeInterval = 0.4
    var timeoutBackoff: TimeInterval = 30
    /// A snapshot younger than this is reused when navigating between folders of the same repository.
    var maximumAge: TimeInterval = 2
    /// Off when no git binary is installed.
    var isEnabled = GitRunner.isAvailable
    /// Number of status runs so far, for diagnostics.
    private(set) var completedRuns = 0

    // Everything is keyed by standardized path: URLs for the same folder can differ by a trailing slash.
    private var repositoriesByFolder: [String: GitRepository?] = [:]
    private var repositoriesByRoot: [String: GitRepository] = [:]
    private var snapshots: [String: GitStatusSnapshot] = [:]
    private var lastFailure: [String: (outcome: GitStatusSnapshot.Outcome, date: Date)] = [:]
    private var stale: Set<String> = []
    private var running: [String: Task<GitStatusSnapshot, Never>] = [:]
    private var rerun: Set<String> = []
    private var lastStart: [String: Date] = [:]
    private var watchers: [String: (watcher: GitRepoWatcher, count: Int)] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: - Repositories

    /// The repository whose work tree contains `folder`, as last found. Not found yet, it's looked for away from the
    /// main thread (an lstat or two at every level up to "/", each a round trip on a server) and nil until then; a
    /// status change says when it's found. `observe` looks again.
    func repository(containing folder: URL) -> GitRepository? {
        let path = folder.standardizedFileURL.path
        if let cached = repositoriesByFolder[path] { return cached }
        find(path)
        return nil
    }

    /// The same, waiting for the lookup when it isn't known yet: for deciding something by it, such as which of a
    /// project's folders git tracks.
    func repositoryFound(containing folder: URL) async -> GitRepository? {
        let path = folder.standardizedFileURL.path
        if let cached = repositoriesByFolder[path] { return cached }
        return await find(path).value
    }


    /// The repository an item in the list belongs to: its parent folder's. (A nested repository's root is an
    /// untracked folder of the outer one, which is how it should look from outside.)
    func repository(forItem url: URL) -> GitRepository? {
        repository(containing: url.standardizedFileURL.deletingLastPathComponent())
    }

    private var finding: [String: (id: UUID, task: Task<GitRepository?, Never>)] = [:]
    /// The newest lookup of each folder: only it may record what it found, however the lookups end.
    private var newestFind: [String: UUID] = [:]

    /// Looks for the repository holding `path` away from the main thread, once however often it's asked meanwhile;
    /// `fresh` looks again even then.
    @discardableResult
    private func find(_ path: String, fresh: Bool = false) -> Task<GitRepository?, Never> {
        if !fresh, let finding = finding[path] { return finding.task }
        let enabled = isEnabled, id = UUID()
        newestFind[path] = id
        let task = Task { [weak self] in
            let repository = enabled ? await Self.locate(path) : nil
            guard let self else { return repository }
            if finding[path]?.id == id { finding[path] = nil }
            guard newestFind[path] == id else { return repository }
            newestFind[path] = nil
            let known = repositoriesByFolder[path] != nil
            record(repository, at: path)
            if let repository, !known {
                NotificationCenter.default.post(name: .gitStatusDidChange, object: self, userInfo: ["root": repository.root])
            }
            return repository
        }
        finding[path] = (id, task)
        return task
    }

    @concurrent private static func locate(_ path: String) async -> GitRepository? {
        GitRepository.locate(from: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func record(_ repository: GitRepository?, at path: String) {
        if let cached = repositoriesByFolder[path], cached != repository {
            // A repository appeared or vanished (git init, rm -rf .git): every cached answer may be wrong now.
            repositoriesByFolder.removeAll()
        } else if repositoriesByFolder.count > 4096 {
            repositoriesByFolder.removeAll()
        }
        repositoriesByFolder[path] = .some(repository)
        if let repository { repositoriesByRoot[repository.rootPath] = repository }
    }

    func snapshot(for root: URL) -> GitStatusSnapshot? {
        snapshots[Self.key(root)]
    }

    func snapshot(containing folder: URL) -> GitStatusSnapshot? {
        repository(containing: folder).flatMap { snapshots[$0.rootPath] }
    }

    /// Why the last run for `root` produced no fresh data, if it didn't.
    func lastFailure(for root: URL) -> GitStatusSnapshot.Outcome? {
        lastFailure[Self.key(root)]?.outcome
    }

    // MARK: - Observing

    /// Starts tracking the repository containing `folder` while the returned token is alive: re-checks, away from the
    /// main thread, which repository the folder is in, watches the work tree and git directory (FSEvents) so edits,
    /// staging, commits and checkouts made anywhere refresh it, and runs status unless a watched snapshot is already
    /// current. Returns nil outside a repository.
    func observe(_ folder: URL) async -> GitObservation? {
        guard let repository = await find(folder.standardizedFileURL.path, fresh: true).value else { return nil }
        let root = repository.rootPath
        let watched = watchers[root] != nil
        let isFresh = snapshots[root].map { watched || Date().timeIntervalSince($0.date) < maximumAge } ?? false
        if !isFresh || stale.contains(root) { refresh(repository) }
        if var entry = watchers[root] {
            entry.count += 1
            watchers[root] = entry
        } else if let watcher = GitRepoWatcher(repository: repository, snapshot: snapshots[root], onChange: { [weak self] in
            self?.invalidate(rootPath: root)
        }) {
            watchers[root] = (watcher, 1)
        }
        return GitObservation(store: self, repository: repository)
    }

    /// Whether an FSEvents watcher is keeping `root` current (it can fail to start, e.g. on some network volumes).
    func isWatching(root: URL) -> Bool {
        watchers[Self.key(root)] != nil
    }

    fileprivate func endObserving(_ root: String) {
        guard var entry = watchers[root] else { return }
        entry.count -= 1
        watchers[root] = entry.count > 0 ? entry : nil
    }

    // MARK: - Refreshing

    /// Marks `root`'s status out of date and refreshes it (coalesced). The hook for anything that knows the work
    /// tree changed: a DirectoryWatcher event, a file operation, the window becoming key.
    func invalidate(root: URL) {
        invalidate(rootPath: Self.key(root))
    }

    private func invalidate(rootPath root: String) {
        stale.insert(root)
        if let repository = repositoriesByRoot[root] { refresh(repository) }
    }

    /// Re-runs status for the repository containing `url`, if any.
    func invalidate(containing url: URL) {
        if let repository = repository(containing: url) { invalidate(root: repository.root) }
    }

    /// Runs status now, or queues one follow-up run if one is already going. `force` ignores the time-out back-off.
    func refresh(_ repository: GitRepository, force: Bool = false) {
        guard isEnabled else { return }
        let root = repository.rootPath
        repositoriesByRoot[root] = repository
        if !force, let failure = lastFailure[root], failure.outcome == .timedOut,
           Date().timeIntervalSince(failure.date) < timeoutBackoff {
            return
        }
        if running[root] != nil {
            rerun.insert(root)
            return
        }
        let delay = max(0, minimumInterval - Date().timeIntervalSince(lastStart[root] ?? .distantPast))
        let mode = ignoredMode
        let timeout = timeout
        running[root] = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            self.lastStart[root] = Date()
            self.stale.remove(root)
            let snapshot = await GitStatusLoader.load(repository, mode: mode, timeout: timeout)
            self.finish(snapshot)
            return snapshot
        }
    }

    /// The current status of `repository`: the cached snapshot when fresh, else the result of the running or a new
    /// run. Used by loaders that need status before they can answer (the project inspector).
    func status(of repository: GitRepository) async -> GitStatusSnapshot? {
        let root = repository.rootPath
        if let task = running[root] { return await task.value }
        if let snapshot = snapshots[root], !stale.contains(root), Date().timeIntervalSince(snapshot.date) < maximumAge {
            return snapshot
        }
        refresh(repository, force: true)
        guard let task = running[root] else { return snapshots[root] }
        return await task.value
    }

    private func finish(_ snapshot: GitStatusSnapshot) {
        let root = snapshot.repository.rootPath
        running[root] = nil
        completedRuns += 1
        let previous = snapshots[root]
        if snapshot.isComplete {
            lastFailure[root] = nil
            snapshots[root] = snapshot
        } else {
            lastFailure[root] = (snapshot.outcome, snapshot.date)
            // Keep showing the last complete result rather than blanking every badge.
            if previous?.isComplete != true { snapshots[root] = snapshot }
        }
        if previous?.fingerprint != snapshots[root]?.fingerprint {
            if let current = snapshots[root] { watchers[root]?.watcher.update(from: current) }
            NotificationCenter.default.post(name: .gitStatusDidChange, object: self, userInfo: ["root": snapshot.root])
        }
        if rerun.remove(root) != nil, let repository = repositoriesByRoot[root] {
            refresh(repository)
        }
    }

    // MARK: - Lookups for the file list

    /// State of an item in the list; nil when it isn't in a repository or status hasn't arrived yet.
    func state(of url: URL, isDirectory: Bool) -> GitFileState? {
        guard let (snapshot, path) = locateItem(url) else { return nil }
        return snapshot.state(forRelativePath: path, isDirectory: isDirectory)
    }

    func pathStatus(of url: URL) -> GitPathStatus? {
        guard let (snapshot, path) = locateItem(url) else { return nil }
        return snapshot.status(forRelativePath: path)
    }

    /// Whether git ignores `url` (directly, or because a folder above it is ignored). Use it to dim rows.
    func isIgnored(_ url: URL) -> Bool {
        guard let (snapshot, path) = locateItem(url) else { return false }
        return snapshot.isIgnored(relativePath: path)
    }

    /// What to draw in the name cell, or nil for clean and ignored items.
    func badge(for url: URL, isDirectory: Bool) -> GitBadge? {
        guard let (snapshot, path) = locateItem(url) else { return nil }
        let state = snapshot.state(forRelativePath: path, isDirectory: isDirectory)
        guard state != .clean, state != .ignored else { return nil }
        let status = snapshot.status(forRelativePath: path)
        return GitBadge(state: state, staging: isDirectory ? nil : status?.staging, isFolder: isDirectory,
                        originalPath: status?.originalPath)
    }

    /// The hot path for list rows: plain string work on `url.path`, which the browser already standardizes. Other
    /// spellings (`/private/tmp/…`, `..`) take one standardization.
    private func locateItem(_ url: URL) -> (GitStatusSnapshot, String)? {
        let path = url.path
        if let found = locateItem(path: path) { return found }
        guard path.hasPrefix("/private/") || path.contains("/./") || path.contains("/../") || path.contains("//") else {
            return nil
        }
        let standardized = url.standardizedFileURL.path
        return standardized == path ? nil : locateItem(path: standardized)
    }

    private func locateItem(path: String) -> (GitStatusSnapshot, String)? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        guard let cached = repositoriesByFolder[parent] else {
            find(parent)
            return nil
        }
        guard let repository = cached, let snapshot = snapshots[repository.rootPath],
              let relative = GitStatusSnapshot.relativePath(path, root: repository.rootPath), !relative.isEmpty else { return nil }
        return (snapshot, relative)
    }
}

/// Keeps a repository watched; drop it (or assign another) to stop.
@MainActor final class GitObservation {
    let repository: GitRepository
    private weak var store: GitStatusStore?

    fileprivate init(store: GitStatusStore, repository: GitRepository) {
        self.store = store
        self.repository = repository
    }

    /// False when FSEvents couldn't watch the repository: callers should then invalidate on their own change
    /// signals (the browser's DirectoryWatcher).
    var isWatching: Bool { store?.isWatching(root: repository.root) ?? false }

    isolated deinit {
        store?.endObserving(repository.rootPath)
    }
}

// MARK: - Watching a repository

/// Decides whether a file-system event path could change `git status`. Sendable, so FSEvents batches are filtered on
/// a background queue: a build writing thousands of files into an ignored `target/` costs the main thread nothing.
nonisolated struct GitEventFilter: Sendable {
    /// The work tree root and git directory, each as given and as the real path (FSEvents reports /private/tmp/…
    /// where standardized URLs say /tmp/…).
    let rootPaths: [String]
    let gitPaths: [String]
    var ignoredDirectories: Set<String> = []
    var ignoredFiles: Set<String> = []

    init(repository: GitRepository) {
        func variants(_ url: URL) -> [String] {
            let path = url.standardizedFileURL.path
            guard let real = realpath(path, nil) else { return [path] }
            defer { free(real) }
            let resolved = String(cString: real)
            return resolved == path ? [path] : [resolved, path]
        }
        rootPaths = variants(repository.root)
        gitPaths = variants(repository.gitDirectory)
    }

    func isRelevant(_ rawPath: String) -> Bool {
        let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        for gitPath in gitPaths {
            guard let inside = GitStatusSnapshot.relativePath(path, root: gitPath) else { continue }
            // Index, HEAD, refs, MERGE_HEAD… matter; object-store churn, reflogs, hooks and lock files don't.
            let first = inside.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return !["objects", "logs", "lfs", "fsmonitor--daemon", "hooks", "info"].contains(first)
                && !inside.hasSuffix(".lock")
        }
        for rootPath in rootPaths {
            guard let inside = GitStatusSnapshot.relativePath(path, root: rootPath) else { continue }
            if inside.isEmpty { return true }
            if inside == ".git" || inside.hasPrefix(".git/") {
                return isRelevant(gitPaths[0] + inside.dropFirst(4))
            }
            return !isIgnored(inside)
        }
        return true
    }

    private func isIgnored(_ path: String) -> Bool {
        if ignoredFiles.contains(path) || ignoredDirectories.contains(path) { return true }
        var end = path.endIndex
        while let slash = path[path.startIndex..<end].lastIndex(of: "/") {
            if ignoredDirectories.contains(String(path[path.startIndex..<slash])) { return true }
            end = slash
        }
        return false
    }
}

/// FSEvents on the work tree (and the git directory, when a worktree or submodule keeps it elsewhere). Calls
/// `onChange` on the main thread for changes git status could notice: work tree edits outside ignored paths, and
/// index, HEAD, ref and merge-state changes. Filtering happens on a background queue.
@MainActor final class GitRepoWatcher {
    private var stream: FSEventStreamRef?
    private let context: GitWatcherContext

    init?(repository: GitRepository, snapshot: GitStatusSnapshot?, onChange: @escaping @MainActor () -> Void) {
        var filter = GitEventFilter(repository: repository)
        if let snapshot {
            filter.ignoredDirectories = snapshot.ignoredDirectories
            filter.ignoredFiles = snapshot.ignoredFiles
        }
        context = GitWatcherContext(filter: filter, onChange: onChange)

        var watched = [repository.rootPath]
        let gitDir = repository.gitDirectory.standardizedFileURL.path
        if !gitDir.hasPrefix(repository.rootPath + "/") { watched.append(gitDir) }

        // The stream owns one reference to the context and releases it when the stream is freed, so a callback that's
        // already running on the queue can never see a dead context.
        var streamContext = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(context).toOpaque(),
                                                 retain: nil, release: gitWatcherContextRelease, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, gitWatcherCallback, &streamContext, watched as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            Unmanaged.passUnretained(context).release()
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, GitWatcherContext.queue)
        FSEventStreamStart(stream)
    }

    isolated deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// New ignore lists from a fresh snapshot.
    func update(from snapshot: GitStatusSnapshot) {
        context.updateIgnored(directories: snapshot.ignoredDirectories, files: snapshot.ignoredFiles)
    }

    var filter: GitEventFilter { context.currentFilter }
}

nonisolated final class GitWatcherContext: @unchecked Sendable {
    static let queue = DispatchQueue(label: "dev.strata.git-events", qos: .utility)
    private let lock = NSLock()
    private var filter: GitEventFilter
    private let onChange: @MainActor () -> Void

    init(filter: GitEventFilter, onChange: @escaping @MainActor () -> Void) {
        self.filter = filter
        self.onChange = onChange
    }

    var currentFilter: GitEventFilter { lock.withLock { filter } }

    func updateIgnored(directories: Set<String>, files: Set<String>) {
        lock.withLock {
            filter.ignoredDirectories = directories
            filter.ignoredFiles = files
        }
    }

    func handle(_ paths: [String]) {
        let filter = currentFilter
        guard paths.contains(where: filter.isRelevant) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onChange() }
        }
    }
}

nonisolated private func gitWatcherCallback(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                                            _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                                            _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info, count > 0 else { return }
    let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    let list = (0..<count).map { String(cString: cPaths[$0]) }
    Unmanaged<GitWatcherContext>.fromOpaque(info).takeUnretainedValue().handle(list)
}

nonisolated private func gitWatcherContextRelease(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    Unmanaged<GitWatcherContext>.fromOpaque(info).release()
}

// MARK: - Display

/// What the file list draws for one item.
struct GitBadge: Equatable {
    let state: GitFileState
    /// Staged / unstaged / both, for tracked files.
    let staging: GitStaging?
    /// Folders show a dot in the color of the most notable change inside; files show a letter.
    let isFolder: Bool
    var originalPath: String? = nil

    var letter: String { state.letter }
    var color: NSColor { state.color }

    /// "Modified, staged", "Renamed from docs/old.md", "Contains modified files"…
    var accessibilityLabel: String {
        if isFolder {
            switch state {
            case .untracked: return String(localized: "Untracked folder", comment: "Git status of a folder")
            case .ignored: return String(localized: "Ignored", comment: "Git status of a file or folder")
            case .clean: return String(localized: "Contains unmodified files", comment: "Git status of a folder")
            case .copied: return String(localized: "Contains copied files", comment: "Git status of a folder")
            case .added: return String(localized: "Contains added files", comment: "Git status of a folder")
            case .renamed: return String(localized: "Contains renamed files", comment: "Git status of a folder")
            case .deleted: return String(localized: "Contains deleted files", comment: "Git status of a folder")
            case .modified: return String(localized: "Contains modified files", comment: "Git status of a folder")
            case .conflicted: return String(localized: "Contains conflicted files", comment: "Git status of a folder")
            }
        }
        var parts = [state.title]
        if let originalPath, state == .renamed {
            parts[0] = String(localized: "Renamed from \(originalPath)", comment: "Git status of a file; the placeholder is its previous path")
        } else if let originalPath, state == .copied {
            parts[0] = String(localized: "Copied from \(originalPath)", comment: "Git status of a file; the placeholder is the path it was copied from")
        }
        switch staging {
        case .staged: parts.append(String(localized: "staged", comment: "Git: the file's change is staged"))
        case .unstaged: parts.append(String(localized: "not staged", comment: "Git: the file's change is not staged"))
        case .partiallyStaged: parts.append(String(localized: "partially staged", comment: "Git: the file's changes are partly staged"))
        case nil: break
        }
        return parts.joined(separator: ", ")
    }
}

extension GitFileState {
    /// git's own short-status letters: U is a conflict (unmerged), ? untracked, ! ignored.
    var letter: String {
        switch self {
        case .clean: return ""
        case .ignored: return "!"
        case .untracked: return "?"
        case .copied: return "C"
        case .added: return "A"
        case .renamed: return "R"
        case .deleted: return "D"
        case .modified: return "M"
        case .conflicted: return "U"
        }
    }

    var title: String {
        switch self {
        case .clean: return String(localized: "Unmodified", comment: "Git status of a file or folder")
        case .ignored: return String(localized: "Ignored", comment: "Git status of a file or folder")
        case .untracked: return String(localized: "Untracked", comment: "Git status of a file or folder")
        case .copied: return String(localized: "Copied", comment: "Git status of a file or folder")
        case .added: return String(localized: "git.status.added", defaultValue: "Added", comment: "Git status of a file or folder")
        case .renamed: return String(localized: "Renamed", comment: "Git status of a file or folder")
        case .deleted: return String(localized: "Deleted", comment: "Git status of a file or folder")
        case .modified: return String(localized: "git.status.modified", defaultValue: "Modified", comment: "Git status of a file or folder")
        case .conflicted: return String(localized: "Conflicted", comment: "Git status of a file or folder")
        }
    }

    var accessibilityLabel: String { title }

    /// Tuned per appearance so the letters read at 10 pt on both the light and dark list backgrounds: the light
    /// variants are deeper than the system colors, the dark ones a touch brighter.
    var color: NSColor {
        switch self {
        case .modified: return GitColors.modified
        case .added: return GitColors.added
        case .deleted: return GitColors.deleted
        case .renamed, .copied: return GitColors.renamed
        case .untracked: return GitColors.untracked
        case .conflicted: return GitColors.conflicted
        case .ignored, .clean: return .tertiaryLabelColor
        }
    }
}

enum GitColors {
    typealias RGB = (CGFloat, CGFloat, CGFloat)

    /// Letter and dot colors: deeper than the system colors in light mode so 10 pt letters stay legible on white,
    /// brighter in dark mode.
    static let modified = dynamic(light: (0.80, 0.47, 0.00), dark: (1.00, 0.72, 0.30), name: "gitModified")
    static let added = dynamic(light: (0.16, 0.60, 0.25), dark: (0.36, 0.84, 0.45), name: "gitAdded")
    static let deleted = dynamic(light: (0.85, 0.20, 0.18), dark: (1.00, 0.45, 0.42), name: "gitDeleted")
    static let renamed = dynamic(light: (0.12, 0.45, 0.88), dark: (0.42, 0.68, 1.00), name: "gitRenamed")
    static let untracked = dynamic(light: (0.00, 0.56, 0.62), dark: (0.30, 0.82, 0.86), name: "gitUntracked")
    static let conflicted = dynamic(light: (0.62, 0.25, 0.85), dark: (0.80, 0.55, 1.00), name: "gitConflicted")

    /// Fills for solid (staged) tiles under a white letter: deep enough for contrast in both appearances.
    static func solid(_ state: GitFileState) -> NSColor {
        switch state {
        case .modified: return solidModified
        case .added: return solidAdded
        case .deleted: return solidDeleted
        case .renamed, .copied: return solidRenamed
        case .untracked: return solidUntracked
        case .conflicted: return solidConflicted
        case .ignored, .clean: return .tertiaryLabelColor
        }
    }

    private static let solidModified = dynamic(light: (0.84, 0.50, 0.00), dark: (0.78, 0.48, 0.02), name: "gitSolidModified")
    private static let solidAdded = dynamic(light: (0.16, 0.60, 0.25), dark: (0.17, 0.56, 0.26), name: "gitSolidAdded")
    private static let solidDeleted = dynamic(light: (0.85, 0.20, 0.18), dark: (0.80, 0.24, 0.22), name: "gitSolidDeleted")
    private static let solidRenamed = dynamic(light: (0.12, 0.45, 0.88), dark: (0.15, 0.45, 0.85), name: "gitSolidRenamed")
    private static let solidUntracked = dynamic(light: (0.00, 0.53, 0.60), dark: (0.03, 0.50, 0.56), name: "gitSolidUntracked")
    private static let solidConflicted = dynamic(light: (0.60, 0.25, 0.84), dark: (0.55, 0.28, 0.80), name: "gitSolidConflicted")

    private static func dynamic(light: RGB, dark: RGB, name: String) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
}
