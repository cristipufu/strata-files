import AppKit

/// The address bar. Shows the location as clickable breadcrumbs; click empty space or press ⌘L to type a path, with
/// Tab completion and a list of matching folders (or folders with the typed name anywhere). The chevrons between
/// crumbs list that folder's subfolders for sideways jumps.
final class PathBar: NSView, NSTextFieldDelegate {
    /// Folder to show, plus an item inside it to select (when a file path was typed).
    var onNavigate: ((URL, URL?) -> Void)?
    var onFinishEditing: (() -> Void)?
    var onActivate: (() -> Void)?

    var url: URL? {
        didSet {
            title = nil
            if !isEditing { rebuild() }
        }
    }

    /// A title shown instead of breadcrumbs (Search, Recents…), kept across editing.
    private var title: (text: String, symbol: String)?
    var isShowingTitle: Bool { title != nil }

    /// Root of the git work tree being shown, if any; the branch pill follows its crumb.
    var gitRoot: URL? {
        didSet { if gitRoot?.path != oldValue?.path, !isEditing, url != nil { rebuild() } }
    }

    /// Set its `model` from the git status; hidden while the model is nil.
    let branchPill: GitBranchPill

    private let crumbs = PathBreadcrumbs()
    private let field = NSTextField()
    private(set) var isEditing = false
    private let suggestions: PathSuggestions
    private let suggestionList: PathSuggestionList
    /// The field's lookup in progress: suggestions, or what Return or Tab finds on disk.
    private(set) var suggesting: Task<Void, Never>?
    private let copies: CopyProviders
    private let names: FolderNames
    private let embedded: Bool
    // Breadcrumbs must yield when AppKit measures the toolbar's minimum size.
    private static let toolbarSizingPriority = NSLayoutConstraint.Priority(
        rawValue: NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)

    var editorField: NSTextField { field }

    var crumbButtons: [CrumbButton] { crumbs.buttons }

    init(frame: NSRect = .zero, preferences: Prefs, places: PlaceChecks, index: FileIndex, copies: CopyProviders,
         names: FolderNames, clipboard: Clipboard, embedded: Bool = false) {
        branchPill = GitBranchPill(clipboard: clipboard)
        self.copies = copies
        self.names = names
        self.embedded = embedded
        suggestionList = PathSuggestionList(copies: copies, names: names)
        suggestions = PathSuggestions(preferences: preferences, places: places, index: index)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(namesRead(_:)), name: .folderNamesRead,
                                               object: names)

        setUpCrumbs()
        setUpField()
        suggestionList.onPick = { [weak self] suggestion in self?.go(to: suggestion) }
        layOut()
    }

    private func setUpCrumbs() {
        crumbs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(crumbs)
    }

    private func setUpField() {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = String(localized: "Go to folder…", comment: "Placeholder of the path bar while typing a path")
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.isHidden = true
        addSubview(field)
    }

    /// Embedded in a pane, the bar gives way to what's beside it; in the toolbar, it wishes for a width it gives up
    /// before other items overflow.
    private func layOut() {
        var constraints = [
            crumbs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            crumbs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            crumbs.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if embedded {
            setContentCompressionResistancePriority(.init(199), for: .horizontal)
            setContentHuggingPriority(.init(199), for: .horizontal)
            field.setContentCompressionResistancePriority(.init(199), for: .horizontal)
        } else {
            // A wish, weaker than the toolbar's own sizing: the bar gives up width before other items overflow.
            let preferred = widthAnchor.constraint(equalToConstant: 520)
            preferred.priority = Self.toolbarSizingPriority
            toolbarSizing = [
                heightAnchor.constraint(equalToConstant: 32),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
                widthAnchor.constraint(lessThanOrEqualToConstant: 720),
                preferred,
            ]
            constraints += toolbarSizing
        }
        NSLayoutConstraint.activate(constraints)
    }

    private var toolbarSizing: [NSLayoutConstraint] = []
    private lazy var rowSizing = [heightAnchor.constraint(equalToConstant: 28)]
    private var toolbarPriorities: (compression: NSLayoutConstraint.Priority, hugging: NSLayoutConstraint.Priority,
                                    field: NSLayoutConstraint.Priority)?

    /// The window's bar sits in the toolbar or, with Tabs above the address bar, in the address row, where it takes
    /// the width the row leaves it instead of wishing for the toolbar's.
    var isInAddressRow = false {
        didSet {
            guard !embedded, isInAddressRow != oldValue else { return }
            if isInAddressRow {
                toolbarPriorities = (contentCompressionResistancePriority(for: .horizontal), contentHuggingPriority(for: .horizontal),
                                     field.contentCompressionResistancePriority(for: .horizontal))
                NSLayoutConstraint.deactivate(toolbarSizing)
                NSLayoutConstraint.activate(rowSizing)
                setContentCompressionResistancePriority(.init(199), for: .horizontal)
                setContentHuggingPriority(.init(199), for: .horizontal)
                field.setContentCompressionResistancePriority(.init(199), for: .horizontal)
            } else if let toolbarPriorities {
                NSLayoutConstraint.deactivate(rowSizing)
                NSLayoutConstraint.activate(toolbarSizing)
                setContentCompressionResistancePriority(toolbarPriorities.compression, for: .horizontal)
                setContentHuggingPriority(toolbarPriorities.hugging, for: .horizontal)
                field.setContentCompressionResistancePriority(toolbarPriorities.field, for: .horizontal)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        beginEditing()
    }

    /// Shows a single non-navigating crumb, for places that aren't folders (Search, Recents).
    func showTitle(_ title: String, symbol: String) {
        if isEditing { endEditing(restoreFocus: false) }
        if self.title?.text == title, self.title?.symbol == symbol, !crumbs.buttons.isEmpty { return }
        self.title = (title, symbol)
        let crumb = CrumbButton(title: title, symbol: symbol, emphasized: true)
        crumb.target = self
        crumb.action = #selector(titleCrumbClicked)
        crumb.isEnabled = true
        crumbs.show([PathBreadcrumbs.Step(button: crumb)])
    }

    @objc private func titleCrumbClicked() {
        onActivate?()
    }

    // MARK: - Breadcrumbs

    private func rebuild() {
        if let currentTitle = title {
            title = nil
            showTitle(currentTitle.text, symbol: currentTitle.symbol)
            return
        }
        guard let url else { crumbs.show([]); return }
        let parts = Self.components(of: url, copies: copies, names: names)
        let repoRootPath = gitRoot?.lexicallyStandardized.path
        var steps: [PathBreadcrumbs.Step] = []
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let crumb = CrumbButton(title: part.title, symbol: part.symbol, emphasized: isLast)
            crumb.toolTip = Format.tildePath(part.url)
            crumb.target = self
            crumb.action = #selector(crumbClicked(_:))
            crumb.destination = part.url
            var step = PathBreadcrumbs.Step(button: crumb)
            let isRepoRoot = part.url.lexicallyStandardized.path == repoRootPath
            if isRepoRoot {
                step.branch = branchPill
            }
            if !isLast {
                let name = part.title.isEmpty ? part.url.lastPathComponent : part.title
                let chevron = ChevronButton(folder: part.url, name: name) { [weak self] target in
                    self?.onActivate?()
                    self?.onNavigate?(target, nil)
                }
                step.chevron = chevron
            }
            steps.append(step)
        }
        crumbs.show(steps)
    }

    /// Finder's names arrived for folders along the path: the crumbs show them.
    @objc private func namesRead(_ notification: Notification) {
        guard !isEditing, title == nil, let path = url?.path,
              let paths = notification.userInfo?["paths"] as? Set<String>,
              paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        rebuild()
    }

    @objc private func crumbClicked(_ sender: CrumbButton) {
        onActivate?()
        guard let destination = sender.destination else { return }
        onNavigate?(destination, nil)
    }

    /// One step of the path bar: its title, where it leads, and its symbol, if any.
    private typealias Crumb = (title: String, url: URL, symbol: String?)

    private static func components(of url: URL, depth: Int = 0, copies: CopyProviders, names: FolderNames) -> [Crumb] {
        // Containers, then a container, then its folders from `/`.
        if let folder = copies.containerCopies.containersFolder(of: url) {
            return [(String(localized: "Containers", comment: "Sidebar section title: Docker containers"), folder, "shippingbox")]
                + steps(of: url, below: folder)
        }
        // On a server: the server, then its folders from `/`.
        if let (server, top) = copies.remoteCopies.server(containing: url) {
            return [(server.name, top, server.kind == .s3 ? "externaldrive.connected.to.line.below" : "server.rack")]
                + steps(of: url, below: top)
        }
        // Inside an archive opened as a folder: the archive's own location, the archive, then the folders inside it
        // (an archive opened from inside another one nests, a few levels at most).
        if depth < 8, let (archive, top) = ArchiveCache.archive(containing: url) {
            return components(of: archive.deletingLastPathComponent(), depth: depth + 1, copies: copies, names: names)
                + [(archive.lastPathComponent, top, "archivebox")] + steps(of: url, below: top)
        }
        return localComponents(of: url, copies: copies, names: names)
    }

    /// Each folder from `top` (not included) down to `url`, by its own name.
    private static func steps(of url: URL, below top: URL) -> [Crumb] {
        var parts: [Crumb] = []
        var current = top
        let inner = url.lexicallyStandardized.path.dropFirst(top.lexicallyStandardized.path.count).split(separator: "/")
        for component in inner {
            current = current.appending(path: String(component))
            parts.append((String(component), current, nil))
        }
        return parts
    }

    /// Your home folder, another disk or the startup disk, then each folder by the name it's shown with; a Trash as
    /// one "Trash" step.
    private static func localComponents(of url: URL, copies: CopyProviders, names: FolderNames) -> [Crumb] {
        let path = url.lexicallyStandardized.path
        let home = Places.home.lexicallyStandardized.path
        var parts: [Crumb] = []
        let root: String
        if path == home || path.hasPrefix(home + "/") {
            root = home
            // Icon only, unless home is the folder being shown.
            let homeURL = URL(filePath: home, directoryHint: .isDirectory)
            parts.append((path == home ? names.name(homeURL) : "", homeURL, "house.fill"))
        } else if path.hasPrefix("/Volumes/"), let name = path.split(separator: "/").dropFirst().first {
            root = "/Volumes/\(name)"
            parts.append((String(name), URL(filePath: root, directoryHint: .isDirectory), "externaldrive.fill"))
        } else {
            root = "/"
            let startup = URL(filePath: "/", directoryHint: .isDirectory), name = names.name(startup)
            parts.append((name == startup.lastPathComponent ? "Macintosh HD" : name, startup, "internaldrive.fill"))
        }
        // Each step's URL is spelled with what's known, never asking the disk.
        var current = URL(filePath: root, directoryHint: .isDirectory)
        for component in path.dropFirst(root.count).split(separator: "/") {
            current = current.appending(path: String(component))
            // Another disk's Trash is `.Trashes/<uid>`: shown as one "Trash" step.
            if component == ".Trashes", Trash.isTrash(current.appending(path: String(getuid()))) { continue }
            if Trash.isTrash(current) {
                parts.append((String(localized: "Trash", comment: "Path bar: a Trash folder"), current, "trash"))
            } else {
                parts.append((Places.displayName(current, copies: copies, names: names), current, nil))
            }
        }
        return parts
    }

    // MARK: - Editing

    func beginEditing() {
        guard url != nil, !isEditing else { return }
        onActivate?()
        guard let url, !isEditing else { return }
        isEditing = true
        alphaValue = 1
        suggestions.begin(at: url)
        if let window {
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowMoved), name: name, object: window)
            }
        }
        crumbs.isHidden = true
        field.isHidden = false
        var text = Format.tildePath(url)
        if !text.hasSuffix("/") { text += "/" }
        field.stringValue = text
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func cancelEditing() {
        if isEditing {
            endEditing(restoreFocus: false)
        } else {
            closeSuggestions()
        }
    }

    private func endEditing(restoreFocus: Bool) {
        guard isEditing else { return }
        isEditing = false
        closeSuggestions()
        if let window {
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: window)
            }
        }
        field.isHidden = true
        crumbs.isHidden = false
        rebuild()
        if restoreFocus { onFinishEditing?() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endEditing(restoreFocus: false)
    }

    func controlTextDidChange(_ notification: Notification) {
        suggestionList.resetChoice()
        updateSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // The list closes first; a second Esc stops editing.
            if suggestionList.isVisible {
                closeSuggestions()
            } else {
                endEditing(restoreFocus: true)
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            if suggestionList.hasChosen, let chosen = suggestionList.selected {
                complete(to: chosen.url)
            } else {
                complete()
            }
            return true
        case #selector(NSResponder.moveDown(_:)) where suggestionList.isVisible:
            suggestionList.move(1)
            return true
        case #selector(NSResponder.moveUp(_:)) where suggestionList.isVisible:
            suggestionList.move(-1)
            return true
        default:
            return false
        }
    }

    // MARK: - Suggestions

    /// Looks again a moment after typing stops; what was being looked up for older text is dropped.
    private func updateSuggestions() {
        suggesting?.cancel()
        let text = field.stringValue
        let current = url
        suggesting = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, !Task.isCancelled else { return }
            let found = await suggestions.suggestions(for: text, in: current)
            guard !Task.isCancelled, isEditing, field.stringValue == text else { return }
            // Nothing to add when the only suggestion is the folder already typed.
            let typed = resolvedPath()
            if found.count == 1, found[0].url.lexicallyStandardized.path == URL(filePath: typed, directoryHint: .inferFromPath).lexicallyStandardized.path {
                return closeSuggestions()
            }
            let typedIsThere = await FileEntry.opening(URL(filePath: typed, directoryHint: .inferFromPath)) != .missing
            guard !Task.isCancelled, isEditing, field.stringValue == text else { return }
            suggestionList.show(found, for: text, highlightFirst: !typedIsThere, below: self)
        }
    }

    /// The list doesn't follow a window being moved or resized: it closes (typing brings it back).
    @objc private func windowMoved() {
        suggestionList.close()
    }

    private func closeSuggestions() {
        suggesting?.cancel()
        suggesting = nil
        suggestionList.close()
    }

    private func go(to suggestion: PathSuggestion) {
        endEditing(restoreFocus: true)
        onNavigate?(suggestion.url.lexicallyStandardized, nil)
    }

    /// Tab on a chosen suggestion: its path goes in the field, to keep typing inside it.
    private func complete(to folder: URL) {
        field.stringValue = Format.tildePath(folder) + "/"
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        updateSuggestions()
    }

    private func resolvedPath() -> String {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let expanded = (text as NSString).expandingTildeInPath
        guard let url, !expanded.hasPrefix("/") else { return expanded }
        return url.appending(path: expanded).path
    }

    /// Return: a suggestion picked with the arrows, else what's typed if it's there, else the best suggestion for what's
    /// typed now (looked up first if the list is for older text).
    private func commit() {
        if suggestionList.hasChosen, let chosen = suggestionList.selected { return go(to: chosen) }
        let path = resolvedPath(), text = field.stringValue, current = url
        suggesting?.cancel()
        suggesting = Task { [weak self] in
            let (opening, located) = await FileEntry.locate(URL(filePath: path, directoryHint: .inferFromPath))
            guard let self, !Task.isCancelled, isEditing, field.stringValue == text else { return }
            guard opening != .missing else {
                if suggestionList.forText == text, let best = suggestionList.items.first { return go(to: best) }
                let found = await suggestions.suggestions(for: text, in: current)
                guard !Task.isCancelled, isEditing, field.stringValue == text else { return }
                if let best = found.first { go(to: best) } else { shake() }
                return
            }
            let target = URL(filePath: located.path, directoryHint: opening == .folder ? .isDirectory : .notDirectory)
            endEditing(restoreFocus: true)
            if opening == .folder {
                onNavigate?(target, nil)
            } else {
                onNavigate?(target.deletingLastPathComponent(), target)
            }
        }
    }

    /// Completes the last path component against the folders on disk, as far as it's unambiguous.
    private func complete() {
        let path = resolvedPath(), text = field.stringValue
        let directory = path.hasSuffix("/") ? path : (path as NSString).deletingLastPathComponent
        let prefix = path.hasSuffix("/") ? "" : (path as NSString).lastPathComponent
        suggesting?.cancel()
        suggesting = Task { [weak self] in
            let matches = await Self.folders(in: directory, startingWith: prefix)
            guard let self, !Task.isCancelled, isEditing, field.stringValue == text else { return }
            guard let matches else { return shake() }
            complete(prefix, in: directory, from: matches)
        }
    }

    /// The folders in `directory` whose names start with `prefix` (any case; hidden ones only for a hidden prefix), in
    /// Finder's order; nil when `directory` can't be read.
    nonisolated static func folders(in directory: String, startingWith prefix: String) async -> [String]? {
        await OwnThread.run {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
            return names.filter { name in
                guard name.lowercased().hasPrefix(prefix.lowercased()), !name.hasPrefix(".") || prefix.hasPrefix(".") else { return false }
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name), isDirectory: &isDir) && isDir.boolValue
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    /// Completes `prefix` as far as `matches` (the folders of `directory` starting with it) agree.
    private func complete(_ prefix: String, in directory: String, from matches: [String]) {
        guard let first = matches.first else {
            Sounds.beep()
            return
        }
        let completed: String
        if matches.count == 1 {
            completed = first + "/"
        } else {
            var end = first.startIndex
            while end < first.endIndex {
                let next = first.index(after: end)
                let candidateLower = first[..<next].lowercased()
                if matches.dropFirst().allSatisfy({ $0.lowercased().hasPrefix(candidateLower) }) {
                    end = next
                } else {
                    break
                }
            }
            completed = String(first[..<end])
            if completed.count == prefix.count { Sounds.beep() }
        }
        let newPath = (directory as NSString).appendingPathComponent(completed)
        field.stringValue = (newPath as NSString).abbreviatingWithTildeInPath + (matches.count == 1 ? "/" : "")
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        updateSuggestions()
    }

    private func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -9, 9, -6, 6, -3, 3, 0]
        animation.duration = 0.4
        layer?.add(animation, forKey: "shake")
        Sounds.beep()
    }
}

/// A breadcrumb segment with a soft hover highlight.
final class CrumbButton: NSButton {
    var destination: URL?
    private var tracking: NSTrackingArea?

    init(title: String, symbol: String?, emphasized: Bool) {
        super.init(frame: .zero)
        cell = CrumbButtonCell(textCell: "")
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular),
            .foregroundColor: emphasized ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? String(localized: "Home", comment: "Accessibility: the home folder crumb") : title)
            symbolConfiguration = .init(pointSize: 12, weight: .medium)
            contentTintColor = .secondaryLabelColor
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            imageHugsTitle = true
        }
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = 24
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHighlight(true) }
    override func mouseExited(with event: NSEvent) { setHighlight(false) }

    override func viewDidHide() {
        setHighlight(false)
        super.viewDidHide()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { setHighlight(false) }
        super.viewWillMove(toWindow: newWindow)
    }

    fileprivate func setHighlight(_ on: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil
        }
    }
}

private final class CrumbButtonCell: NSButtonCell {
    private var horizontalInset: CGFloat { title.isEmpty ? 7 : 8 }

    // AppKit includes these drawing insets when measuring the title and image together.
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let content = super.drawingRect(forBounds: rect)
        let inset = min(horizontalInset, max(0, content.width / 2))
        return content.insetBy(dx: inset, dy: 0)
    }

    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        let point = controlView.convert(event.locationInWindow, from: nil)
        guard isEnabled, cellFrame.contains(point) else { return [] }
        return [.contentArea, .trackableArea]
    }
}

/// The separator between crumbs; click it to jump to a sibling folder.
final class ChevronButton: NSButton {
    typealias FolderReader = @Sendable (URL) async -> [URL]
    private let folder: URL
    private let navigate: (URL) -> Void
    private let readFolders: FolderReader
    private let presentMenu: @MainActor (ChevronButton, [URL]) -> Void
    private var tracking: NSTrackingArea?
    private var readRevision = 0
    /// Its subfolders being read for the menu.
    private(set) var reading: Task<Void, Never>?

    init(folder: URL, name: String, readFolders: @escaping FolderReader = ChevronButton.subfolders,
         presentMenu: (@MainActor (ChevronButton, [URL]) -> Void)? = nil, navigate: @escaping (URL) -> Void) {
        self.folder = folder
        self.navigate = navigate
        self.readFolders = readFolders
        self.presentMenu = presentMenu ?? { button, folders in button.popUpMenu(listing: folders) }
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Subfolders"))
        symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        contentTintColor = .tertiaryLabelColor
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 5
        target = self
        action = #selector(showMenu)
        toolTip = String(localized: "Folders in \(folder.lastPathComponent)", comment: "Menu of a folder's subfolders; the folder's name")
        setAccessibilityLabel(String(localized: "Folders in \(name)",
                                     comment: "Menu of a folder's subfolders; the folder's name"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        reading?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 22) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }

    override func viewDidHide() {
        cancelReading()
        layer?.backgroundColor = nil
        super.viewDidHide()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            if let window { NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window) }
            cancelReading()
            layer?.backgroundColor = nil
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                                       name: NSWindow.willCloseNotification, object: newWindow)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowWillClose(_ notification: Notification) { cancelReading() }

    @discardableResult private func cancelReading() -> Int {
        readRevision &+= 1
        let revision = readRevision
        let previous = reading
        reading = nil
        previous?.cancel()
        return revision
    }

    @objc private func showMenu() {
        let revision = cancelReading()
        guard revision == readRevision, let owner = window, canPresentMenu(in: owner) else { return }
        let read = readFolders
        reading = Task { [weak self, weak owner, folder] in
            guard !Task.isCancelled else { return }
            let folders = await read(folder)
            guard let self, !Task.isCancelled, revision == readRevision else { return }
            reading = nil
            guard let owner, canPresentMenu(in: owner) else { return }
            presentMenu(self, folders)
        }
    }

    private func canPresentMenu(in owner: NSWindow) -> Bool {
        window === owner && owner.isVisible && owner.attachedSheet == nil && isEnabled && !isHiddenOrHasHiddenAncestor
    }

    /// The folders in `folder` a click on the chevron lists: visible ones, not packages, in Finder's order.
    nonisolated static func subfolders(of folder: URL) async -> [URL] {
        await OwnThread.run {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return urls.filter {
                let values = try? $0.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
    }

    private func popUpMenu(listing folders: [URL]) {
        let menu = NSMenu()
        for url in folders.prefix(400) {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let folderIcon = IconCache.shared.icon(forPath: url.path, folder: true)
            let icon = (folderIcon.copy() as? NSImage) ?? folderIcon
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if folders.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No Folders", comment: "Menu item: the folder has no subfolders"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        navigate(url)
    }
}
