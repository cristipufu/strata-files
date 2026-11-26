import AppKit
import Quartz
import StrataIndex
import StrataModel
import StrataTheme

// MARK: - Data source and delegate

extension BrowserViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Only expanded nodes are considered, even when the outline contains thousands of ordinary file rows.
    var visibleExpandedFolders: [FileNode] {
        guard effectiveMode == .list, !isShowingResults, filter.isEmpty else { return [] }
        return expandedNodes.allObjects.compactMap { node -> (Int, FileNode)? in
            guard outlineView.isItemExpanded(node) else { return nil }
            let row = outlineView.row(forItem: node)
            return row >= 0 ? (row, node) : nil
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// A capped allowance or a failed directory open falls back to the root watch's periodic refresh.
    var hasUnwatchedExpandedFolders: Bool {
        visibleExpandedFolders.contains { !expandedWatches.covers($0.url) }
    }

    func pruneExpandedWatches() {
        let visible = visibleExpandedFolders
        expandedWatches.keepOnly(Set(visible.map { $0.url.fileViewKey }))
        loading.keepChildReads(for: Set(visible.map(ObjectIdentifier.init)))
    }

    func watchExpandedFolder(_ node: FileNode) -> Task<Void, Never>? {
        guard watching.folder != nil, effectiveMode == .list, !isShowingResults, filter.isEmpty,
              expandedNodes.contains(node), self.node(for: node.url) === node else { return nil }
        return expandedWatches.watch(node.url, replacingOldest: false) { [weak self, weak node] in
            guard let self, let node, self.node(for: node.url) === node, outlineView.isItemExpanded(node),
                  outlineView.row(forItem: node) >= 0 else { return }
            loading.invalidateChildren(of: node)
            loadChildren(of: node)
        }
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !isShowingResults, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedNodes.add(node)
        _ = watchExpandedFolder(node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplyingListing, !isShowingResults, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        // Reopening a cached folder must pick up changes made while it was collapsed.
        loadChildren(of: node)
        // AppKit can remember expansion below a collapsed parent.
        for child in visibleExpandedFolders where child !== node && !expandedWatches.contains(child.url) {
            loadChildren(of: child)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedNodes.remove(node)
        pruneExpandedWatches()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return kindSections.roots?.count ?? rows.count }
        guard let node = item as? FileNode else { return 0 }
        guard let children = node.children else {
            loadChildren(of: node)
            return 0
        }
        return children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode {
            guard let children = node.children, children.indices.contains(index) else { return NSNull() }
            return children[index]
        }
        guard item == nil else { return NSNull() }
        if let roots = kindSections.roots { return roots.indices.contains(index) ? roots[index] : NSNull() }
        return rows.indices.contains(index) ? rows[index] : NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        // A drag resting on a folder springs it open; the outline's own expand-on-hover would compete.
        !self.outlineView.isReceivingDrag
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if node.groupTitle != nil { return true }
        guard filter.isEmpty, !isShowingResults else { return false }
        return node.entry.isFolder
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemeRowView(alternatingRows: preferences.alternatingRows)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let heading = item as? ListKindHeading {
            return heading.kind.heading(in: outlineView, font: listTypography.bold)
        }
        guard let node = item as? FileNode else { return nil }
        if let title = node.groupTitle {
            let cell = outlineView.makeView(withIdentifier: .groupCell, owner: nil) as? GroupHeaderCellView ?? {
                let cell = GroupHeaderCellView()
                cell.identifier = .groupCell
                return cell
            }()
            cell.configure(title: title, detail: node.groupDetail ?? "", icon: services.thumbnails.icon(for: node.entry))
            return cell
        }
        guard let column = tableColumn else { return nil }
        let entry = node.entry
        let git = services.git
        let dimmed = entry.isHidden || services.clipboard.isCut(entry.url) || git.isIgnored(entry.url)
        if column.identifier == .name {
            let cell = outlineView.makeView(withIdentifier: .nameCell, owner: nil) as? NameCellView ?? {
                let cell = NameCellView()
                cell.identifier = .nameCell
                return cell
            }()
            cell.configure(name: entry.listName(showingExtension: preferences.showListNameExtensions), icon: services.thumbnails.icon(for: entry), matches: node.matchIndices, dimmed: dimmed,
                           git: git.badge(for: entry.url, isDirectory: entry.isDirectory), tags: services.tags.tags(for: entry.url),
                           cloud: services.cloud.status(for: entry.url), thumbnail: preferences.showIconPreviews ? entry : nil,
                           thumbnails: services.thumbnails, scale: outlineView.window?.backingScaleFactor ?? 2,
                           typography: listTypography)
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: .textCell, owner: nil) as? TextCellView ?? {
            let cell = TextCellView()
            cell.identifier = .textCell
            return cell
        }()
        switch column.identifier {
        case .modified: cell.configure(Format.date(entry.modified), alignment: .left, dimmed: dimmed)
        case .created: cell.configure(Format.date(entry.created), alignment: .left, dimmed: dimmed)
        case .added: cell.configure(Format.date(entry.added), alignment: .left, dimmed: dimmed)
        case .fileExtension: cell.configure(entry.url.pathExtension, alignment: .left, dimmed: dimmed)
        case .dimensions, .width, .height, .duration:
            mediaInfo.request(entry)
            let info = mediaInfo.cached(entry)
            let text: String?
            switch column.identifier {
            case .dimensions: text = info?.dimensions
            case .width: text = info?.width.map(String.init)
            case .height: text = info?.height.map(String.init)
            default: text = info?.durationText
            }
            cell.configure(text ?? (info == nil && mediaInfo.canRead(entry) ? "…" : "—"),
                           alignment: column.headerCell.alignment, dimmed: dimmed)
        case .tags: cell.configure(services.tags.tags(for: entry.url).map(\.name).joined(separator: ", "),
                                   alignment: .left, dimmed: dimmed)
        case .size: cell.configure(sizeText(node), alignment: .right, dimmed: dimmed)
        case .location: cell.configure(Format.tildePath(entry.url.deletingLastPathComponent()), alignment: .left, dimmed: dimmed)
        default: cell.configure(entry.kind, alignment: .left, dimmed: dimmed)
        }
        return cell
    }

    private func sizeText(_ node: FileNode) -> String {
        guard node.entry.isDirectory else { return Format.bytes(node.entry.size ?? 0) }
        guard showsSize(node.entry) else { return "—" }
        if let size = folderSize(node.url, request: true) {
            return Format.bytes(size.bytes)
        }
        return "…"
    }

    /// Symlinks and volumes aren't walked, and neither are guarded folders that would trigger a consent prompt, nor
    /// folders that hold one: the index sizes those without opening it, a walk could not.
    func canMeasure(_ entry: FileEntry) -> Bool {
        guard entry.isDirectory, !entry.isSymlink, !entry.isVolume, !services.copies.contains(entry.url), let directory else { return false }
        if !Privacy.measuringWouldPrompt(entry.url, browsing: directory), !Privacy.walkingWouldReachGuardedFolders(entry.url) {
            return true
        }
        return services.index.folderSizeLookup(entry.url) != .unindexed || FolderSizer.cached(entry.url) != nil
    }

    /// Whether views show a size for `entry` without being asked: a folder you excluded from the index shows none and
    /// isn't walked, since it can hold millions of items, until you ask (Inspector, Calculate Size). Nor does any folder
    /// the index would cover while it is turned off. Nor one its cloud badge says is only in the cloud, unless its
    /// size is known already: nothing of it is on the Mac for a walk to measure.
    func showsSize(_ entry: FileEntry) -> Bool {
        canMeasure(entry) && !services.index.leavesSizeUntilAsked(entry.url)
            && (services.cloud.status(for: entry.url)?.isPlaceholder != true || folderSize(entry.url) != nil)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is ListKindHeading || (item as? FileNode)?.groupTitle != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        FileNode.isFile(item)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !isApplyingListing, loading.hasPartialListing || filtering.matching != nil { pending.cancel() }
        delegate?.browserSelectionDidChange(self)
        prefetchSelection()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // The header follows the pane's choice (`syncSortDescriptor`): only a click that picks another order applies it.
        guard let descriptor = outlineView.sortDescriptors.first, let key = SortKey(rawValue: descriptor.key ?? ""),
              ordering.choice != .init(key: key, ascending: descriptor.ascending) else { return }
        applySort(key, ascending: descriptor.ascending)
    }

    func applySort(_ key: SortKey, ascending direction: Bool, remember: Bool = true) {
        if key == .tags, isShowingResults { services.tags.load(nodes.flatMap { $0.children ?? [$0] }.map(\.entry)) }
        ordering.choose(.init(key: key, ascending: direction), remember: remember)
        if !remember, directory == nil, !isShowingResults { initialSort = .init(key: key, ascending: direction) }
        syncSortDescriptor()
        if remember, !isShowingResults {
            if hasCustomFolderPresentation { rememberFolderPresentation() }
            else { preferences.sortColumn = key.rawValue; preferences.sortAscending = direction }
            folderOptions?.refresh()
        }
        let selection = selectedURLs
        listing.sort(using: sort)
        reloadList()
        pushContent()
        if effectiveMode == .columns { columnController?.resortLoadedColumns() }
        select(selection, scroll: false)
        if loading.hasPartialListing { refresh() }
    }
}

// MARK: - Rename editing

extension BrowserViewController: NSTextFieldDelegate {
    func applyHeldListing() -> Bool {
        defer { filtering.resumeDeferredMatch() }
        guard let held = inlineRename.takeHeldListing(generation: generation) else { return false }
        apply(held.entries, preservingState: held.preservingState, fromTop: held.fromTop, sortedBy: held.sortedBy,
              complete: held.complete, progressive: held.progressive)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let ended = inlineRename.end(field) else { return }
        let node = ended.node, newName = ended.name
        updateListGrouping()
        if !applyHeldListing() {
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
            }
        }
        view.window?.makeFirstResponder(outlineView)
        resorting.editingEnded()
        guard !newName.isEmpty, newName != node.entry.name else { return }
        renameItem(node.url, to: newName)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let node = inlineRename.node {
            (control as? NSTextField)?.stringValue = node.entry.name
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }
}
