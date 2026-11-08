import AppKit
import Quartz

/// List, icons, columns, gallery and disk usage: the other presentations are child view controllers fed the same rows.
extension BrowserViewController {
    @objc func showViewOptions(_ sender: Any?) { services.viewOptions.show(for: self) }

    var effectiveMode: BrowserViewMode { isShowingResults ? results.mode : mode }

    func supportsMode(_ mode: BrowserViewMode) -> Bool { !isShowingResults || PaneResults.supports(mode) }

    var activeView: FileCollectionController? {
        presentations.controller(for: effectiveMode, in: self)
    }

    /// The view that should have keyboard focus.
    var focusView: NSView { activeView?.focusView ?? outlineView }

    /// Where new folders and pastes go: the focused column in column view, otherwise the current folder.
    var targetDirectory: URL? {
        guard !isShowingResults else { return nil }
        if effectiveMode == .columns, let active = columnController?.activeDirectory { return active }
        return directory
    }

    @objc func setViewMode(_ sender: Any?) {
        let picked: BrowserViewMode? = if let group = sender as? NSToolbarItemGroup {
            BrowserViewMode.ordered.indices.contains(group.selectedIndex) ? BrowserViewMode.ordered[group.selectedIndex] : nil
        } else {
            BrowserViewMode(rawValue: (sender as? NSMenuItem)?.tag ?? 0)
        }
        guard let mode = picked else { return }
        setMode(mode)
    }

    /// `remember: false` (a workspace reopening) leaves the view new windows open in as it is.
    func setMode(_ newMode: BrowserViewMode, remember: Bool = true) {
        if !remember, directory == nil, !isShowingResults { initialMode = newMode }
        guard supportsMode(newMode), newMode != effectiveMode else { return }
        let revision = navigationRevision
        columnController?.cancelPendingRename()
        let selection = selectedURLs
        if isShowingResults { results.chooseMode(newMode) }
        else {
            setStoredMode(newMode)
            if remember {
                if hasCustomFolderPresentation { rememberFolderPresentation() }
                else { preferences.viewMode = newMode.rawValue }
                folderOptions?.refresh()
            }
        }
        installActiveView()
        if !applyHeldListing() { pushContent() }
        guard navigationRevision == revision, effectiveMode == newMode else { return }
        select(selection)
        view.window?.makeFirstResponder(focusView)
        delegate?.browserSelectionDidChange(self)
    }

    /// ⌘+: bigger icons in Icons; in List and Columns, bigger names (Settings ▸ Appearance ▸ Text size, every window).
    @objc func biggerIcons(_ sender: Any?) {
        guard effectiveMode == .grid else { return stepTextSize(1) }
        grid.setIconSize(min(256, grid.iconSize * 1.25), animated: true)
        setIconSize(Double(grid.iconSize))
    }

    @objc func smallerIcons(_ sender: Any?) {
        guard effectiveMode == .grid else { return stepTextSize(-1) }
        grid.setIconSize(max(32, grid.iconSize / 1.25), animated: true)
        setIconSize(Double(grid.iconSize))
    }

    /// The text size's range is 11–16 pt; past an end there's nothing to do.
    static let textSizes: ClosedRange<Double> = 11...16

    private func stepTextSize(_ delta: Double) {
        let size = min(max(preferences.nameTextSize + delta, Self.textSizes.lowerBound), Self.textSizes.upperBound)
        guard size != preferences.nameTextSize else { return Sounds.beep() }
        preferences.nameTextSize = size
    }

    /// Shows the active presentation's view on top of the list (the list's scroll view hides).
    func installActiveView() {
        presentations.install(effectiveMode, in: self)
        if effectiveMode == .list { listNamesChanged() }
    }

    /// Hands the current rows (sorted, filtered, with match highlights) to the active presentation.
    func pushContent(animated: Bool = false) {
        guard let active = activeView else { return }
        let directory = isShowingResults ? nil : directory
        guard isShowingResults || directory != nil else { return }
        let shown = visibleRows.flatMap { $0.groupTitle == nil ? [$0] : $0.children ?? [] }
        var matches: [URL: [Int]] = [:]
        for node in shown where !node.matchIndices.isEmpty { matches[node.url] = node.matchIndices }
        var details: FileCollectionDetails?
        if isShowingResults {
            var groups: [String: String] = [:]
            for group in visibleRows where group.groupTitle != nil {
                let title = [group.groupTitle, group.groupDetail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                for child in group.children ?? [] { groups[child.entry.locationKey] = title }
            }
            details = FileCollectionDetails(groups: groups, copies: services.copies)
        }
        let content = FileCollectionContent(complete: !loading.hasPartialListing, directory: directory, entries: shown.map(\.entry), matches: matches, details: details)
        let diskSizeReader: (@MainActor (FileEntry) -> DiskSizeMeasurement)?
        if directory == nil || directory.map(services.copies.contains) == true || directory.flatMap(ArchiveCache.archive(containing:)) != nil {
            diskSizeReader = nil
        } else {
            diskSizeReader = { [weak self] entry in self?.diskSize(entry) ?? .unavailable }
        }
        let metadata = FileCollectionMetadata(
            ordered: { [weak self] a, b in
                self?.ordered(a, b) ?? (a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending)
            },
            canMeasure: { [weak self] entry in self?.canMeasure(entry) ?? false },
            size: { [weak self] entry in
                guard let self else { return nil }
                guard entry.isDirectory else { return entry.size }
                return canMeasure(entry) ? folderSize(entry.url, request: true)?.bytes : 0
            },
            sortedBy: ordering.snapshot,
            diskSize: diskSizeReader)
        active.apply(content, metadata: metadata, animated: animated)
    }

    private func diskSize(_ entry: FileEntry) -> DiskSizeMeasurement {
        if !entry.isDirectory || entry.isSymlink {
            return entry.allocatedSize.map(DiskSizeMeasurement.measured) ?? .unavailable
        }
        guard canMeasure(entry) else { return .unavailable }
        guard let size = folderSize(entry.url, request: true) else { return .measuring }
        guard let bytes = size.allocatedBytes else { return .unavailable }
        return size.allocationComplete ? .measured(bytes) : .partial(bytes)
    }

    // MARK: - Lazily created presentations

    var grid: GridViewController { presentations.grid(in: self) }
    var columns: ColumnBrowserViewController { presentations.columns(in: self) }
    var gallery: GalleryViewController { presentations.gallery(in: self) }
    var treemap: TreemapViewController { presentations.treemap(in: self) }

    /// Reuses the list's measurements and privacy checks; links and disks are never walked for icon info.
    func iconFolderSizeText(_ entry: FileEntry) -> String? {
        guard entry.isFolder else { return nil }
        guard canMeasure(entry) else { return "—" }
        return folderSize(entry.url, request: true).map { Format.bytes($0.bytes) } ?? "…"
    }
}

extension BrowserViewController: FileCollectionViewDelegate {
    func fileView(_ view: NSViewController, open entries: [FileEntry]) {
        openEntries(entries)
    }

    func fileView(_ view: NSViewController, selectionDidChange urls: [URL]) {
        guard view === activeView else { return }
        if !isApplyingListing, loading.hasPartialListing || filtering.matching != nil,
           Set(urls.map(\.fileViewKey)) != appliedSelection { pending.cancel() }
        delegate?.browserSelectionDidChange(self)
        prefetchSelection()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    func fileView(_ view: NSViewController, menuFor entries: [FileEntry]) -> NSMenu? {
        contextMenu()
    }

    func fileView(_ view: NSViewController, springLoad folder: URL, drag: Int) {
        springLoad(folder, drag: drag)
    }

    func fileView(_ view: NSViewController, canSpringLoad folder: URL, during info: NSDraggingInfo) -> Bool {
        SpringLoader.canOpen(folder, browsing: targetDirectory, during: info)
    }

    func fileView(_ view: NSViewController, drop urls: [URL], onto folder: URL?, info: NSDraggingInfo) -> Bool {
        guard !urls.isEmpty, let target = folder ?? targetDirectory else { return false }
        FileDrop.drop(urls, into: target, info: info, copies: services.copies) { [weak self] move in
            self?.moveOrCopy(urls, into: target, move: move)
        }
        return true
    }

    func fileView(_ view: NSViewController, handle key: FileViewKey) -> Bool {
        handle(key)
    }

    func fileView(_ view: NSViewController, handleOutsideFilter key: FileViewKey) -> Bool {
        handle(key, typesIntoFilter: false)
    }

    /// The same keys in every view (see `PaneKeyAction`): typing filters, Return renames (or opens), Space previews,
    /// Esc clears the filter, and the Windows keyboard's F2, ⌦ and ⌫. False when the key isn't the pane's to handle.
    func handle(_ key: FileViewKey, typesIntoFilter: Bool = true) -> Bool {
        // Return acts on the rows for what was typed: a match still being worked out is made now.
        if key == .returnKey { filtering.finish() }
        let context = PaneKeyAction.Context(typed: filtering.typed, filtered: !filter.isEmpty, typesIntoFilter: typesIntoFilter,
                                            returnOpens: preferences.returnOpens, windowsKeyboard: preferences.windowsKeyboard,
                                            renamesInPlace: effectiveMode != .treemap)
        switch PaneKeyAction.decide(key, context) {
        case .filter(let text): setFilter(text)
        case .open: openSelection(nil)
        case .rename: renameSelection(nil)
        case .quickLook: toggleQuickLook(nil)
        case .command(let action): return sendMenuCommand(action)
        case .back: return onBack?() ?? false
        case .tab: return onTab?() ?? false
        case .none: return false
        }
        return true
    }

    /// On and off exactly when its menu item is, and sent with one, as the menu's shortcut sends it.
    private func sendMenuCommand(_ action: Selector) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        guard validateMenuItem(item) else { return false }
        _ = perform(action, with: item)
        return true
    }

    func fileView(_ view: NSViewController, rename entry: FileEntry, to name: String) {
        renameItem(entry.url, to: name)
    }

    func fileView(_ view: NSViewController, renameClicked url: URL) {
        renameClicked(url)
    }
}
