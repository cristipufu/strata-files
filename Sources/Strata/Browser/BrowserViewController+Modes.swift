import AppKit
import Quartz

/// List, icons, columns, gallery and disk usage: the other presentations are child view controllers fed the same rows.
extension BrowserViewController {
    @objc func showViewOptions(_ sender: Any?) { services.viewOptions.show() }

    /// Results (search, Recents, Duplicates) have no single folder, so they always use the list.
    var effectiveMode: BrowserViewMode { isShowingResults ? .list : mode }

    var activeView: FileCollectionController? {
        presentations.controller(for: effectiveMode, in: self)
    }

    /// The view that should have keyboard focus.
    var focusView: NSView { activeView?.focusView ?? outlineView }

    /// Where new folders and pastes go: the focused column in column view, otherwise the current folder.
    var targetDirectory: URL? {
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
        // Results stay in List; a user command must not silently change the folder's saved view.
        guard !remember || !isShowingResults else { return }
        guard newMode != mode else { return }
        columnController?.cancelPendingRename()
        let selection = selectedURLs
        setStoredMode(newMode)
        if remember { preferences.viewMode = newMode.rawValue }
        installActiveView()
        pushContent()
        select(selection)
        view.window?.makeFirstResponder(focusView)
        delegate?.browserSelectionDidChange(self)
    }

    /// ⌘+: bigger icons in Icons; in List and Columns, bigger names (Settings ▸ Appearance ▸ Text size, every window).
    @objc func biggerIcons(_ sender: Any?) {
        guard effectiveMode == .grid else { return stepTextSize(1) }
        grid.setIconSize(min(256, grid.iconSize * 1.25), animated: true)
        preferences.gridIconSize = Double(grid.iconSize)
    }

    @objc func smallerIcons(_ sender: Any?) {
        guard effectiveMode == .grid else { return stepTextSize(-1) }
        grid.setIconSize(max(32, grid.iconSize / 1.25), animated: true)
        preferences.gridIconSize = Double(grid.iconSize)
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
        if effectiveMode == .columns, columnsMissedIcons {
            columnsMissedIcons = false
            columnController?.refreshVisibleRows()
        }
    }

    /// Hands the current rows (sorted, filtered, with match highlights) to the active presentation.
    func pushContent(animated: Bool = false) {
        guard let directory, !isShowingResults, let active = activeView else { return }
        let shown = visibleRows
        var matches: [URL: [Int]] = [:]
        for node in shown where !node.matchIndices.isEmpty { matches[node.url] = node.matchIndices }
        let content = FileCollectionContent(directory: directory, entries: shown.map(\.entry), matches: matches)
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
            sortedBy: ordering.snapshot)
        active.apply(content, metadata: metadata, animated: animated)
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
        SpringLoader.canOpen(folder, browsing: directory, during: info)
    }

    func fileView(_ view: NSViewController, drop urls: [URL], onto folder: URL?, copy: Bool) -> Bool {
        guard let target = folder ?? targetDirectory else { return false }
        moveOrCopy(urls, into: target, move: !copy)
        return true
    }

    func fileView(_ view: NSViewController, handle key: FileViewKey) -> Bool {
        handle(key)
    }

    /// The same keys in every view: typing filters, Return renames (or opens), Space previews, Esc clears the filter.
    /// False when the key isn't the pane's to handle.
    func handle(_ key: FileViewKey) -> Bool {
        let typed = filtering.typed
        switch key {
        case .type(let text):
            setFilter(typed + text)
        case .backspace:
            guard !typed.isEmpty else { return false }
            setFilter(String(typed.dropLast()))
        case .escape:
            guard !typed.isEmpty else { return false }
            setFilter("")
        case .returnKey:
            // Disk Usage can't rename in place, so Return opens there.
            filtering.finish()
            if filter.isEmpty && !preferences.returnOpens && effectiveMode != .treemap { renameSelection(nil) } else { openSelection(nil) }
        case .space:
            if typed.isEmpty { toggleQuickLook(nil) } else { setFilter(typed + " ") }
        case .tab:
            return onTab?() ?? false
        }
        return true
    }

    func fileView(_ view: NSViewController, rename entry: FileEntry, to name: String) {
        renameItem(entry.url, to: name)
    }

    func fileView(_ view: NSViewController, renameClicked url: URL) {
        renameClicked(url)
    }
}
