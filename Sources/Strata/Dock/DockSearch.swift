import AppKit
import ApplicationServices

/// Settings ▸ General ▸ Search box in the Dock (off unless you turn it on). Apple's Dock takes no plug-ins, so Strata
/// keeps a gap of empty spacer tiles in it (see `DockGapTiles`), right after its own icon, and floats its own search box
/// over them, shaped like the icons around it. It finds what ⌘K finds (see `DockSearchItems`), plus apps, plain English
/// and documents by their content; results rise above it in ⌘K's rows. Where the Dock draws the gap is read through
/// Accessibility, which the box needs to find its place.
final class DockSearch: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = DockSearch()

    private let box = DockSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 38),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let results = DockSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 100),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private let boxGlass = NSGlassEffectView()
    private let ranker = PaletteRanker()
    private var pathQuery = PathQuery()
    private var follower: Timer?
    private let reader = DockReader()
    private var placed: NSRect?
    private var pendingRank: DispatchWorkItem?
    private let readTiles: () -> [[String: Any]]?
    private let writeTiles: ([[String: Any]]) -> Void
    private let restartDock: () -> Void
    /// Rows the card has room for: it grows as results come in but doesn't shrink while you type (no jumping).
    private var cardRows = 0
    /// What the table shows, to leave it alone when an update brings the same rows.
    private var shownRows: [String] = []

    private static let rowHeight: CGFloat = 46
    private static let maxVisibleRows = 8
    private static let resultsWidth: CGFloat = 560

    init(notifications: NotificationCenter = .default,
         readTiles: @escaping () -> [[String: Any]]? = DockGapTiles.read,
         writeTiles: @escaping ([[String: Any]]) -> Void = DockGapTiles.write,
         restartDock: @escaping () -> Void = DockGapTiles.restartDock) {
        self.readTiles = readTiles
        self.writeTiles = writeTiles
        self.restartDock = restartDock
        super.init()
        build()
        ranker.queryItems = { [weak self] query in
            guard let self else { return [] }
            return DockSearchItems.pathItems(query, pathQuery)
        }
        ranker.lateItems = { query in await DockSearchItems.lateItems(query) }
        ranker.goToPath = { url in DockSearchItems.show(url) }
        ranker.emptyResults = { source in
            let workspaces: [PaletteItem] = Array(source.filter { $0.kind == .workspace }.prefix(3))
            let folders: [PaletteItem] = Array(source.filter { $0.kind == .folder }.prefix(6))
            return workspaces + folders
        }
        ranker.lateArrived = { [weak self] keeping in self?.showResults(keeping: keeping) }
        // Index and documents only once typing pauses; names (folders, apps, commands) as you type.
        ranker.lateDelay = .milliseconds(180)
        ranker.selectedTitle = { [weak self] in
            guard let self, ranker.results.indices.contains(table.selectedRow) else { return nil }
            return ranker.results[table.selectedRow].item.title
        }
        // The saved setting stays on for next launch, but the box and its gap only belong to a running Strata.
        notifications.addObserver(self, selector: #selector(disable), name: NSApplication.willTerminateNotification, object: nil)
    }

    // MARK: - On and off

    /// Matches Settings: the gap and the box when it's on, neither when it's turned off. At launch with it off, the Dock
    /// isn't touched at all.
    func apply(atLaunch: Bool = false) {
        if Prefs.shared.dockSearch {
            enable()
        } else if !atLaunch {
            disable()
        }
    }

    private func enable() {
        // The box can't be placed without reading the Dock; macOS asks once (System Settings ▸ Privacy & Security).
        if !AXIsProcessTrusted() {
            // kAXTrustedCheckOptionPrompt's value, spelled out (the global isn't concurrency-safe).
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if let apps = readTiles() {
            let changed = DockGapTiles.adding(to: apps, after: Self.bundleID)
            if changed.count != apps.count {
                writeTiles(changed)
                restartDock()
            }
        }
        guard follower == nil else { return }
        follower = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        follow()
    }

    @objc private func disable() {
        follower?.invalidate()
        follower = nil
        placed = nil
        clear()
        box.orderOut(nil)
        guard let apps = readTiles() else { return }
        let changed = DockGapTiles.removing(from: apps)
        guard changed.count != apps.count else { return }
        writeTiles(changed)
        restartDock()
    }

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "dev.strata.app" }

    // MARK: - Keeping the box over the gap

    /// Puts the box over the gap, sized and rounded like the icons beside it; hides it while the gap isn't shown (the
    /// Dock hidden, on the left or right, or not open to Accessibility yet).
    private func follow() {
        guard let layout = reader.layout(anchor: Self.bundleID) else {
            if placed != nil {
                placed = nil
                clear()
                box.orderOut(nil)
            }
            return
        }
        let frame = layout.boxFrame
        guard frame != placed else { return }
        placed = frame
        box.setFrame(frame, display: true)
        boxGlass.cornerRadius = layout.cornerRadius
        field.font = .systemFont(ofSize: max(12, min(15, frame.height * 0.37)))
        box.orderFrontRegardless()
        placeResults()
    }

    private func placeResults() {
        let typing = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        // While you type, the card stays up even between results (the slow ones still coming).
        guard let placed, box.isKeyWindow || results.isKeyWindow,
              !ranker.results.isEmpty || (typing && ranker.isSearching && cardRows > 0) else {
            results.orderOut(nil)
            cardRows = 0
            return
        }
        let count = min(ranker.results.count, Self.maxVisibleRows)
        cardRows = typing ? max(cardRows, count) : count
        let margin = ShadowedGlass.margin
        let rows = CGFloat(max(cardRows, 1))
        let width = Self.resultsWidth + margin * 2
        let height = rows * Self.rowHeight + 12 + margin * 2
        let screen = NSScreen.screens.first { $0.frame.intersects(placed) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? placed
        // The card's glass starts at the box's left edge, 10 points above it; it stays on screen.
        let x = min(max(placed.minX - margin, visible.minX - margin + 8), visible.maxX + margin - 8 - width)
        let frame = NSRect(x: x, y: placed.maxY + 10 - margin, width: width, height: height)
        if results.frame != frame { results.setFrame(frame, display: true) }
        table.tableColumns.first?.width = Self.resultsWidth - 8
        if !results.isVisible { results.orderFrontRegardless() }
    }

    // MARK: - Searching

    @objc private func boxBecameKey() {
        // What there is to find changes between visits (folders used, workspaces saved, apps installed).
        ranker.source = DockSearchItems.items()
        pathQuery = PathQuery()
        ranker.rank(field.stringValue)
        showResults()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Keystrokes in quick succession rank once, after the last of them.
        pendingRank?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingRank = nil
                self.ranker.rank(self.field.stringValue)
                self.showResults()
            }
        }
        pendingRank = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }

    private func showResults(keeping selectedTitle: String? = nil) {
        let rows = ranker.results
        let keys = rows.map { "\($0.item.title)\u{1}\($0.item.subtitle)\u{1}\($0.matches)" }
        // The same rows again (a keystroke that changed nothing shown): no redraw.
        if keys != shownRows {
            shownRows = keys
            table.reloadData()
        }
        let keep = selectedTitle.flatMap { title in rows.firstIndex { $0.item.title == title } } ?? 0
        if !rows.isEmpty, table.selectedRow != keep {
            table.selectRowIndexes([keep], byExtendingSelection: false)
            table.scrollRowToVisible(keep)
        }
        placeResults()
    }

    private func clear() {
        pendingRank?.cancel()
        field.stringValue = ""
        ranker.cancel()
        shownRows = []
        table.reloadData()
        cardRows = 0
        results.orderOut(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            // ⌘Return shows the item in Strata instead of opening it.
            finishTyping()
            run(table.selectedRow, reveal: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { box.resignKey() }
            clear()
        default:
            return false
        }
        return true
    }

    /// Return and the arrows act on what was typed, not on the results from a keystroke before.
    private func finishTyping() {
        guard let pending = pendingRank else { return }
        pending.cancel()
        pendingRank = nil
        ranker.rank(field.stringValue)
        showResults()
    }

    private func moveSelection(_ delta: Int) {
        finishTyping()
        let rows = ranker.results.count
        guard rows > 0 else { return }
        let row = max(0, min(rows - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clickedRow() {
        run(table.clickedRow, reveal: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func run(_ row: Int, reveal: Bool) {
        guard ranker.results.indices.contains(row) else { return }
        let item = ranker.results[row].item
        run(item, reveal: reveal)
    }

    private func run(_ item: PaletteItem, reveal: Bool) {
        clear()
        box.resignKey()
        if reveal, let url = item.url {
            (NSApp.delegate as? AppDelegate)?.revealInStrata([url])
        } else {
            item.run()
        }
    }

    @objc private func focusLeft() {
        // Results stay while one is being clicked; anywhere else closes them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.box.isKeyWindow, !self.results.isKeyWindow else { return }
                self.results.orderOut(nil)
            }
        }
    }

    // MARK: - Results table (⌘K's rows)

    func numberOfRows(in tableView: NSTableView) -> Int { ranker.results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard ranker.results.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("PaletteCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PaletteCell ?? {
            let cell = PaletteCell()
            cell.identifier = id
            return cell
        }()
        let result = ranker.results[row]
        cell.configure(result.item, matches: result.matches)
        cell.isRowSelected = row == tableView.selectedRow
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = table.selectedRow
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? PaletteCell)?.isRowSelected = row == selected
        }
    }

    // MARK: - Views

    private func build() {
        let aboveDock = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        for panel in [box, results] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // Neither has a window shadow: the Dock's icons cast none, and on a focused panel it's a dark ring that
            // doesn't follow the glass. The results card's glass draws its own (`ShadowedGlass`).
            panel.hasShadow = false
            panel.level = aboveDock
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.isExcludedFromWindowsMenu = true
            panel.isReleasedWhenClosed = false
        }

        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        magnifier.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        magnifier.contentTintColor = .secondaryLabelColor
        field.placeholderString = String(localized: "Search files and apps", comment: "The search box in the Dock: placeholder")
        field.setAccessibilityLabel(String(localized: "Search files and apps", comment: "The search box in the Dock: placeholder"))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        let row = NSView()
        for view in [magnifier, field] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            magnifier.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        boxGlass.cornerRadius = 9
        boxGlass.contentView = row
        box.contentView = boxGlass

        // The results: ⌘K's rows on glass, rising above the box.
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedRow)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        let card = ShadowedGlass(cornerRadius: 18)
        card.glass.contentView = scroll
        results.contentView = card

        NotificationCenter.default.addObserver(self, selector: #selector(boxBecameKey), name: NSWindow.didBecomeKeyNotification, object: box)
        NotificationCenter.default.addObserver(self, selector: #selector(focusLeft), name: NSWindow.didResignKeyNotification, object: box)
        NotificationCenter.default.addObserver(self, selector: #selector(focusLeft), name: NSWindow.didResignKeyNotification, object: results)
    }
}

/// A borderless panel that takes typing without making Strata the active app, but only once you've clicked it: on its
/// own it never becomes the key window (macOS would otherwise pick it when Strata comes to the front from the Dock, and
/// open the results).
final class DockSearchPanel: NSPanel {
    private var clicked = false

    override var canBecomeKey: Bool { clicked }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { clicked = true }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        clicked = false
    }
}

// MARK: - What it finds

/// The Dock's search box finds what ⌘K finds without a window to act on (folders you use, places, workspaces, path
/// lookups like `github/acme`), apps, and the commands that work from anywhere. Then, as they arrive: files and folders
/// from the index, plain English understood ("pdfs from last week"), documents whose text matches (on this Mac), and a
/// row that opens the whole search in a window. Folders open in Strata; files and apps open; ⌘Return shows any of them
/// in Strata.
@MainActor
enum DockSearchItems {
    static func items() -> [PaletteItem] {
        folders() + workspaces() + apps() + commands()
    }

    /// Shows a folder in Strata; anything else, selected in its folder.
    static func show(_ url: URL) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        if FileEntry.isNavigableFolder(url) { delegate.showFolder(url) } else { delegate.revealInStrata([url]) }
    }

    private static func folders() -> [PaletteItem] {
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        var seen = Set<String>()
        var items: [PaletteItem] = []
        let services = BrowserServices.shared, places = services.places
        places.refresh()
        let visited = services.visits.ranked().filter { places.isFolder($0.path) != false }.prefix(400)
        for (rank, url) in visited.enumerated() where seen.insert(url.path).inserted {
            items.append(PaletteItem(title: Places.displayName(url, copies: services.copies, checks: places), subtitle: Format.tildePath(url.deletingLastPathComponent()),
                                     icon: folderIcon, kind: .folder, boost: max(0, 24 - rank / 2), url: url) { show(url) })
        }
        for place in Places.favorites(preferences: services.preferences, checks: places) + places.snapshot.volumes
        where seen.insert(place.url.path).inserted {
            items.append(PaletteItem(title: place.title, subtitle: Format.tildePath(place.url), icon: IconCache.shared.icon(forPath: place.url.path),
                                     kind: .folder, boost: 4, url: place.url) { show(place.url) })
        }
        return items
    }

    private static func workspaces() -> [PaletteItem] {
        Workspaces.shared.all.map { workspace in
            let image = NSImage(systemSymbolName: Workspaces.symbol(workspace), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
            return PaletteItem(title: workspace.name, subtitle: Workspaces.summary(workspace), icon: image, kind: .workspace,
                               keywords: workspace.tabs.joined().map { FileManager.default.displayName(atPath: $0) }, boost: 10) {
                NSApp.activate()
                Workspaces.shared.open(workspace)
            }
        }
    }

    private static func apps() -> [PaletteItem] {
        installedApps.map { url in
            PaletteItem(title: FileManager.default.displayName(atPath: url.path), subtitle: "", icon: IconCache.shared.icon(forPath: url.path),
                        kind: .app, boost: 6, url: url) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    /// Commands that make sense without a window in front: a window opens for those that need one.
    static func commands() -> [PaletteItem] {
        func command(_ definition: StrataCommand, keywords: [String] = [], _ run: @escaping () -> Void) -> PaletteItem {
            let image = definition.image?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
            return PaletteItem(title: definition.title, subtitle: "", icon: image, kind: .action,
                               shortcut: definition.shortcut, keywords: keywords, commandID: definition.id) {
                NSApp.activate()
                run()
            }
        }
        func send(_ command: StrataCommand) { NSApp.sendAction(command.action, to: nil, from: nil) }
        let delegate = NSApp.delegate as? AppDelegate
        return [
            command(.newWindow) { send(.newWindow) },
            command(.connectToServer, keywords: ["sftp", "s3", "smb"]) { delegate?.frontController().connectToServer(nil) },
            command(.goRecents) { delegate?.frontController().goRecents(nil) },
            command(.showSettings) { send(.showSettings) },
            command(.toggleShelf) { send(.toggleShelf) },
            command(.emptyTrash) { send(.emptyTrash) },
            command(.showShortcuts) { send(.showShortcuts) },
        ]
    }

    /// `github/acme`-style lookups among the folders you use and their insides, as ⌘K makes them.
    static func pathItems(_ query: String, _ pathQuery: PathQuery) -> [PaletteItem] {
        let services = BrowserServices.shared, places = services.places
        let visited = services.visits.ranked().filter { places.isFolder($0.path) != false }.prefix(400).map(\.self)
        let roots = (Places.favorites(preferences: services.preferences, checks: places) + places.snapshot.volumes).map(\.url)
            + [Places.home] + visited.prefix(100)
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        return pathQuery.resolve(query, roots: roots, visited: visited).map { hit in
            let url = hit.url
            return PaletteItem(title: url.lastPathComponent, subtitle: Format.tildePath(url.deletingLastPathComponent()),
                               icon: hit.isFolder ? folderIcon : IconCache.shared.icon(forPath: url.path),
                               kind: hit.isFolder ? .folder : .match, fixedScore: hit.score, titleMatches: hit.nameMatches, url: url) {
                show(url)
            }
        }
    }

    /// Files and folders from the index (plain English understood), documents whose text matches, and a row that opens
    /// the whole search in a window: on top when the words were read as plain English.
    static func lateItems(_ query: String) async -> [PaletteItem] {
        guard query.count >= 2, !query.hasPrefix("/"), !query.hasPrefix("~"),
              let found = await FileIndex.shared.understand(query, limit: 30), !Task.isCancelled else { return [] }
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        var items: [PaletteItem] = found.hits.filter { !($0.isPackage && $0.path.hasSuffix(".app")) }.map { hit in
            let entry = FileEntry(hit: hit)
            let isFolder = entry.isFolder
            let matches = Fuzzy.match(query.split(separator: " ").first.map(String.init) ?? query, entry.name)?.indices ?? []
            return PaletteItem(title: entry.name, subtitle: Format.tildePath(entry.url.deletingLastPathComponent()),
                               icon: isFolder ? folderIcon : IconCache.shared.icon(for: entry), kind: isFolder ? .folder : .match,
                               fixedScore: max(0, hit.score - 1000) / 2 + 8, titleMatches: matches, url: entry.url) {
                if isFolder { show(entry.url) } else { NSWorkspace.shared.open(entry.url) }
            }
        }
        // Documents whose text matches, as the window's search finds them: a plain-English reading's kinds, sizes and
        // dates must hold for them too.
        let plainNames = found.interpretation == nil && !IndexQuery.parse(query).hasFilters
        if let contentQuery = found.interpretation?.contentQuery ?? (plainNames ? query : nil), contentQuery.count >= 3 {
            var structural = found.interpretation
            structural?.nameContains = []
            structural?.keywords = []
            let known = Set(found.hits.map(\.path))
            // The costliest part (it reads meaning, not just names): not for words already typed over.
            guard !Task.isCancelled else { return [] }
            let hits = await StrataAI.index.search(contentQuery, limit: 8).filter { hit in
                !known.contains(hit.url.path) && (structural.map { filter in FileEntry(url: hit.url).map(filter.matches) ?? false } ?? true)
            }
            items += StrataAI.paletteItems(for: hits) { NSWorkspace.shared.open($0) }
        }
        let summary = found.interpretation?.summary
        let magnifier = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
        let count = String(localized: "\(found.total) results everywhere", comment: "plural")
        items.append(PaletteItem(title: String(localized: "Search for “\(query)”", comment: "The search box in the Dock: opens the search in a window"),
                                 subtitle: summary.map { "\($0) · \(count)" } ?? count, icon: magnifier, kind: .action,
                                 fixedScore: summary == nil ? 4 : 900) {
            NSApp.activate()
            (NSApp.delegate as? AppDelegate)?.frontController().search(query, in: nil)
        })
        return items
    }

    private static var cachedApps: (apps: [URL], until: Date)?

    /// Apps in Applications and the system's, read again at most once a minute.
    private static var installedApps: [URL] {
        if let cachedApps, Date() < cachedApps.until { return cachedApps.apps }
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"]
        let apps = roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: root).appending(path: $0) }
        }
        cachedApps = (apps, Date().addingTimeInterval(60))
        return apps
    }
}

// MARK: - Where the Dock draws the gap

/// The gap's place on screen, and the box shaped from the icon tile beside it.
struct DockLayout: Equatable {
    /// The spacer tiles, in screen coordinates.
    let gap: NSRect
    /// An app's tile next to them, in screen coordinates: icons sit in the upper part of a tile, the rest is room for
    /// the dot under a running app.
    let tile: NSRect

    /// Measured on macOS 26: an icon is three quarters of its tile's width, centred 56% of the way down the tile, with
    /// corners rounded to 22.5% of its side (continuous, like the icons).
    private var iconSide: CGFloat { tile.width * 0.74 }

    var boxFrame: NSRect {
        let side = iconSide
        let inset = (tile.width - side) / 2
        let centreY = tile.maxY - tile.height * 0.563
        return NSRect(x: gap.minX + inset, y: centreY - side / 2, width: gap.width - inset * 2, height: side).integral
    }

    var cornerRadius: CGFloat { iconSide * 0.225 }
}

/// Reads the Dock through Accessibility: which of its items are Strata's spacer tiles, and where they are now. The
/// list of items (and which of them are the gap) is read again every second or so; their frames every time, so the box
/// keeps up with the Dock sliding in, magnifying or moving to another display.
final class DockReader {
    private var pid: pid_t = 0
    private var list: AXUIElement?
    private var items: [AXUIElement] = []
    /// Positions in `items`: the gap, and an app tile beside it to take the icon size from.
    private var gapItems: Range<Int>?
    private var tileItem: Int?
    private var refreshed = Date.distantPast

    /// Nil when the gap isn't on screen: no Accessibility access, no gap in the Dock, the Dock hidden, or on the left or
    /// right (a text box doesn't fit a column of icons).
    func layout(anchor bundleID: String) -> DockLayout? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        // A Dock started again (Strata changed its tiles, or it crashed) has new items; so does one rearranged.
        if dock.processIdentifier != pid || Date().timeIntervalSince(refreshed) > 1 {
            refresh(dock.processIdentifier, anchor: bundleID)
        }
        guard let list, let listFrame = Self.frame(of: list), listFrame.width > listFrame.height,
              let gapItems, let tileItem,
              let first = Self.frame(of: items[gapItems.lowerBound]), let last = Self.frame(of: items[gapItems.upperBound - 1]),
              let tile = Self.frame(of: items[tileItem]), let primary = NSScreen.screens.first else { return nil }
        // Accessibility measures down from the top of the main screen, AppKit up from its bottom.
        func flipped(_ rect: CGRect) -> NSRect {
            NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        let gap = flipped(first.union(last))
        // A hidden Dock keeps its tiles just off the edge of the screen.
        guard NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: gap.midX, y: gap.midY)) }) else { return nil }
        return DockLayout(gap: gap, tile: flipped(tile))
    }

    private func refresh(_ dockPID: pid_t, anchor bundleID: String) {
        refreshed = Date()
        if dockPID != pid {
            pid = dockPID
            let app = AXUIElementCreateApplication(dockPID)
            list = (Self.attribute(app, kAXChildrenAttribute) as? [AXUIElement])?
                .first { Self.attribute($0, kAXRoleAttribute) as? String == "AXList" }
        }
        items = list.flatMap { Self.attribute($0, kAXChildrenAttribute) as? [AXUIElement] } ?? []
        // If the Dock just started again, its list isn't there yet: look again next time.
        if items.isEmpty { pid = 0 }
        let subroles = items.map { Self.attribute($0, kAXSubroleAttribute) as? String }
        let isSpacer = { (index: Int) in subroles[index] == "AXSpacerDockItem" }
        let isApp = { (index: Int) in subroles[index] == "AXApplicationDockItem" }
        gapItems = nil
        // The Dock lists Finder, then its kept apps in the order of its settings: Strata's tiles are found by their
        // place there, wherever they've been dragged.
        if let run = DockGapTiles.run(in: DockGapTiles.read() ?? []),
           run.upperBound + 1 <= items.count, (run.lowerBound + 1..<run.upperBound + 1).allSatisfy(isSpacer) {
            gapItems = run.lowerBound + 1..<run.upperBound + 1
        } else if let anchor = items.firstIndex(where: { Self.bundleID(of: $0) == bundleID }) ?? (items.isEmpty ? nil : 0) {
            // Not settled yet (the Dock still starting, or its settings not written yet): the spacers after Strata's
            // tile, where they were put.
            let run = (anchor + 1..<items.count).prefix { isSpacer($0) }
            if let lower = run.first, let upper = run.last { gapItems = lower..<upper + 1 }
        }
        tileItem = gapItems.flatMap { gap in
            [gap.lowerBound - 1, gap.upperBound].first { items.indices.contains($0) && isApp($0) }
                ?? items.indices.first(where: isApp)
        }
    }

    private static func bundleID(of item: AXUIElement) -> String? {
        (attribute(item, kAXURLAttribute) as? URL).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        frame(position: attribute(element, kAXPositionAttribute), size: attribute(element, kAXSizeAttribute))
    }

    static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        // Check both the CF object type and the structure stored inside it before using Dock geometry.
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              origin.x.isFinite, origin.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0,
              (origin.x + extent.width).isFinite, (origin.y + extent.height).isFinite else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

// MARK: - The spacer tiles

/// The empty tiles the box sits on, kept in the Dock's own settings. The Dock keeps nothing on a spacer but its kind
/// (no id, no label: it rewrites them), so Strata's gap is told apart by its shape: a half-width spacer, three full
/// ones and another half (four icons wide), a run you'd hardly make by hand. Found wherever it's been dragged; only it
/// is ever taken out.
nonisolated enum DockGapTiles {
    static let shape = ["small-spacer-tile", "spacer-tile", "spacer-tile", "spacer-tile", "small-spacer-tile"]
    private static var domain: CFString { "com.apple.dock" as CFString }
    private static var key: CFString { "persistent-apps" as CFString }

    static func isSpacer(_ tile: [String: Any]) -> Bool {
        ["spacer-tile", "small-spacer-tile"].contains(tile["tile-type"] as? String)
    }

    /// Where Strata's gap is in `apps`: a run of spacers in exactly `shape` (spacers of your own beside it would make it
    /// some other run). Nil when there's none.
    static func run(in apps: [[String: Any]]) -> Range<Int>? {
        var index = 0
        while index < apps.count {
            guard isSpacer(apps[index]) else { index += 1; continue }
            let run = apps[index...].prefix(while: isSpacer)
            if run.map({ $0["tile-type"] as? String ?? "" }) == shape { return index..<index + run.count }
            index += run.count
        }
        return nil
    }

    /// `apps` with Strata's gap, unless it's already somewhere: right after the tile of `bundleID` (at the front when
    /// Strata isn't kept in the Dock). It never touches a spacer of yours, which would make one longer run that isn't
    /// Strata's shape: then it goes right before Strata, or else wherever nearest that has no spacer on either side.
    static func adding(to apps: [[String: Any]], after bundleID: String) -> [[String: Any]] {
        guard run(in: apps) == nil else { return apps }
        let anchor = apps.firstIndex { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String == bundleID }
        let clear = { (position: Int) in
            (position == 0 || !isSpacer(apps[position - 1])) && (position == apps.count || !isSpacer(apps[position]))
        }
        let preferred = anchor.map { [$0 + 1, $0] } ?? [0]
        guard let position = preferred.first(where: clear)
                ?? (0...apps.count).filter(clear).min(by: { abs($0 - preferred[0]) < abs($1 - preferred[0]) }) else { return apps }
        var changed = apps
        changed.insert(contentsOf: shape.map { ["tile-type": $0, "tile-data": [String: Any]()] as [String: Any] }, at: position)
        return changed
    }

    /// `apps` without Strata's gap (spacers of your own stay).
    static func removing(from apps: [[String: Any]]) -> [[String: Any]] {
        var changed = apps
        while let run = run(in: changed) { changed.removeSubrange(run) }
        return changed
    }

    /// The Dock's kept apps, read afresh (it rewrites them when you drag a tile).
    static func read() -> [[String: Any]]? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [[String: Any]]
    }

    static func write(_ apps: [[String: Any]]) {
        CFPreferencesSetAppValue(key, apps as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// The Dock reads its tiles when it starts; macOS starts it again at once.
    static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
