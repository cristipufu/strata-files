import AppKit

/// A heading has outline identity but no URL. The files below it remain real root nodes,
/// so expanding a folder and resolving a file command use the same hierarchy as an ungrouped list.
final class ListKindHeading {
    let kind: FileKindGroup
    init(_ kind: FileKindGroup) { self.kind = kind }
}

final class ListKindSections {
    private let headings = FileKindGroup.allCases.map { ListKindHeading($0) }
    private(set) var roots: [AnyObject]?

    func update(_ files: [FileNode], grouped: Bool) {
        guard grouped else { roots = nil; return }
        let sections = FileKindGroup.sections(files, by: { $0.entry.kindGroup })
        var ordered: [AnyObject] = []
        ordered.reserveCapacity(files.count + sections.count)
        for (kind, files) in sections {
            ordered.append(headings[kind.rawValue])
            ordered.append(contentsOf: files)
        }
        roots = ordered
    }

    func viewportKey(_ item: Any?) -> String? {
        if let heading = item as? ListKindHeading { return heading.kind.viewportKey }
        return (item as? FileNode)?.entry.locationKey
    }

    func heading(for key: String) -> ListKindHeading? {
        guard key.hasPrefix("kind.") else { return nil }
        return headings.first { viewportKey($0) == key }
    }
}

extension BrowserViewController {
    var canGroupByKind: Bool { effectiveMode.supportsKindGrouping && canCustomizeFolderPresentation }
    var groupedByKind: Bool { grouping == .kind && effectiveMode.supportsKindGrouping && !isShowingResults }
    var showsKindGroups: Bool { groupedByKind && effectiveMode == .list }

    @objc func groupBy(_ sender: NSMenuItem) {
        guard canGroupByKind, let raw = sender.representedObject as? String, let grouping = FolderGrouping(rawValue: raw) else { return }
        customizeFolderPresentation { $0.grouping = grouping }
    }

    func reloadList() {
        kindSections.update(rows, grouped: showsKindGroups)
        outlineView.reloadData()
    }

    func updateListGrouping() {
        guard !inlineRename.isEditing, (kindSections.roots != nil) != showsKindGroups else { return }
        let revision = navigationRevision
        let selection = selectedURLs
        let expanded = visibleExpandedFolders
        let viewport = TableViewport.capture(outlineView, key: kindSections.viewportKey)
        let wasApplying = isApplyingListing
        isApplyingListing = true
        defer { isApplyingListing = wasApplying }
        reloadList()
        guard navigationRevision == revision else { return }
        for node in expanded { outlineView.expandItem(node) }
        select(selection, scroll: false)
        if navigationRevision == revision { restoreListViewport(viewport) }
    }

    func restoreListViewport(_ viewport: TableViewport?) {
        viewport?.restore(in: outlineView) { key in
            if let heading = kindSections.heading(for: key) { return outlineView.row(forItem: heading) }
            return listing.node(forKey: key).map { outlineView.row(forItem: $0) }
        }
    }
}
