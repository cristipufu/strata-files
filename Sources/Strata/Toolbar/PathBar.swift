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

    private let crumbs = NSStackView()
    private let field = NSTextField()
    private(set) var isEditing = false
    private let suggestions: PathSuggestions
    private let suggestionList: PathSuggestionList
    private var suggesting: Task<Void, Never>?
    private let copies: CopyProviders
    private let names: FolderNames
    private let embedded: Bool

    var editorField: NSTextField { field }

    var crumbButtons: [CrumbButton] {
        crumbs.arrangedSubviews.flatMap { view -> [CrumbButton] in
            if let button = view as? CrumbButton { return [button] }
            if let stack = view as? NSStackView { return stack.arrangedSubviews.compactMap { $0 as? CrumbButton } }
            return []
        }
    }

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

        crumbs.orientation = .horizontal
        crumbs.spacing = 0
        crumbs.alignment = .centerY
        crumbs.detachesHiddenViews = true
        // Let a deep path squeeze into the bar by dropping middle crumbs (their visibility priorities below) instead of
        // forcing the bar wider: past the toolbar's room, AppKit would move every toolbar item into the overflow menu.
        crumbs.setClippingResistancePriority(embedded ? .init(230) : .defaultLow, for: .horizontal)
        crumbs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(crumbs)

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
        suggestionList.onPick = { [weak self] suggestion in self?.go(to: suggestion) }

        var constraints = [
            crumbs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            crumbs.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if embedded {
            setContentCompressionResistancePriority(.init(199), for: .horizontal)
            setContentHuggingPriority(.init(199), for: .horizontal)
            field.setContentCompressionResistancePriority(.init(199), for: .horizontal)
            branchPill.setContentCompressionResistancePriority(.init(220), for: .horizontal)
        } else {
            // A wish, weaker than the toolbar's own sizing: the bar gives up width before other items overflow.
            let preferred = widthAnchor.constraint(equalToConstant: 520)
            preferred.priority = .fittingSizeCompression
            constraints += [
                heightAnchor.constraint(equalToConstant: 32),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
                widthAnchor.constraint(lessThanOrEqualToConstant: 720),
                preferred,
            ]
        }
        NSLayoutConstraint.activate(constraints)
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
        if self.title?.text == title, self.title?.symbol == symbol, !crumbs.arrangedSubviews.isEmpty { return }
        self.title = (title, symbol)
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let crumb = CrumbButton(title: title, symbol: symbol, emphasized: true)
        if embedded { crumb.setContentCompressionResistancePriority(.init(220), for: .horizontal) }
        crumb.target = self
        crumb.action = #selector(titleCrumbClicked)
        crumb.isEnabled = true
        crumbs.addArrangedSubview(crumb)
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
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else { return }
        let parts = Self.components(of: url, copies: copies, names: names)
        let repoRootPath = gitRoot?.standardizedFileURL.path
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let crumb = CrumbButton(title: part.title, symbol: part.symbol, emphasized: isLast)
            if embedded { crumb.setContentCompressionResistancePriority(.init(220), for: .horizontal) }
            crumb.toolTip = Format.tildePath(part.url)
            crumb.target = self
            crumb.action = #selector(crumbClicked(_:))
            crumb.destination = part.url
            let group = NSStackView(views: [crumb])
            group.spacing = 0
            let isRepoRoot = part.url.standardizedFileURL.path == repoRootPath
            if isRepoRoot {
                group.addArrangedSubview(branchPill)
                group.setCustomSpacing(2, after: crumb)
                group.setCustomSpacing(2, after: branchPill)
            }
            if !isLast {
                let name = part.title.isEmpty ? part.url.lastPathComponent : part.title
                let chevron = ChevronButton(folder: part.url, name: name) { [weak self] target in
                    self?.onActivate?()
                    self?.onNavigate?(target, nil)
                }
                group.addArrangedSubview(chevron)
            }
            crumbs.addArrangedSubview(group)
            // When space runs out, middle folders go first; the root and the current folder stay.
            let priority: Float
            if embedded {
                priority = index == 0 || isLast ? 1000 : isRepoRoot ? 180 : Float(100 + min(index, 70))
            } else {
                priority = index == 0 || isLast ? 1000 : isRepoRoot ? 900 : Float(500 + index)
            }
            crumbs.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: priority), for: group)
        }
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

    private static func components(of url: URL, depth: Int = 0, copies: CopyProviders,
                                   names: FolderNames) -> [(title: String, url: URL, symbol: String?)] {
        // Containers, then a container, then its folders from `/`.
        if let folder = copies.containerCopies.containersFolder(of: url) {
            var parts: [(title: String, url: URL, symbol: String?)] = [(String(localized: "Containers", comment: "Sidebar section title: Docker containers"), folder, "shippingbox")]
            var current = folder
            let inner = url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count).split(separator: "/")
            for component in inner {
                current = current.appending(path: String(component))
                parts.append((String(component), current, nil))
            }
            return parts
        }
        // On a server: the server, then its folders from `/`.
        if let (server, top) = copies.remoteCopies.server(containing: url) {
            var parts: [(title: String, url: URL, symbol: String?)] = [(server.name, top, server.kind == .s3 ? "externaldrive.connected.to.line.below" : "server.rack")]
            var current = top
            let inner = url.standardizedFileURL.path.dropFirst(top.standardizedFileURL.path.count).split(separator: "/")
            for component in inner {
                current = current.appending(path: String(component))
                parts.append((String(component), current, nil))
            }
            return parts
        }
        // Inside an archive opened as a folder: the archive's own location, the archive, then the folders inside it
        // (an archive opened from inside another one nests, a few levels at most).
        if depth < 8, let (archive, top) = ArchiveCache.archive(containing: url) {
            var parts = components(of: archive.deletingLastPathComponent(), depth: depth + 1, copies: copies,
                                   names: names)
            parts.append((archive.lastPathComponent, top, "archivebox"))
            var current = top
            let inner = url.standardizedFileURL.path.dropFirst(top.standardizedFileURL.path.count).split(separator: "/")
            for component in inner {
                current = current.appending(path: String(component))
                parts.append((String(component), current, nil))
            }
            return parts
        }
        let path = url.standardizedFileURL.path
        let home = Places.home.standardizedFileURL.path
        var parts: [(title: String, url: URL, symbol: String?)] = []
        let root: String
        if path == home || path.hasPrefix(home + "/") {
            root = home
            // Icon only, unless home is the folder being shown.
            let homeURL = URL(fileURLWithPath: home)
            parts.append((path == home ? names.name(homeURL) : "", homeURL, "house.fill"))
        } else if path.hasPrefix("/Volumes/"), let name = path.split(separator: "/").dropFirst().first {
            root = "/Volumes/\(name)"
            parts.append((String(name), URL(fileURLWithPath: root), "externaldrive.fill"))
        } else {
            root = "/"
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
            parts.append((values?.volumeLocalizedName ?? "Macintosh HD", URL(fileURLWithPath: "/"), "internaldrive.fill"))
        }
        var current = URL(fileURLWithPath: root)
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
            if found.count == 1, found[0].url.standardizedFileURL.path == URL(fileURLWithPath: typed).standardizedFileURL.path {
                return closeSuggestions()
            }
            var isFolder: ObjCBool = false
            let typedIsThere = FileManager.default.fileExists(atPath: typed, isDirectory: &isFolder)
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
        onNavigate?(suggestion.url.standardizedFileURL, nil)
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
        let path = resolvedPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            let text = field.stringValue
            if suggestionList.forText == text, let best = suggestionList.items.first { return go(to: best) }
            suggesting?.cancel()
            let current = url
            suggesting = Task { [weak self] in
                guard let self else { return }
                let found = await suggestions.suggestions(for: text, in: current)
                guard !Task.isCancelled, isEditing, field.stringValue == text else { return }
                if let best = found.first { go(to: best) } else { shake() }
            }
            return
        }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let isFolder = isDirectory.boolValue && !NSWorkspace.shared.isFilePackage(atPath: path)
        endEditing(restoreFocus: true)
        if isFolder {
            onNavigate?(target, nil)
        } else {
            onNavigate?(target.deletingLastPathComponent(), target)
        }
    }

    /// Completes the last path component against the folders on disk, as far as it's unambiguous.
    private func complete() {
        let path = resolvedPath()
        let directory = path.hasSuffix("/") ? path : (path as NSString).deletingLastPathComponent
        let prefix = path.hasSuffix("/") ? "" : (path as NSString).lastPathComponent
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else {
            shake()
            return
        }
        let matches = names.filter { name in
            guard name.lowercased().hasPrefix(prefix.lowercased()), !name.hasPrefix(".") || prefix.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name), isDirectory: &isDir) && isDir.boolValue
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular),
            .foregroundColor: emphasized ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? String(localized: "Home", comment: "Accessibility: the home folder crumb") : title)
            symbolConfiguration = .init(pointSize: 12, weight: .medium)
            contentTintColor = .secondaryLabelColor
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            imageHugsTitle = true
        }
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += title.isEmpty ? 14 : 16
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

    fileprivate func setHighlight(_ on: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil
        }
    }
}

/// The separator between crumbs; click it to jump to a sibling folder.
final class ChevronButton: NSButton {
    private let folder: URL
    private let navigate: (URL) -> Void
    private var tracking: NSTrackingArea?

    init(folder: URL, name: String, navigate: @escaping (URL) -> Void) {
        self.folder = folder
        self.navigate = navigate
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

    @objc private func showMenu() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let folders = urls.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isPackage != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

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
