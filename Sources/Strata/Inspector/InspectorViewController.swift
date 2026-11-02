import AppKit
import UniformTypeIdentifiers
import ImageIO
import Quartz

/// Live preview and metadata for the selection, or for the current folder when nothing is selected.
final class InspectorViewController: NSViewController {
    let services: BrowserServices
    private let previewBox = NSView()
    let preview = QuickLookPreviewView(frame: .zero, style: .compact)
    let iconView = NSImageView()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    /// The details: size, dates, where it is…
    let infoRows = InspectorRows()
    /// The shown items' Finder tags, editable.
    private let tagPicker: TagPicker
    private var tagField: TagField { tagPicker.field }
    /// Comments, Open With, Locked and permissions, for one item.
    let infoEditor: InfoEditor
    /// The Where row's folder names and icons, read once each.
    private let looks = FinderLooks()
    var infoCard: InspectorCard!
    var tagsCard: InspectorCard!
    var commentsCard: InspectorCard!
    var openWithCard: InspectorCard!
    var permissionsCard: InspectorCard!
    /// Shows a folder in the browser (the Where row).
    var onShowFolder: ((_ folder: URL, _ select: URL) -> Void)?
    /// Opens a folder in the browser (a container's mount).
    var onOpenFolder: ((URL) -> Void)?
    /// Shows a container's files (a Compose service).
    var onOpenContainer: ((String) -> Void)?
    /// The container these files are of, and its mounts.
    let containerView: ContainerInspectorView
    /// A Compose project's services, for a folder `docker compose` runs in.
    let composeView: ComposeInspectorView
    private var composeFolder: URL?
    private var shownURLs: [URL] = []
    /// The items whose icons the icon view shows, to draw again when their own icons arrive.
    private var iconItems: [FileEntry] = []
    private var previewWork: DispatchWorkItem?
    private var previewingContent = false
    let projectView: ProjectInspectorView
    let summary = SummaryView()
    private var projectFolder: URL?
    private var projectTask: Task<Void, Never>?
    /// The image size read for the item on show, by its path and modification date, and the read under way.
    private var dimensions: (key: String, text: String?)?
    private(set) var dimensionsTask: Task<Void, Never>?
    /// A native preview for code, Markdown, JSON, CSV, SQLite and archives; Quick Look covers everything else.
    private(set) var richPreview: NSView?
    private let richBackdrop = NSBox()
    private var previewHeight: NSLayoutConstraint?

    private let previewScheduler: (DispatchWorkItem) -> Void
    private let readSelectionSizes: InspectorSelectionSizes.Reader
    private(set) var selectionSizesTask: Task<Void, Never>?

    init(services: BrowserServices,
         previewScheduler: @escaping (DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: $0)
         }, readSelectionSizes: @escaping InspectorSelectionSizes.Reader = InspectorSelectionSizes.read) {
        self.services = services
        self.readSelectionSizes = readSelectionSizes
        tagPicker = TagPicker(listWhileEditing: true, maxRows: 6, tags: services.tags)
        self.containerView = ContainerInspectorView(preferences: services.preferences,
                                                    copies: services.copies.containerCopies,
                                                    store: services.containerStore)
        self.composeView = ComposeInspectorView(preferences: services.preferences,
                                                store: services.containerStore)
        self.projectView = ProjectInspectorView(files: services.files, git: services.git, clipboard: services.clipboard)
        self.previewScheduler = previewScheduler
        infoEditor = InfoEditor(readFacts: InfoEditor.Facts.read(_:opensWithApps:))
        super.init(nibName: nil, bundle: nil)
    }

    isolated deinit {
        selectionSizesTask?.cancel()
        previewWork?.cancel()
        projectTask?.cancel()
        dimensionsTask?.cancel()
        summary.url = nil
        infoEditor.hide()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        configurePreview()
        configureTitles()
        let cards = makeCards()
        observeChanges()
        view = layOut(cards)
    }

    /// The rounded box the preview, a rich preview's backdrop or the icon fills.
    private func configurePreview() {
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 14
        previewBox.layer?.cornerCurve = .continuous
        previewBox.layer?.masksToBounds = true
        ThemeStyle.bind(previewBox, to: .inspector)

        preview.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        richBackdrop.boxType = .custom
        richBackdrop.fillColor = .textBackgroundColor
        richBackdrop.borderColor = .separatorColor
        ThemeStyle.bind(richBackdrop, to: .inspector)
        richBackdrop.borderWidth = 1
        richBackdrop.cornerRadius = 14
        richBackdrop.isHidden = true
        richBackdrop.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(richBackdrop)
        previewBox.addSubview(preview)
        previewBox.addSubview(iconView)
    }

    private func configureTitles() {
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = InspectorColors.primary
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.isSelectable = true
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = InspectorColors.secondary
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
    }

    /// The sections below the titles, in order.
    private func makeCards() -> [NSView] {
        projectView.isHidden = true
        projectView.onDidClean = { [weak self] _ in self?.reloadProject() }
        // Every section is a card of the same kind, in Finder's Get Info order.
        let preferences = services.preferences
        infoCard = InspectorCard(id: "info", title: String(localized: "Information", comment: "Inspector section: size, dates, location"),
                                 symbol: "info.circle", content: infoRows, preferences: preferences)
        tagsCard = InspectorCard(id: "tags", title: String(localized: "Tags", comment: "Inspector section: Finder tags"),
                                 symbol: "tag", content: tagPicker, preferences: preferences)
        commentsCard = InspectorCard(id: "comments", title: String(localized: "Comments", comment: "Inspector: the item’s Spotlight comments"),
                                     symbol: "text.bubble", content: infoEditor.commentsContent, preferences: preferences)
        openWithCard = InspectorCard(id: "openWith", title: String(localized: "Open With"), symbol: "app.badge",
                                     content: infoEditor.openWithContent, preferences: preferences)
        permissionsCard = InspectorCard(id: "permissions",
                                        title: String(localized: "Sharing & Permissions", comment: "Inspector section: Locked and who may read and write"),
                                        symbol: "lock", content: infoEditor.permissionsContent, preferences: preferences)
        containerView.isHidden = true
        containerView.onOpen = { [weak self] url in self?.onOpenFolder?(url) }
        composeView.isHidden = true
        composeView.onOpenContainer = { [weak self] id in self?.onOpenContainer?(id) }
        for card in [tagsCard, commentsCard, openWithCard, permissionsCard] as [NSView] { card.isHidden = true }
        return [containerView, infoCard, tagsCard, commentsCard, openWithCard, permissionsCard, summary, projectView, composeView]
    }

    private func observeChanges() {
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged(_:)), name: .tagsChanged, object: services.tags)
        NotificationCenter.default.addObserver(self, selector: #selector(containerFilesFetched(_:)), name: .containerFilesFetched, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(containersChanged), name: .containersChanged,
                                               object: services.containerStore)
        NotificationCenter.default.addObserver(self, selector: #selector(iconsLoaded(_:)), name: .iconsLoaded, object: nil)
    }

    /// The preview, titles and cards in one scrolling column.
    private func layOut(_ cards: [NSView]) -> NSScrollView {
        let stack = NSStackView(views: [previewBox, titleLabel, subtitleLabel] + cards)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.setCustomSpacing(14, after: previewBox)
        stack.setCustomSpacing(2, after: titleLabel)
        stack.setCustomSpacing(16, after: subtitleLabel)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 18, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        ThemeStyle.bind(scroll, to: .inspector)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            // A little in from the Inspector's edges.
            previewBox.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 5),
            previewBox.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -5),
            richBackdrop.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            richBackdrop.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            richBackdrop.topAnchor.constraint(equalTo: previewBox.topAnchor),
            richBackdrop.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewBox.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 160),
            iconView.heightAnchor.constraint(equalToConstant: 160),
            titleLabel.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: previewBox.widthAnchor),
        ] + cards.map { $0.widthAnchor.constraint(equalTo: previewBox.widthAnchor) })
        previewHeight = previewBox.heightAnchor.constraint(equalToConstant: 230)
        previewHeight?.isActive = true
        return scroll
    }

    /// The file shown arrived from its container: preview it now.
    @objc private func containerFilesFetched(_ notification: Notification) {
        guard shownURLs.count == 1, let urls = notification.object as? [URL],
              let shown = shownURLs.first, services.copies.contains(shown),
              urls.contains(where: { $0.lexicallyStandardized.path == shown.lexicallyStandardized.path }),
              let entry = FileEntry(url: shown), canPreview(entry) else { return }
        if !entry.isDirectory {
            updateSummary(for: [entry])
            showSingleItem(entry, folderSize: { _ in nil }, canMeasure: { _ in false })
        }
        schedulePreview(entry)
    }

    private func canPreview(_ entry: FileEntry) -> Bool {
        !entry.isSymlink && !services.copies.isPlaceholder(entry.url)
    }

    private func updateSummary(for items: [FileEntry]) {
        // Summaries for single documents; the card hides itself when there's no readable text.
        // Source code has its own preview; summaries are for prose (PDFs, Markdown, Word, text…).
        let isCode = items.first?.contentType.map { $0.conforms(to: .sourceCode) || $0.conforms(to: .json) || $0.conforms(to: .propertyList) } ?? false
        // Only for files with text to read (a video gets no empty Summary card).
        let document = items.count == 1 && !items[0].isDirectory && canPreview(items[0])
            && !isCode && Summarizer.canSummarize(items[0].url) ? items[0].url : nil
        if summary.url != document { summary.url = document }
        summary.isHidden = document == nil
    }

    private func isReadOnlyCopy(_ url: URL) -> Bool {
        ReadOnlyCopies.contains(url, copies: services.copies)
    }

    /// Containers started, stopped or went away: their cards follow.
    @objc private func containersChanged() {
        containerView.configure(url: shownURLs.first)
        composeView.configure(composeFolder)
    }

    @objc private func iconsLoaded(_ notification: Notification) {
        guard !iconView.isHidden, let paths = notification.userInfo?["paths"] as? Set<String>,
              iconItems.contains(where: { paths.contains($0.url.path) }) else { return }
        showIcons(of: iconItems)
    }

    private func showIcons(of items: [FileEntry]) {
        iconItems = items
        iconView.image = items.count == 1 ? services.thumbnails.icon(for: items[0]) : stackedIcons(items)
    }

    @objc private func tagsChanged(_ notification: Notification) {
        guard tagField.currentEditor() == nil,
              let changed = notification.userInfo?["urls"] as? [URL], changed.contains(where: shownURLs.contains) else { return }
        tagField.reload()
    }

    /// Shows `entries`, or `folder` when the selection is empty. Calling again with the same items only refreshes metadata.
    func show(entries: [FileEntry], folder: FileEntry?, folderSize: (URL) -> FolderSize?, canMeasure: (FileEntry) -> Bool) {
        selectionSizesTask?.cancel()
        selectionSizesTask = nil
        let items = entries.isEmpty ? [folder].compactMap { $0 } : entries
        showProject(of: items)
        updateSummary(for: items)
        let urls = items.map(\.url)
        let sameItems = urls == shownURLs
        shownURLs = urls
        updateTags(of: items, sameItems: sameItems)
        updateInfoCards(of: items)
        guard let first = items.first else { return showNothing() }
        if items.count == 1 {
            showSingleItem(first, folderSize: folderSize, canMeasure: canMeasure)
            if !sameItems || canPreview(first) != previewingContent {
                schedulePreview(first)
            }
        } else {
            showSelection(items, sameItems: sameItems, folderSize: folderSize, canMeasure: canMeasure)
            if !sameItems {
                hidePreview()
                iconView.isHidden = false
                showIcons(of: items)
            }
        }
    }

    /// The project section follows a single selected folder, or the current folder when nothing is selected; never in
    /// a read-only copy (a container's scripts are not this Mac's to run).
    private func showProject(of items: [FileEntry]) {
        let projectFolder = items.count == 1 && items[0].isFolder && !isReadOnlyCopy(items[0].url) && FileOps.canTrash(spelled: items[0].url, copies: services.copies) ? items[0].url : nil
        loadProject(projectFolder)
        composeFolder = projectFolder
        composeView.configure(projectFolder)
        containerView.configure(url: items.first?.url)
    }

    /// Volumes, links and archives opened as folders don't take tags. A refresh while you type leaves your typing alone.
    /// Typing in the tag field belongs to the items it was opened on: a new selection (or a hidden field) ends it,
    /// applying what was typed to those items.
    private func updateTags(of items: [FileEntry], sameItems: Bool) {
        let taggable = !items.isEmpty
            && !items.contains { $0.isVolume || isReadOnlyCopy($0.url) || !TagStore.canTag($0, copies: services.copies) }
        if tagField.currentEditor() != nil, !sameItems || !taggable {
            tagField.commit()
            view.window?.makeFirstResponder(nil)
        }
        tagsCard.isHidden = !taggable
        tagField.undo = view.window?.undoManager
        tagField.errorWindow = view.window
        if !sameItems {
            tagField.urls = items.map(\.url)
        } else if tagField.currentEditor() == nil {
            tagField.reload()
        }
    }

    /// Get Info's settings: one real item (not a disk, a link, or a temporary copy inside an archive).
    private func updateInfoCards(of items: [FileEntry]) {
        let editable = items.count == 1 && !items[0].isVolume && !items[0].isSymlink && !isReadOnlyCopy(items[0].url)
        if editable { infoEditor.show(items[0]) } else { infoEditor.hide() }
        commentsCard.isHidden = !editable
        openWithCard.isHidden = !editable || !infoEditor.hasOpenWith
        permissionsCard.isHidden = !editable
    }

    private func showNothing() {
        titleLabel.stringValue = ""
        subtitleLabel.stringValue = ""
        setRows([])
        hidePreview()
        iconView.isHidden = true
    }

    private func hidePreview() {
        previewWork?.cancel()
        previewingContent = false
        removeRichPreview()
        preview.clear()
        preview.isHidden = true
    }

    /// Several items: how many folders and files, and their total size as far as it's known.
    private func showSelection(_ items: [FileEntry], sameItems: Bool, folderSize: (URL) -> FolderSize?, canMeasure: (FileEntry) -> Bool) {
        titleLabel.stringValue = String(localized: "\(items.count) items", comment: "plural")
        if !sameItems {
            subtitleLabel.stringValue = String(localized: "Calculating…")
            setRows([(Self.allocatedSizeTitle, InspectorRows.text("—")), (Self.logicalSizeTitle, InspectorRows.text("—"))])
        }
        var facts: [URL: InspectorSelectionSizes.Folder] = [:]
        for item in items where item.isDirectory {
            let copy = services.copies.contains(item.url)
            let size = copy ? nil : folderSize(item.url)
            let unmeasured = size == nil && (copy || !canMeasure(item) || item.isSymlink || item.isVolume
                || Privacy.measuringWouldPrompt(item.url, browsing: item.url.deletingLastPathComponent()))
            facts[item.url] = InspectorSelectionSizes.Folder(size: size, unmeasured: unmeasured)
        }
        let read = readSelectionSizes, copies = services.copies
        selectionSizesTask = Task { [weak self] in
            let size = await read(items, facts, copies)
            guard let self, !Task.isCancelled else { return }
            selectionSizesTask = nil
            if let size { showSelectionSizes(size, count: items.count) }
        }
    }

    private func showSelectionSizes(_ size: InspectorSelectionSizes, count: Int) {
        subtitleLabel.stringValue = size.supportsAllocation
            ? allocationText(size.allocated, complete: size.allocationComplete)
            : Format.bytes(size.logical) + (size.pending || size.unmeasured > 0 ? "+" : "")
        let totalText = size.pending ? String(localized: "\(Format.bytes(size.logical)) (calculating…)", comment: "Inspector: a total size still being worked out")
            : size.unmeasured > 0 ? String(localized: "\(Format.bytes(size.logical)) (\(size.unmeasured) folders not measured)", comment: "plural")
            : Format.bytes(size.logical)
        var rows: [(String, NSView)] = [
            (Self.logicalSizeTitle, InspectorRows.text(totalText)),
            (String(localized: "Folders", comment: "Inspector row: how many folders are selected"), InspectorRows.text(size.folders.formatted())),
            (String(localized: "Files", comment: "Inspector row: how many files are selected"), InspectorRows.text((count - size.folders).formatted())),
        ]
        if size.supportsAllocation { rows.insert((Self.allocatedSizeTitle, allocatedRow(allocationText(size.allocated, complete: size.allocationComplete))), at: 0) }
        setRows(rows)
    }

    /// Where an item appears to be, since things are described there: inside an archive opened as a folder, in a
    /// container's files or on a server, rather than in Strata's copy of them.
    private struct Placement {
        let apparent: URL?
        let container: (source: ContainerSource, top: URL)?
        let containerPath: String?
        let server: (server: RemoteServer, top: URL)?
        let serverPath: String?
    }

    private func placement(of url: URL) -> Placement {
        let container = services.copies.containerCopies.copy(containing: url)
        let server = services.remote.copies.server(containing: url)
        return Placement(apparent: ArchiveCache.apparentURL(url), container: container,
                         containerPath: container.flatMap { ContainerCopies.containerPath(of: url, top: $0.top) },
                         server: server, serverPath: server.flatMap { RemoteCopies.remotePath(of: url, top: $0.top) })
    }

    private func showSingleItem(_ entry: FileEntry, folderSize: (URL) -> FolderSize?, canMeasure: (FileEntry) -> Bool) {
        let place = placement(of: entry.url)
        let isCopy = services.copies.contains(entry.url)
        titleLabel.stringValue = title(of: entry, place: place)
        let directorySize = entry.isDirectory && !isCopy ? folderSize(entry.url) : nil
        let allocated = entry.isDirectory && !entry.isSymlink ? directorySize?.allocatedBytes : entry.allocatedSize
        let allocation = allocationText(allocated, complete: directorySize?.allocationComplete != false)
        let size = isCopy || place.apparent != nil
            ? (entry.isDirectory ? directorySize.map { Format.bytes($0.bytes) } : entry.size.map(Format.bytes))
            : (allocated == nil ? nil : allocation)
        subtitleLabel.stringValue = [entry.kind, size].compactMap { $0 }.joined(separator: " · ")
        var rows: [(String, NSView)] = []
        if !isCopy, place.apparent == nil {
            rows.append((Self.allocatedSizeTitle, allocatedRow(allocation)))
        }
        if let logical = sizeRow(entry, directorySize: directorySize, isCopy: isCopy, canMeasure: canMeasure) { rows.append(logical) }
        if let dimensions = imageDimensions(entry, at: rows.count) {
            rows.append((Self.dimensionsTitle, InspectorRows.text(dimensions)))
        }
        rows += dateRows(entry, isCopy: isCopy)
        if let row = whereRow(entry, place: place, isCopy: isCopy) {
            rows.append(row)
        }
        if let cloud = services.cloud.status(for: entry.url) {
            rows.append((String(localized: "Cloud", comment: "Inspector row: iCloud or File Provider download status"), InspectorRows.text(cloud.label)))
        }
        setRows(rows)
    }

    private func title(of entry: FileEntry, place: Placement) -> String {
        place.serverPath == "/" ? place.server?.server.name ?? entry.displayName
            : place.containerPath == "/" ? place.container?.source.name ?? entry.displayName
            : services.copies.containerCopies.engineFolder(entry.url) != nil ? Places.displayName(entry.url, copies: services.copies, names: services.folderNames)
            : place.apparent.map { Places.displayName($0, copies: services.copies, names: services.folderNames) } ?? entry.displayName
    }

    private func sizeRow(_ entry: FileEntry, directorySize: FolderSize?, isCopy: Bool,
                         canMeasure: (FileEntry) -> Bool) -> (String, NSView)? {
        let sizeTitle = Self.logicalSizeTitle
        if entry.isDirectory {
            if let size = directorySize {
                let files = String(localized: "\(size.files) files", comment: "plural")
                return (sizeTitle, InspectorRows.text("\(Format.bytes(size.bytes)) · \(files)"))
            } else if !isCopy, canMeasure(entry) {
                return (sizeTitle, InspectorRows.text(String(localized: "Calculating…")))
            } else if entry.isVolume || entry.isSymlink || isCopy {
                return (sizeTitle, InspectorRows.text("—"))
            } else {
                return (sizeTitle, InspectorRows.text(String(localized: "Needs Full Disk Access", comment: "Inspector: a folder’s size can’t be measured without Full Disk Access")))
            }
        } else if let bytes = entry.size {
            // The exact byte count only adds information once the size is rounded to KB or more.
            return (sizeTitle, InspectorRows.text(bytes < 1000 ? Format.bytes(bytes)
                : String(localized: "\(Format.bytes(bytes)) (\(Int(bytes)) bytes)", comment: "plural")))
        }
        return nil
    }

    /// A container's or a server's files have their modification dates; created and added would be the copy's.
    private func dateRows(_ entry: FileEntry, isCopy: Bool) -> [(String, NSView)] {
        var rows: [(String, NSView)] = []
        if !isCopy {
            rows.append((String(localized: "Created", comment: "Inspector row: creation date"), InspectorRows.text(Format.longDate(entry.created))))
        }
        rows.append((String(localized: "Modified", comment: "Inspector row: last modification date"), InspectorRows.text(Format.longDate(entry.modified))))
        if !isCopy, let added = entry.added {
            rows.append((String(localized: "Added", comment: "Inspector row: date the item was added to its folder"), InspectorRows.text(Format.longDate(added))))
        }
        return rows
    }

    /// Where: the folder by name (and its path on one line); clicking shows it with the item selected. Inside an
    /// archive opened as a folder, it's where the item appears to be; the archive's own top is the archive, in
    /// the archive's folder.
    private func whereRow(_ entry: FileEntry, place: Placement, isCopy: Bool) -> (String, NSView)? {
        let target: (folder: URL, item: URL)
        if let (archive, top) = ArchiveCache.archive(containing: entry.url), top.lexicallyStandardized == entry.url.lexicallyStandardized {
            target = (archive.deletingLastPathComponent(), archive)
        } else {
            target = (entry.url.deletingLastPathComponent(), entry.url)
        }
        let shownFolder = (place.apparent ?? entry.url).deletingLastPathComponent()
        let inCopy = copyLocation(place)
        looks.keep(only: [target.folder, shownFolder])
        guard !isCopy || inCopy != nil else { return nil }
        return (String(localized: "Where", comment: "Inspector row: the folder the item is in"),
                InspectorLocationView(folder: target.folder, shownAs: shownFolder, name: inCopy?.name,
                                      location: inCopy?.location,
                                      locationLeadsHere: inCopy?.leadsHere ?? true, looks: looks) { [weak self] in
                    self?.onShowFolder?(target.folder, target.item)
                })
    }

    /// In a container's files: the folder in the container ("web:/etc"), not Strata's copy of it; at the top, the
    /// container's name with its engine under it. On a server: the folder there ("web-1:/srv/app"); at the top, the
    /// server's name with its address.
    private func copyLocation(_ place: Placement) -> (name: String, location: String, leadsHere: Bool)? {
        place.container.flatMap { copy in
            guard let path = place.containerPath, path != "/" else { return nil }
            let folder = (path as NSString).deletingLastPathComponent
            return folder == "/" ? (copy.source.name, copy.source.engineName, false)
                : ((folder as NSString).lastPathComponent, "\(copy.source.name):" + ((folder as NSString).deletingLastPathComponent), true)
        } ?? place.server.flatMap { copy in
            guard let path = place.serverPath, path != "/" else { return nil }
            let folder = RemotePath.parent(path)
            return folder == "/" ? (copy.server.name, copy.server.address, false)
                : (RemotePath.name(folder), "\(copy.server.name):" + RemotePath.parent(folder), true)
        }
    }

    private func schedulePreview(_ entry: FileEntry) {
        previewWork?.cancel()
        removeRichPreview()
        preview.clear()
        previewingContent = canPreview(entry)
        showIcons(of: [entry])
        iconView.isHidden = false
        preview.isHidden = true
        guard previewingContent else { return }
        // Arrowing through a folder shouldn't render every file; wait for the selection to settle.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shownURLs == [entry.url] else { return }
                // A container's file not fetched yet: its icon until it arrives.
                guard self.canPreview(entry) else {
                    self.previewingContent = false
                    return
                }
                self.previewingContent = true
                if !entry.isDirectory, let rich = RichPreview.makeView(for: entry.url, contentType: entry.contentType, preferences: self.services.preferences, fallback: { [weak self] in
                    guard let self, self.shownURLs == [entry.url], self.canPreview(entry) else { return }
                    self.removeRichPreview()
                    self.showQuickLook(entry.url)
                }) {
                    self.showRich(rich)
                } else {
                    self.showQuickLook(entry.url)
                }
            }
        }
        previewWork = work
        previewScheduler(work)
    }

    private func showQuickLook(_ url: URL) {
        guard preview.show(url) else { return }
        preview.isHidden = false
        iconView.isHidden = true
    }

    /// Code and tables need more room than a thumbnail.
    private func showRich(_ rich: NSView) {
        rich.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(rich, positioned: .above, relativeTo: richBackdrop)
        NSLayoutConstraint.activate(rich.fillingConstraints(in: previewBox))
        richPreview = rich
        richBackdrop.isHidden = false
        previewHeight?.constant = 340
        preview.clear()
        preview.isHidden = true
        iconView.isHidden = true
    }

    /// Dropping the view also cancels its loading.
    private func removeRichPreview() {
        richPreview?.removeFromSuperview()
        richPreview = nil
        richBackdrop.isHidden = true
        previewHeight?.constant = 230
    }

    // MARK: - Project section

    /// Loads the project section for `url` (nil hides it). The same folder isn't reloaded unless `force`; a forced
    /// reload keeps the current section on screen until the new data arrives.
    private func loadProject(_ url: URL?, force: Bool = false) {
        let same = url?.lexicallyStandardized.path == projectFolder?.lexicallyStandardized.path
        guard !same || force else { return }
        projectFolder = url
        projectTask?.cancel()
        if !same { showProject(nil) }
        guard let url else { return }
        projectTask = Task { [weak self, git = services.git] in
            let info = await ProjectInfo.load(for: url, store: git) { partial in
                guard !Task.isCancelled, let self, self.projectFolder == url else { return }
                self.showProject(partial)
            }
            guard let self, !Task.isCancelled, self.projectFolder == url else { return }
            self.showProject(info)
        }
    }

    private func showProject(_ info: ProjectInfo?) {
        projectView.configure(info)
        projectView.isHidden = info == nil
    }

    private func reloadProject() {
        loadProject(projectFolder, force: true)
    }

    /// A repository's status changed: refresh the git part only (no rescans).
    func gitStatusChanged(_ notification: Notification) {
        guard let info = projectView.info, let root = notification.userInfo?["root"] as? URL else { return }
        let path = info.folder.lexicallyStandardized.path
        guard path == root.path || path.hasPrefix(root.path + "/") else { return }
        projectView.configure(info.withCurrentGit(store: services.git))
    }

    private func setRows(_ rows: [(String, NSView)]) {
        infoRows.set(rows)
        infoCard.isHidden = rows.isEmpty
    }

    private func allocatedRow(_ text: String) -> NSTextField {
        let row = InspectorRows.text(text)
        row.toolTip = DiskSizeMeasurement.partialExplanation
        return row
    }

    private func allocationText(_ bytes: Int64?, complete: Bool) -> String {
        bytes.map { Format.bytes($0) + (complete ? "" : "+") } ?? "—"
    }

    private static let logicalSizeTitle = String(localized: "Logical size", comment: "Inspector row: file lengths before compression, sparse allocation or shared storage")
    private static let allocatedSizeTitle = String(localized: "Size on disk", comment: "Inspector: space allocated to the item’s files")
    private static let dimensionsTitle = String(localized: "Dimensions",
                                                comment: "Inspector row: an image’s width × height in pixels")

    /// An image's size once read; until then it's read away from the main thread and joins the rows at `index`.
    private func imageDimensions(_ entry: FileEntry, at index: Int) -> String? {
        dimensionsTask?.cancel()
        dimensionsTask = nil
        guard canPreview(entry), entry.contentType?.conforms(to: .image) == true else { return nil }
        let key = "\(entry.url.path)|\(entry.modified?.timeIntervalSinceReferenceDate ?? 0)"
        if let dimensions, dimensions.key == key { return dimensions.text }
        let url = entry.url
        dimensionsTask = Task { [weak self] in
            let text = await Self.readDimensions(url)
            guard !Task.isCancelled, let self, self.shownURLs == [url] else { return }
            self.dimensions = (key, text)
            guard let text, index <= self.infoRows.shown.count else { return }
            var rows = self.infoRows.shown.map { ($0.title, $0.value) }
            rows.insert((Self.dimensionsTitle, InspectorRows.text(text)), at: index)
            self.setRows(rows)
        }
        return nil
    }

    @concurrent private static func readDimensions(_ url: URL) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }

    /// Up to three icons fanned out, like a stack of the selected files.
    private func stackedIcons(_ items: [FileEntry]) -> NSImage {
        let icons = items.prefix(3).map { services.thumbnails.icon(for: $0) }
        let size = NSSize(width: 160, height: 160)
        return NSImage(size: size, flipped: false) { _ in
            let angles: [CGFloat] = icons.count == 1 ? [0] : icons.count == 2 ? [-7, 6] : [-10, 0, 9]
            for (icon, angle) in zip(icons, angles) {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: size.width / 2, yBy: size.height / 2)
                transform.rotate(byDegrees: angle)
                transform.concat()
                icon.draw(in: NSRect(x: -60, y: -60, width: 120, height: 120))
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
