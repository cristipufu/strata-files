import AppKit

/// The searches running in one pane: a query (answered by the index, by Spotlight for tags, or by reading a folder
/// the index doesn't cover), Recents and duplicates. Only the latest runs on: one answering after another started, or
/// after the pane went elsewhere, is dropped.
@MainActor final class PaneSearch {
    private let services: BrowserServices
    private weak var pane: Pane?
    /// The scope bar's line for this pane's search, kept so switching panes shows the right one.
    private(set) var summary = ""
    /// The line changed (the window shows it when this is the active pane).
    var onSummary: ((String) -> Void)?
    /// The latest search's number: one answering with an older number is dropped.
    private(set) var latest = 0
    /// The search running in this pane, stopped when another starts or the pane goes elsewhere.
    private(set) var task: Task<Void, Never>?
    private var duplicateSearch: CancelFlag?
    /// The scan behind a search in a folder the index doesn't cover, kept while you keep searching that folder.
    private var folderScan: FolderSearch?
    /// The scope `folderScan` was made for, as asked.
    private var folderScanScope: URL?
    private let scans: DispatchQueue
    private let waitForRefresh: () async -> Void
    private let waitForScanProgress: (Duration) async -> Void
    private static let largeScanEntryCount = 200_000
    private static let scanRefreshInterval: Duration = .milliseconds(400)
    private static let largeScanRefreshInterval: Duration = .seconds(1)
    private var refreshPending = false
    private var refreshTask: Task<Void, Never>?

    init(pane: Pane, services: BrowserServices, scans: DispatchQueue = FolderSearch.scanQueue,
         waitForRefresh: @escaping () async -> Void = { try? await Task.sleep(for: .seconds(2)) },
         waitForScanProgress: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.pane = pane
        self.services = services
        self.scans = scans
        self.waitForRefresh = waitForRefresh
        self.waitForScanProgress = waitForScanProgress
    }

    isolated deinit { stop() }

    /// An index update must not keep restarting a search before its results land. Coalesce changes and leave a
    /// pause after the current read, so a busy index doesn't keep a full search running continuously.
    func refresh() {
        guard let pane else { return }
        switch pane.destination {
        case .search, .recents: break
        case .folder, .duplicates: return
        }
        refreshPending = true
        if task == nil { scheduleRefresh() }
    }

    /// The index was turned on or off: what this pane shows belongs to the other side of the switch. A folder read
    /// before left out other folders, or took part of its answer from an index that is gone, so it is let go, still
    /// reading or not; then the search starts over at once.
    func indexSwitched() {
        folderScan?.cancel()
        folderScan = nil
        run()
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
    }

    private func scheduleRefresh() {
        guard refreshTask == nil, let target = pane?.destination else { return }
        let generation = latest, wait = waitForRefresh
        refreshTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await wait()
            guard !Task.isCancelled, let self, latest == generation, pane?.destination == target else { return }
            refreshTask = nil
            runSearch()
        }
    }

    private func finished(_ generation: Int) {
        guard generation == latest else { return }
        task = nil
        if refreshPending { scheduleRefresh() }
    }

    /// Runs what the pane shows: its query or Recents, or a search for duplicates.
    func run() {
        guard let p = pane else { return }
        switch p.destination {
        case .search, .recents: runSearch()
        case .duplicates: findDuplicates()
        case .folder: break
        }
    }

    /// The pane goes to `target`: what doesn't serve it stops. A finished folder scan stays a minute, so Back shows its
    /// results at once; a search left behind stops (a Spotlight query would otherwise run on to its time limit).
    func leave(for target: Destination) {
        cancelRefresh()
        if target != .duplicates { duplicateSearch?.set() }
        if case .search = target {} else {
            task?.cancel()
            task = nil
        }
        if case .search(_, let scope?) = target, scope == folderScanScope {} else if folderScan?.isFinished == false {
            folderScan?.cancel()
            folderScan = nil
        }
    }

    /// The pane is closing.
    func stop() {
        cancelRefresh()
        task?.cancel()
        task = nil
        duplicateSearch?.set()
        duplicateSearch = nil
        folderScan?.cancel()
        folderScan = nil
    }

    private func runSearch() {
        guard let p = pane else { return }
        cancelRefresh()
        latest += 1
        let generation = latest
        let target = p.destination
        // Only the latest search runs on: an earlier one (a Spotlight query a keystroke ago) is stopped.
        task?.cancel()
        task = Task {
            defer { finished(generation) }
            switch target {
            case .search(let text, let scope):
                await runQuery(text, in: scope, pane: p, generation: generation, target: target)
            case .recents:
                await runRecents(in: p, generation: generation, target: target)
            case .folder, .duplicates:
                break
            }
        }
    }

    private func runQuery(_ text: String, in scope: URL?, pane p: Pane, generation: Int, target: Destination) async {
        // Finder tags aren't in the index: Spotlight answers those.
        if let query = SpotlightQuery.parse(text) {
            await searchSpotlight(query, in: scope, pane: p, generation: generation, target: target)
        } else if let scope, await !services.index.covers(scope) {
            await searchOutsideIndex(text, in: scope, pane: p, generation: generation, target: target)
        } else {
            await searchIndex(text, in: scope, pane: p, generation: generation, target: target)
        }
    }

    /// Whether `generation` is still the pane's latest search, and the pane still shows it.
    private func isCurrent(_ generation: Int, _ p: Pane, _ target: Destination) -> Bool {
        !Task.isCancelled && generation == latest && p.destination == target
    }

    private func showIndexing(_ p: Pane) {
        guard services.index.isOn else { return showIndexOff(p) }
        p.browser.showMessage(symbol: "hourglass", title: String(localized: "Indexing…"),
                              message: String(localized: "Search works as soon as the first index is built."))
        show(summary: "")
    }

    /// What needs the index says so while it is turned off, with the way to the switch.
    private func showIndexOff(_ p: Pane) {
        let showSetting = services.showSetting
        p.browser.showMessage(
            symbol: "magnifyingglass", title: String(localized: "The index is turned off"),
            message: String(localized: "Search across your Mac, Recents and Duplicates need it. To search a folder, open it and search there: Strata reads it directly."),
            button: (String(localized: "Open Index Settings…"), { showSetting(.indexFiles) }))
        show(summary: "")
    }

    /// A folder the index doesn't cover is read directly, unless that would duplicate the first index while it's
    /// built (and ask for the folders macOS guards in it), or macOS would ask before Strata reads it.
    private func searchOutsideIndex(_ text: String, in scope: URL, pane p: Pane, generation: Int, target: Destination) async {
        let overlaps = await services.index.overlapsIndexedFolders(scope)
        guard isCurrent(generation, p, target) else { return }
        // Turned off, there is no first index to wait for: the folder is read.
        if services.index.isOn, !services.index.isReady, overlaps {
            return showIndexing(p)
        }
        if Privacy.measuringWouldPrompt(scope, browsing: p.location) {
            // A link or saved search pointing into a guarded folder you haven't opened: macOS would ask.
            let name = Places.displayName(scope, copies: services.copies, names: services.folderNames)
            p.browser.showMessage(symbol: "lock", title: String(localized: "Open “\(name)” to search it"),
                                  message: String(localized: "macOS asks before apps read this folder. Open it in Strata once, then search it."))
            show(summary: "")
            return
        }
        await searchDirectly(text, in: scope, pane: p, generation: generation, target: target)
    }

    private func searchIndex(_ text: String, in scope: URL?, pane p: Pane, generation: Int, target: Destination) async {
        // Replaced while the index was asked: the folder scan is a newer search's now.
        guard isCurrent(generation, p, target) else { return }
        folderScan?.cancel()
        folderScan = nil
        let givenUpBefore = NameRegex.namesGivenUp
        let understood = await services.index.understand(text, in: scope)
        guard isCurrent(generation, p, target) else { return }
        guard let result = understood else { return showIndexing(p) }
        let byName = await FileEntry.entries(from: result.hits)
        guard isCurrent(generation, p, target) else { return }
        let byContent = await contentMatches(text, interpretation: result.interpretation, besides: byName, in: scope)
        guard isCurrent(generation, p, target) else { return }
        let total = result.total + byContent.count
        p.browser.showResults(byName + byContent, total: total)
        let scopeName = scope.map { Places.displayName($0, copies: services.copies, names: services.folderNames) }
        show(summary: Self.resultsSummary(total: total, in: scopeName, byContent: byContent.count, interpretation: result.interpretation,
                                   patternGaveUp: NameRegex.namesGivenUp > givenUpBefore))
    }

    /// Documents whose text matches (on-device, Documents/Desktop/Downloads), to follow the name matches. Explicit
    /// filters (ext:, size:…) apply to them too: they're skipped for syntax searches, and a plain-English reading's
    /// kinds, sizes and dates must hold for each one.
    private func contentMatches(_ text: String, interpretation: SearchFilter?, besides byName: [FileEntry],
                                in scope: URL?) async -> [FileEntry] {
        let plainNames = interpretation == nil && IndexQuery.parse(text).searchesContent
        let contentQuery = interpretation?.contentQuery ?? (plainNames ? text : nil)
        var structural = interpretation
        structural?.nameContains = []
        structural?.keywords = []
        let validContentQuery = contentQuery.flatMap { $0.count >= 3 ? $0 : nil }
        let contentHits = validContentQuery != nil
            ? await services.contentIndex.search(validContentQuery ?? "", limit: 15) : []
        let known = Set(byName.map { $0.url.lexicallyStandardized.path })
        let contentURLs = contentHits.map(\.url).filter { url in
            !known.contains(url.lexicallyStandardized.path) && (scope.map { url.path.hasPrefix($0.path + "/") } ?? true)
        }
        return await Self.entries(contentURLs).filter { entry in structural.map { $0.matches(entry) } ?? true }
    }

    /// "12 results in “Documents” · 2 by content · PDFs": how many, where, how many by content, and the search as
    /// it was understood.
    static func resultsSummary(total: Int, in scopeName: String?, byContent: Int, interpretation: SearchFilter?,
                               patternGaveUp: Bool) -> String {
        var parts: [String]
        if let name = scopeName {
            parts = [total == 0 ? String(localized: "No results in “\(name)”")
                : String(localized: "\(total) results in “\(name)”", comment: "plural")]
        } else {
            parts = [total == 0 ? String(localized: "No results everywhere")
                : String(localized: "\(total) results everywhere", comment: "plural")]
        }
        if byContent > 0 {
            parts.append(String(localized: "\(byContent) by content", comment: "plural"))
        }
        if let filter = interpretation { parts.append(filter.summary) }
        if patternGaveUp {
            parts.append(String(localized: "the pattern took too long on some names, so they’re left out"))
        }
        return parts.joined(separator: " · ")
    }

    private func runRecents(in p: Pane, generation: Int, target: Destination) async {
        let recent = await services.index.recentFiles()
        guard isCurrent(generation, p, target) else { return }
        guard recent != nil || services.index.isOn else { return showIndexOff(p) }
        let hits = recent ?? []
        let entries = await FileEntry.entries(from: hits)
        guard isCurrent(generation, p, target) else { return }
        p.browser.showResults(entries, total: hits.count)
    }

    private func show(summary: String) {
        self.summary = summary
        onSummary?(summary)
    }

    /// A search only Spotlight can answer (tags): in `scope`, or on the whole Mac.
    private func searchSpotlight(_ query: SpotlightQuery, in scope: URL?, pane p: Pane, generation: Int, target: Destination) async {
        folderScan?.cancel()
        folderScan = nil
        guard !query.unsupportedSourceFilters else {
            p.browser.showMessage(symbol: "line.3.horizontal.decrease", title: String(localized: "Filters…"),
                                  message: String(localized: "Check the size and date filters. Download origin cannot be combined with name patterns, exclusions or folder filters."))
            show(summary: "")
            return
        }
        let result = await SpotlightSearch.run(query.predicate, scope: scope)
        let entries = await Self.entries(result.urls)
        guard isCurrent(generation, p, target) else { return }
        p.browser.showResults(entries, total: result.total)
        var parts: [String]
        if let scope {
            let name = Places.displayName(scope, copies: services.copies, names: services.folderNames)
            parts = [result.total == 0 ? String(localized: "No results in “\(name)”")
                : String(localized: "\(result.total) results in “\(name)”", comment: "plural")]
        } else {
            parts = [result.total == 0 ? String(localized: "No results on this Mac")
                : String(localized: "\(result.total) results on this Mac", comment: "plural")]
        }
        parts.append(query.summary)
        if result.total > result.urls.count {
            parts.append(String(localized: "first \(result.urls.count) shown", comment: "plural"))
        }
        if result.timedOut { parts.append(String(localized: "Spotlight took too long; results may be incomplete")) }
        show(summary: parts.joined(separator: " · "))
    }

    @concurrent
    private static func entries(_ urls: [URL]) async -> [FileEntry] {
        var found: [FileEntry] = []
        for url in urls {
            guard !Task.isCancelled else { return [] }
            if let entry = autoreleasepool(invoking: { FileEntry(url: url) }) { found.append(entry) }
        }
        return found
    }

    @concurrent
    private static func duplicateEntries(_ groups: [DuplicateGroup]) async -> [String: FileEntry] {
        var found: [String: FileEntry] = [:]
        for group in groups {
            for path in group.paths {
                guard !Task.isCancelled else { return [:] }
                if let entry = autoreleasepool(invoking: { FileEntry(url: URL(fileURLWithPath: path)) }) { found[path] = entry }
            }
        }
        return found
    }

    /// Searches a folder the index doesn't cover by reading it (`FolderSearch`): matches fill in while it reads, the
    /// scope bar counts what's been read, and the summary says the folder was searched directly. Typing more in the same
    /// folder reuses the scan.
    private func searchDirectly(_ text: String, in scope: URL, pane p: Pane, generation: Int, target: Destination) async {
        let search: FolderSearch
        let path = await FolderSearch.path(of: scope)
        guard isCurrent(generation, p, target) else { return }
        if let current = folderScan, current.canServe(path) {
            search = current
        } else {
            let indexed = await services.index.indexedParts(inside: scope)
            guard isCurrent(generation, p, target) else { return }
            let leftOut = await services.index.foldersLeftOut(below: path)
            guard isCurrent(generation, p, target) else { return }
            folderScan?.cancel()
            search = FolderSearch(path: path, indexed: indexed, leavingOut: leftOut, queue: scans)
            folderScan = search
            folderScanScope = scope
            search.start()
        }
        let name = Places.displayName(scope, copies: services.copies, names: services.folderNames)
        // Small folders are done almost at once: give them a moment so they don't flash "Searching…".
        if !search.isFinished { try? await Task.sleep(for: .milliseconds(120)) }
        var shown = -1
        var lastScannedCount: Int?
        while isCurrent(generation, p, target) {
            if let count = lastScannedCount {
                // Searching takes the store's read lock, so large scans get more time between queries.
                await waitForScanProgress(count > Self.largeScanEntryCount ? Self.largeScanRefreshInterval : Self.scanRefreshInterval)
                guard isCurrent(generation, p, target) else { return }
            }
            let finished = search.isFinished
            let scanned = search.scannedCount
            // A stalled reader adds no searchable data. Completion still needs a final query, even for an empty folder.
            guard finished || lastScannedCount != scanned else { continue }
            lastScannedCount = scanned
            let found = await search.search(text)
            guard isCurrent(generation, p, target) else { return }
            if finished || found.total > 0, finished || found.total != shown {
                shown = found.total
                let entries = await FileEntry.entries(from: found.hits)
                guard isCurrent(generation, p, target) else { return }
                p.browser.showResults(entries, total: found.total)
            } else if shown < 0 {
                shown = 0
                p.browser.showMessage(symbol: "magnifyingglass", title: String(localized: "Searching…"),
                                      message: String(localized: "“\(name)” isn’t in the index, so Strata is reading it directly."))
            }
            if finished {
                var parts = [found.total == 0 ? String(localized: "No results in “\(name)”")
                    : String(localized: "\(found.total) results in “\(name)”", comment: "plural")]
                if let filter = found.interpretation { parts.append(filter.summary) }
                parts.append(search.usesIndex ? String(localized: "searched directly, indexed folders from the index")
                                              : String(localized: "not indexed, searched directly"))
                show(summary: parts.joined(separator: " · "))
            } else {
                show(summary: String(localized: "Searching “\(name)” directly… \(search.scannedCount) items", comment: "plural"))
            }
            if finished {
                // The pane keeps this scan for a minute; expiry must not retain it after the pane releases it.
                Task { [weak self, weak search] in
                    try? await Task.sleep(for: .seconds(61))
                    if let self, let search, folderScan === search { folderScan = nil }
                }
                return
            }
        }
    }

    /// Hashes candidates in the background; leaving the view cancels it.
    private func findDuplicates() {
        guard let p = pane else { return }
        latest += 1
        let generation = latest
        task?.cancel()
        task = nil
        duplicateSearch?.set()
        guard services.index.isOn else { return showIndexOff(p) }
        guard services.index.isReady else {
            p.browser.showMessage(symbol: "hourglass", title: String(localized: "Indexing…"),
                                  message: String(localized: "Duplicates appear once the first index is built."))
            return
        }
        p.browser.showMessage(symbol: "square.on.square", title: String(localized: "Looking for duplicates…"))
        let cancelled = CancelFlag()
        duplicateSearch = cancelled
        let services = services
        let updates = LatestUpdate<(Int, Int)> { [weak self, weak p] update in
            guard !cancelled.isSet else { return }
            self?.showDuplicateProgress(update.0, update.1, in: p, generation: generation)
        }
        task = Task { [weak self, weak p] in
            defer { updates.cancel(); self?.finished(generation) }
            let groups = await services.index.duplicates(progress: { done, total in
                updates.send((done, total))
            }, isCancelled: { cancelled.isSet }) ?? []
            guard !Task.isCancelled, !cancelled.isSet else { return }
            let shown = Array(groups.prefix(500))
            // Each copy's details are read away from the main thread: up to 500 groups of them.
            let byPath = await Self.duplicateEntries(shown)
            guard let self, let p, isCurrent(generation, p, .duplicates), !cancelled.isSet else { return }
            let reclaimable = groups.map(\.reclaimable).saturatingSum
            let rows = shown.map { group in
                let entries = group.paths.compactMap { byPath[$0] }
                let name = (group.paths.first as NSString?)?.lastPathComponent ?? ""
                let detail = [
                    String(localized: "\(group.paths.count) copies", comment: "plural"),
                    String(localized: "\(Format.bytes(group.size)) each", comment: "Size of each copy of a duplicate file"),
                    String(localized: "\(Format.bytes(group.reclaimable)) to reclaim", comment: "Disk space freed by removing the extra copies"),
                ].joined(separator: " · ")
                return ResultGroup(title: name, detail: detail, entries: entries)
            }.filter { $0.entries.count > 1 }
            if rows.isEmpty {
                p.browser.showMessage(symbol: "checkmark.circle", title: String(localized: "No duplicates"),
                                      message: String(localized: "No identical files of 1 MB or more."))
            } else {
                p.browser.showGroups(rows, summary: String(localized: "\(groups.count) sets of duplicates", comment: "plural") + " · "
                                     + String(localized: "\(Format.bytes(reclaimable)) to reclaim", comment: "Disk space freed by removing the extra copies"))
            }
        }
    }

    private func showDuplicateProgress(_ done: Int, _ total: Int, in pane: Pane?, generation: Int) {
        guard let pane, isCurrent(generation, pane, .duplicates), task?.isCancelled == false, total > 0 else { return }
        pane.browser.emptyState.show(symbol: "square.on.square", title: String(localized: "Looking for duplicates…"),
                                     message: String(localized: "Checked \(done.formatted()) of \(total) size groups.", comment: "plural"))
    }

    /// Whether `changes` can alter what this pane's active search or Recents view shows.
    func affects(_ changes: IndexChanges) -> Bool {
        guard let pane else { return false }
        switch pane.destination {
        case .folder, .duplicates:
            return false
        case .recents:
            return changes.affectsRecents
        case .search(let text, let scope):
            if SpotlightQuery.parse(text) != nil {
                return scope.map { changes.affects($0.path) } ?? true
            }
            let parsed = IndexQuery.parse(text)
            let scopePath = scope?.lexicallyStandardized.path ?? parsed.scopePath
            let includeHiddenAndNoise = parsed.includeHidden || parsed.includeNoise
                || (scopePath.map { services.index.includesHiddenOrNoise($0) } ?? false)
            if let scopePath {
                return changes.affects(scopePath, includeHiddenAndNoise: includeHiddenAndNoise)
            }
            return includeHiddenAndNoise ? changes.hasChanges : changes.affectsSearch
        }
    }
}
