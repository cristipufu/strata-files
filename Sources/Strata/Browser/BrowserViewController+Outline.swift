import AppKit
import Quartz
import StrataIndex
import StrataModel
import StrataTheme

// MARK: - Data source and delegate

extension BrowserViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return rows.count }
        guard let children = node.children else {
            loadChildren(of: node)
            return 0
        }
        return children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else {
            if rows.indices.contains(index) { return rows[index] }
            if let first = rows.first { return first }
            return FileNode(entry: FileEntry(url: URL(fileURLWithPath: "/"), name: "", isDirectory: true, isPackage: false,
                                             isHidden: false, isSymlink: false, isVolume: false, size: nil, modified: nil, created: nil,
                                             added: nil, kind: "", contentType: nil))
        }
        guard let children = node.children, children.indices.contains(index) else { return node }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        // A drag resting on a folder springs it open; the outline's own expand-on-hover would compete.
        !isDragOver
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if node.groupTitle != nil { return true }
        guard filter.isEmpty, !isShowingResults else { return false }
        return node.entry.isFolder
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ThemeRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
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
            cell.configure(name: entry.displayName, icon: services.thumbnails.icon(for: entry), matches: node.matchIndices, dimmed: dimmed,
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
        // A container's folder holds only what's been browsed: its size isn't known.
        if services.copies.contains(node.url) { return "—" }
        if let size = services.index.folderSize(node.url) ?? sizer.cached(node.url) { return Format.bytes(size.bytes) }
        guard canMeasure(node.entry) else { return "—" }
        sizer.request(node.url)
        return "…"
    }

    /// Symlinks and volumes aren't walked, and neither are guarded folders that would trigger a consent prompt.
    func canMeasure(_ entry: FileEntry) -> Bool {
        guard entry.isDirectory, !entry.isSymlink, !entry.isVolume, !services.copies.contains(entry.url), let directory else { return false }
        if services.index.folderSize(entry.url) != nil { return true }
        return !Privacy.measuringWouldPrompt(entry.url, browsing: directory)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? FileNode)?.groupTitle != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FileNode)?.groupTitle == nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        delegate?.browserSelectionDidChange(self)
        prefetchSelection()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !updatingSortDescriptor, let descriptor = outlineView.sortDescriptors.first,
              let key = SortKey(rawValue: descriptor.key ?? "") else { return }
        applySort(key, ascending: descriptor.ascending)
    }

    func applySort(_ key: SortKey, ascending direction: Bool, remember: Bool = true) {
        if key == .tags, isShowingResults { services.tags.load(nodes.flatMap { $0.children ?? [$0] }.map(\.entry)) }
        ordering.choose(.init(key: key, ascending: direction), remember: remember)
        syncSortDescriptor()
        if remember { preferences.sortColumn = key.rawValue; preferences.sortAscending = direction }
        let selection = selectedURLs
        listing.sort(using: sort)
        outlineView.reloadData()
        pushContent()
        select(selection, scroll: false)
    }
}

// MARK: - Rename editing

extension BrowserViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = renaming else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        renamingField = nil
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        if let deferred = deferredApply, deferred.generation == generation {
            apply(deferred.entries, preservingState: deferred.preservingState, fromTop: deferred.fromTop,
                  sortedBy: deferred.sortedBy)
        } else {
            deferredApply = nil
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
            }
        }
        view.window?.makeFirstResponder(outlineView)
        if deferredMetadataOrder {
            deferredMetadataOrder = false
            resortAfterMetadata()
        }
        guard !newName.isEmpty, newName != node.entry.name else { return }
        renameItem(node.url, to: newName)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let node = renaming {
            (control as? NSTextField)?.stringValue = node.entry.name
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }
}

// MARK: - Quick Look panel

extension BrowserViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        return urls.indices.contains(index) ? (urls[index] as NSURL) : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, !isRenamingInPlace, view.window?.attachedSheet == nil,
              !(view.window?.firstResponder is NSText) else { return false }
        focusView.keyDown(with: event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = (item as? NSURL) as URL? else { return .zero }
        return iconScreenRect(for: url) ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = (item as? NSURL) as URL? else { return nil }
        guard let entry = selectedEntries.first(where: { Self.key($0.url) == Self.key(url) }) ?? node(for: url)?.entry else { return nil }
        // The thumbnail the row shows, so the zoom starts from what's on screen.
        let scale = view.window?.backingScaleFactor ?? 2
        if preferences.showIconPreviews, services.thumbnails.canThumbnail(entry),
           let thumbnail = services.thumbnails.cached(entry, size: NameCellView.iconSide, scale: scale) { return thumbnail.image }
        return services.thumbnails.icon(for: entry)
    }
}
