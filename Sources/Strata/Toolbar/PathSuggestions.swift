import AppKit

/// A folder the path bar offers while you type.
nonisolated struct PathSuggestion: Equatable, Sendable {
    let url: URL
    let score: Int
    /// Matched character offsets in the folder's name, for highlighting.
    let matches: [Int]
}

/// What the path bar suggests for what's typed: a path (`~/Doc`, `/Volumes/…`) lists the folders inside as you type; a
/// relative one walks down from where you are and from folders you use (`github/acme`); a name alone finds folders with
/// that name anywhere, from the index, those you open most first.
final class PathSuggestions {
    private let visits: Frecency
    private let preferences: Prefs
    private let places: PlaceChecks

    init(visits: Frecency, preferences: Prefs, places: PlaceChecks) {
        self.visits = visits
        self.preferences = preferences
        self.places = places
    }

    static let limit = 12
    /// Folders you use and where `github/acme`-style lookups start, read once per editing (`begin`).
    private var visited: [URL] = []
    private var roots: [URL] = []
    /// Folders already read this editing: their subfolders.
    private var listings: [String: [URL]] = [:]

    /// Typing starts: what the lookups use, taken now rather than on every key. Roots that would ask for access
    /// (Desktop, Documents… without Full Disk Access) or live on another machine are left out.
    func begin(at current: URL?) {
        listings.removeAll()
        places.refresh()
        visited = visits.ranked().filter { places.isFolder($0.path) != false }.prefix(400).map(\.self)
        let here = current ?? Places.home
        let candidates = Places.favorites(preferences: preferences, checks: places).map(\.url)
            + places.snapshot.volumes.filter { $0.symbol != "network" }.map(\.url) + [Places.home] + visited.prefix(100)
        roots = candidates.filter { !Privacy.measuringWouldPrompt($0, browsing: here) }
    }

    func suggestions(for text: String, in current: URL?) async -> [PathSuggestion] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        if visited.isEmpty, roots.isEmpty { begin(at: current) }
        if typed.hasPrefix("/") || typed.hasPrefix("~") {
            let path = (typed as NSString).expandingTildeInPath
            return await inside(path, keepTrailingSlash: typed.hasSuffix("/"))
        }
        var found: [String: PathSuggestion] = [:]
        func keep(_ suggestion: PathSuggestion) {
            let key = suggestion.url.standardizedFileURL.path
            if found[key].map({ $0.score < suggestion.score }) ?? true { found[key] = suggestion }
        }
        if typed.contains("/") {
            // Relative to this folder first, then `github/acme`-style lookups.
            if let current {
                for hit in await inside(current.appending(path: typed).path, keepTrailingSlash: typed.hasSuffix("/")) {
                    keep(PathSuggestion(url: hit.url, score: hit.score + 40, matches: hit.matches))
                }
            }
            // Walking folders reads the disk: off the main thread, with a fresh cache each time.
            let roots = roots, visited = visited
            let hits = await Self.offMain { PathQuery().resolve(typed, roots: roots, visited: visited) }
            for hit in hits where hit.isFolder {
                keep(PathSuggestion(url: hit.url, score: hit.score, matches: hit.nameMatches))
            }
        } else {
            // A name: folders here, folders you use, then any folder on disk by that name.
            if let current {
                for hit in await inside(current.path + "/" + typed, keepTrailingSlash: false) {
                    keep(PathSuggestion(url: hit.url, score: hit.score + 30, matches: hit.matches))
                }
            }
            for (rank, url) in visited.enumerated() {
                guard let match = Fuzzy.match(typed, url.lastPathComponent) else { continue }
                keep(PathSuggestion(url: url, score: match.score + max(0, 24 - rank / 2) + 10, matches: match.indices))
            }
            if typed.count >= 2, let result = await FileIndex.shared.search("kind:folder " + typed, limit: 30) {
                for hit in result.hits where !hit.isPackage {
                    let url = URL(fileURLWithPath: hit.path, isDirectory: true)
                    let matches = Fuzzy.match(typed, url.lastPathComponent)?.indices ?? []
                    keep(PathSuggestion(url: url, score: max(0, hit.score - 1000) / 2 + 8, matches: matches))
                }
            }
        }
        return Array(found.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }.prefix(Self.limit))
    }

    /// The folders in `path`'s parent whose names match its last part (all of them after a trailing `/`), names starting
    /// with what's typed first. Read off the main thread: a folder on a slow disk or server mustn't stall typing.
    /// The folders in `path`'s parent whose names match its last part (all of them after a trailing `/`), names starting
    /// with what's typed first. Each folder is read once per editing, off the main thread: typing on in a big folder (or
    /// one on a slow disk or server) doesn't read it again for every key.
    private func inside(_ path: String, keepTrailingSlash: Bool) async -> [PathSuggestion] {
        let directory = keepTrailingSlash ? path : (path as NSString).deletingLastPathComponent
        let prefix = keepTrailingSlash ? "" : (path as NSString).lastPathComponent
        let showHidden = preferences.showHidden || prefix.hasPrefix(".")
        let key = directory + (showHidden ? "\u{0}hidden" : "")
        let folders: [URL]
        if let cached = listings[key] {
            folders = cached
        } else {
            folders = await Self.offMain { Self.subfolders(of: directory, showHidden: showHidden) }
            listings[key] = folders
        }
        var hits: [PathSuggestion] = []
        for url in folders {
            let name = url.lastPathComponent
            if prefix.isEmpty {
                hits.append(PathSuggestion(url: url, score: 0, matches: []))
            } else if let match = Fuzzy.match(prefix, name) {
                // Names that start with what's typed come first, as completion would have them.
                let starts = name.lowercased().hasPrefix(prefix.lowercased())
                hits.append(PathSuggestion(url: url, score: match.score + (starts ? 40 : 0), matches: match.indices))
            }
        }
        return Array(hits.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }.prefix(40))
    }

    nonisolated private static func subfolders(of directory: String, showHidden: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: keys,
                                                                      options: showHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        return urls.prefix(5000).filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isPackage != true
        }
    }

    private static let reads = DispatchQueue(label: "dev.strata.path-suggestions", qos: .userInitiated)

    /// Runs `work` (file system reads) on a queue of its own, never on the main thread or Swift's shared threads.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            reads.async { continuation.resume(returning: work()) }
        }
    }
}

/// The list under the path bar while you edit it: a glass panel, one line per folder (its name, then where it is).
/// It never takes focus; the path bar's field keeps it and drives the selection.
final class PathSuggestionList: NSObject {
    private let panel = SuggestionPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    private let table = SuggestionTable()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    private(set) var items: [PathSuggestion] = []
    /// The text these suggestions are for (typing since makes them stale).
    private(set) var forText: String?
    /// Set once ↑ or ↓ picks a row: Return then goes there rather than to what's typed.
    private(set) var hasChosen = false
    var onPick: ((PathSuggestion) -> Void)?

    private static let rowHeight: CGFloat = 30
    private static let maxVisibleRows = 9
    private static let footerHeight: CGFloat = 26

    override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        build()
    }

    var isVisible: Bool { panel.isVisible }

    var selected: PathSuggestion? {
        items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
    }

    private func build() {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        let content = NSView()

        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel(String(localized: "Folder suggestions"))

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 5, left: 0, bottom: 0, right: 0)
        scroll.documentView = table

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .tertiaryLabelColor
        footer.stringValue = String(localized: "↑↓ Choose   ↩ Go   ⇥ Complete   esc Close",
                                    comment: "Key hints under the path bar's folder suggestions; keep the symbols")

        content.addSubview(scroll)
        content.addSubview(footer)
        heightConstraint = content.heightAnchor.constraint(equalToConstant: 200)
        widthConstraint = content.widthAnchor.constraint(equalToConstant: 480)
        NSLayoutConstraint.activate([
            heightConstraint, widthConstraint,
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.footerHeight),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            footer.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.footerHeight / 2),
        ])
        glass.contentView = content
        panel.contentView = glass
    }

    /// Typing again: what was picked with the arrows no longer counts.
    func resetChoice() {
        hasChosen = false
    }

    /// Shows `items` (for `text`) under `anchor` (the path bar), as wide as it is. The first row is highlighted when
    /// Return would go to it (`highlightFirst`: what's typed isn't a folder that's there).
    func show(_ items: [PathSuggestion], for text: String, highlightFirst: Bool, below anchor: NSView) {
        guard let window = anchor.window, !items.isEmpty else { return close() }
        self.items = items
        forText = text
        hasChosen = false
        table.reloadData()
        if highlightFirst {
            table.selectRowIndexes([0], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        table.scrollRowToVisible(0)

        let rows = CGFloat(min(items.count, Self.maxVisibleRows))
        let height = rows * Self.rowHeight + 5 + Self.footerHeight
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = max(anchorFrame.width, 420)
        heightConstraint.constant = height
        widthConstraint.constant = width
        var frame = NSRect(x: anchorFrame.minX, y: anchorFrame.minY - 6 - height, width: width, height: height)
        // Kept on the screen (a window near its right edge).
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - frame.width))
        }
        panel.setFrame(frame, display: true)
        if !panel.isVisible || panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    func close() {
        items = []
        forText = nil
        hasChosen = false
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// ↑ / ↓: picks a row (the first ↓ the top one), and VoiceOver says which.
    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = hasChosen ? max(0, min(items.count - 1, table.selectedRow + delta)) : (delta > 0 ? 0 : items.count - 1)
        hasChosen = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        NSAccessibility.post(element: table, notification: .announcementRequested,
                             userInfo: [.announcement: Format.tildePath(items[row].url), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func rowClicked() {
        guard items.indices.contains(table.clickedRow) else { return }
        onPick?(items[table.clickedRow])
    }
}

extension PathSuggestionList: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("SuggestionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SuggestionCell ?? {
            let cell = SuggestionCell()
            cell.identifier = id
            return cell
        }()
        cell.configure(items[row])
        cell.isRowSelected = row == tableView.selectedRow
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = table.selectedRow
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? SuggestionCell)?.isRowSelected = row == selected
        }
    }
}

/// Never key: typing stays in the path bar.
private final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click though its panel isn't key.
private final class SuggestionTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class SuggestionCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let location = NSTextField(labelWithString: "")
    private var suggestion: PathSuggestion?
    var isRowSelected = false {
        didSet { if isRowSelected != oldValue { render() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, name, location] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingTail
        location.lineBreakMode = .byTruncatingHead
        location.font = .systemFont(ofSize: 11)
        location.alignment = .right
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            location.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 14),
            location.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            location.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ suggestion: PathSuggestion) {
        self.suggestion = suggestion
        icon.image = IconCache.shared.icon(forPath: suggestion.url.path)
        location.stringValue = Format.tildePath(suggestion.url.deletingLastPathComponent())
        setAccessibilityLabel(Format.tildePath(suggestion.url))
        render()
    }

    private func render() {
        guard let suggestion else { return }
        let title = Places.displayName(suggestion.url)
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        // Highlights only apply to the name as it's spelled on disk.
        if title == suggestion.url.lastPathComponent {
            let characters = Array(title)
            var offsets: [Int] = []
            var offset = 0
            for c in characters {
                offsets.append(offset)
                offset += c.utf16.count
            }
            for i in suggestion.matches where i < characters.count {
                text.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                    .foregroundColor: isRowSelected ? NSColor.labelColor : NSColor.controlAccentColor],
                                   range: NSRange(location: offsets[i], length: characters[i].utf16.count))
            }
        }
        name.attributedStringValue = text
        location.textColor = .secondaryLabelColor
    }
}
