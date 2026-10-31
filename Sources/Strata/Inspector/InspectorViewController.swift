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
    private var shownRows: [(String, NSView)] = []
    /// A native preview for code, Markdown, JSON, CSV, SQLite and archives; Quick Look covers everything else.
    private(set) var richPreview: NSView?
    private let richBackdrop = NSBox()
    private var previewHeight: NSLayoutConstraint?

    private let previewScheduler: (DispatchWorkItem) -> Void

    init(services: BrowserServices,
         previewScheduler: @escaping (DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: $0)
         }) {
        self.services = services
        tagPicker = TagPicker(listWhileEditing: true, maxRows: 6, tags: services.tags)
        self.containerView = ContainerInspectorView(preferences: services.preferences,
                                                    copies: services.copies.containerCopies,
                                                    store: services.containerStore)
        self.composeView = ComposeInspectorView(preferences: services.preferences,
                                                store: services.containerStore)
        self.projectView = ProjectInspectorView(files: services.files, git: services.git)
        self.previewScheduler = previewScheduler
        infoEditor = InfoEditor(readFacts: InfoEditor.Facts.read(_:opensWithApps:))
        super.init(nibName: nil, bundle: nil)
    }

    isolated deinit {
        previewWork?.cancel()
        projectTask?.cancel()
        dimensionsTask?.cancel()
        summary.url = nil
        infoEditor.hide()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func loadView() {
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

        projectView.isHidden = true
        projectView.onDidClean = { [weak self] _ in self?.reloadProject() }
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged(_:)), name: .tagsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(containerFilesFetched(_:)), name: .containerFilesFetched, object: nil)
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
        NotificationCenter.default.addObserver(self, selector: #selector(containersChanged), name: .containersChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(iconsLoaded(_:)), name: .iconsLoaded, object: nil)
        let cards: [NSView] = [containerView, infoCard, tagsCard, commentsCard, openWithCard, permissionsCard, summary, projectView, composeView]
        for card in [tagsCard, commentsCard, openWithCard, permissionsCard] as [NSView] { card.isHidden = true }
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
        view = scroll
    }

    /// The file shown arrived from its container: preview it now.
    @objc private func containerFilesFetched(_ notification: Notification) {
        guard shownURLs.count == 1, let urls = notification.object as? [URL],
              let shown = shownURLs.first, services.copies.contains(shown),
              urls.contains(where: { $0.standardizedFileURL.path == shown.standardizedFileURL.path }),
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
        ReadOnlyCopies.contains(url) || services.copies.contains(url)
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
              let changed = notification.object as? [URL], changed.contains(where: shownURLs.contains) else { return }
        tagField.reload()
    }

    /// Shows `entries`, or `folder` when the selection is empty. Calling again with the same items only refreshes metadata.
    func show(entries: [FileEntry], folder: FileEntry?, folderSize: (URL) -> FolderSize?, canMeasure: (FileEntry) -> Bool) {
        let items = entries.isEmpty ? [folder].compactMap { $0 } : entries
        // The project section follows a single selected folder, or the current folder when nothing is selected; never in
        // a read-only copy (a container's scripts are not this Mac's to run).
        let projectFolder = items.count == 1 && items[0].isFolder && !isReadOnlyCopy(items[0].url) && FileOps.canTrash(items[0].url, copies: services.copies) ? items[0].url : nil
        loadProject(projectFolder)
        composeFolder = projectFolder
        composeView.configure(projectFolder)
        containerView.configure(url: items.first?.url)
        updateSummary(for: items)
        let urls = items.map(\.url)
        let sameItems = urls == shownURLs
        shownURLs = urls
        // Volumes, links and archives opened as folders don't take tags. A refresh while you type leaves your typing alone.
        // Typing in the tag field belongs to the items it was opened on: a new selection (or a hidden field) ends it,
        // applying what was typed to those items.
        let taggable = !items.isEmpty
            && !items.contains { $0.isVolume || isReadOnlyCopy($0.url) || !TagStore.canTag($0) }
        if tagField.currentEditor() != nil, !sameItems || !taggable {
            tagField.commit()
            view.window?.makeFirstResponder(nil)
        }
        tagsCard.isHidden = !taggable
        tagField.undo = view.window?.undoManager
        tagField.errorWindow = view.window
        if !sameItems {
            tagField.urls = urls
        } else if tagField.currentEditor() == nil {
            tagField.reload()
        }

        // Get Info's settings: one real item (not a disk, a link, or a temporary copy inside an archive).
        let editable = items.count == 1 && !items[0].isVolume && !items[0].isSymlink && !isReadOnlyCopy(items[0].url)
        if editable { infoEditor.show(items[0]) } else { infoEditor.hide() }
        commentsCard.isHidden = !editable
        openWithCard.isHidden = !editable || !infoEditor.hasOpenWith
        permissionsCard.isHidden = !editable

        guard let first = items.first else {
            titleLabel.stringValue = ""
            subtitleLabel.stringValue = ""
            setRows([])
            previewWork?.cancel()
            previewingContent = false
            removeRichPreview()
            preview.clear()
            preview.isHidden = true
            iconView.isHidden = true
            return
        }

        if items.count == 1 {
            let entry = first
            showSingleItem(entry, folderSize: folderSize, canMeasure: canMeasure)
            let canShowPreview = canPreview(entry)
            if !sameItems || canShowPreview != previewingContent {
                schedulePreview(entry)
            }
        } else {
            titleLabel.stringValue = String(localized: "\(items.count) items", comment: "plural")
            let known = items.compactMap { item -> Int64? in
                guard item.isDirectory else { return item.size }
                return services.copies.contains(item.url) ? nil : folderSize(item.url)?.bytes
            }
            let total = known.saturatingSum
            // Symlinked folders, volumes, provider copies and folders macOS guards aren't measured: their size never
            // arrives, so they mustn't leave the total "calculating" forever.
            let unmeasured = items.filter { item in
                guard item.isDirectory else { return false }
                if services.copies.contains(item.url) { return true }
                guard folderSize(item.url) == nil else { return false }
                return !canMeasure(item) || item.isSymlink || item.isVolume
                    || Privacy.measuringWouldPrompt(item.url, browsing: item.url.deletingLastPathComponent())
            }.count
            let pending = known.count + unmeasured < items.count
            subtitleLabel.stringValue = Format.bytes(total) + (pending || unmeasured > 0 ? "+" : "")
            let folders = items.filter(\.isFolder).count
            let totalText = pending ? String(localized: "\(Format.bytes(total)) (calculating…)", comment: "Inspector: a total size still being worked out")
                : unmeasured > 0 ? String(localized: "\(Format.bytes(total)) (\(unmeasured) folders not measured)", comment: "plural")
                : Format.bytes(total)
            setRows([
                (String(localized: "Folders", comment: "Inspector row: how many folders are selected"), InspectorRows.text(folders.formatted())),
                (String(localized: "Files", comment: "Inspector row: how many files are selected"), InspectorRows.text((items.count - folders).formatted())),
                (String(localized: "Total", comment: "Inspector row: the selection’s total size"), InspectorRows.text(totalText)),
            ])
            if !sameItems {
                previewWork?.cancel()
                previewingContent = false
                removeRichPreview()
                preview.clear()
                preview.isHidden = true
                iconView.isHidden = false
                showIcons(of: items)
            }
        }
    }

    private func showSingleItem(_ entry: FileEntry, folderSize: (URL) -> FolderSize?, canMeasure: (FileEntry) -> Bool) {
        // Inside an archive opened as a folder, things are described where they appear: in the archive.
        let apparent = ArchiveCache.apparentURL(entry.url)
        let containerCopies = services.copies.containerCopies
        let container = containerCopies.copy(containing: entry.url)
        let containerPath = container.flatMap { ContainerCopies.containerPath(of: entry.url, top: $0.top) }
        let server = services.remote.copies.server(containing: entry.url)
        let serverPath = server.flatMap { RemoteCopies.remotePath(of: entry.url, top: $0.top) }
        let isCopy = services.copies.contains(entry.url)
        titleLabel.stringValue = serverPath == "/" ? server?.server.name ?? entry.displayName
            : containerPath == "/" ? container?.source.name ?? entry.displayName
            : containerCopies.engineFolder(entry.url) != nil ? Places.displayName(entry.url, copies: services.copies)
            : apparent.map { Places.displayName($0, copies: services.copies) } ?? entry.displayName
        let directorySize = entry.isDirectory && !isCopy ? folderSize(entry.url) : nil
        let size = entry.isDirectory ? directorySize.map { Format.bytes($0.bytes) } : entry.size.map(Format.bytes)
        subtitleLabel.stringValue = [entry.kind, size].compactMap { $0 }.joined(separator: " · ")
        var rows: [(String, NSView)] = []
        let sizeTitle = String(localized: "Size", comment: "Inspector row: how big the item is")
        if entry.isDirectory {
            if let size = directorySize {
                let files = String(localized: "\(size.files) files", comment: "plural")
                rows.append((sizeTitle, InspectorRows.text("\(Format.bytes(size.bytes)) · \(files)")))
            } else if !isCopy, canMeasure(entry) {
                rows.append((sizeTitle, InspectorRows.text(String(localized: "Calculating…"))))
            } else if entry.isVolume || entry.isSymlink || isCopy {
                rows.append((sizeTitle, InspectorRows.text("—")))
            } else {
                rows.append((sizeTitle, InspectorRows.text(String(localized: "Needs Full Disk Access", comment: "Inspector: a folder’s size can’t be measured without Full Disk Access"))))
            }
        } else if let bytes = entry.size {
            // The exact byte count only adds information once the size is rounded to KB or more.
            rows.append((sizeTitle, InspectorRows.text(bytes < 1000 ? Format.bytes(bytes)
                : String(localized: "\(Format.bytes(bytes)) (\(Int(bytes)) bytes)", comment: "plural"))))
        }
        if let dimensions = imageDimensions(entry, at: rows.count) {
            rows.append((Self.dimensionsTitle, InspectorRows.text(dimensions)))
        }
        // A container's or a server's files have their modification dates; created and added would be the copy's.
        if !isCopy {
            rows.append((String(localized: "Created", comment: "Inspector row: creation date"), InspectorRows.text(Format.longDate(entry.created))))
        }
        rows.append((String(localized: "Modified", comment: "Inspector row: last modification date"), InspectorRows.text(Format.longDate(entry.modified))))
        if !isCopy, let added = entry.added {
            rows.append((String(localized: "Added", comment: "Inspector row: date the item was added to its folder"), InspectorRows.text(Format.longDate(added))))
        }
        // Where: the folder by name (and its path on one line); clicking shows it with the item selected. Inside an
        // archive opened as a folder, it's where the item appears to be; the archive's own top is the archive, in
        // the archive's folder.
        let target: (folder: URL, item: URL)
        if let (archive, top) = ArchiveCache.archive(containing: entry.url), top.standardizedFileURL == entry.url.standardizedFileURL {
            target = (archive.deletingLastPathComponent(), archive)
        } else {
            target = (entry.url.deletingLastPathComponent(), entry.url)
        }
        let shownFolder = (apparent ?? entry.url).deletingLastPathComponent()
        // In a container's files: the folder in the container ("web:/etc"), not Strata's copy of it. At the top, the
        // container's name with its engine under it.
        let inContainer: (name: String, location: String, leadsHere: Bool)? = container.flatMap { copy in
            guard let path = containerPath, path != "/" else { return nil }
            let folder = (path as NSString).deletingLastPathComponent
            return folder == "/" ? (copy.source.name, copy.source.engineName, false)
                : ((folder as NSString).lastPathComponent, "\(copy.source.name):" + ((folder as NSString).deletingLastPathComponent), true)
        } ?? server.flatMap { copy in
            // On a server: the folder there ("web-1:/srv/app"); at the top, the server's name with its address.
            guard let path = serverPath, path != "/" else { return nil }
            let folder = RemotePath.parent(path)
            return folder == "/" ? (copy.server.name, copy.server.address, false)
                : (RemotePath.name(folder), "\(copy.server.name):" + RemotePath.parent(folder), true)
        }
        if !isCopy || inContainer != nil {
            rows.append((String(localized: "Where", comment: "Inspector row: the folder the item is in"),
                         InspectorLocationView(folder: target.folder, shownAs: shownFolder, name: inContainer?.name,
                                               location: inContainer?.location,
                                               locationLeadsHere: inContainer?.leadsHere ?? true) { [weak self] in
                             self?.onShowFolder?(target.folder, target.item)
                         }))
        }
        if let cloud = services.cloud.status(for: entry.url) {
            rows.append((String(localized: "Cloud", comment: "Inspector row: iCloud or File Provider download status"), InspectorRows.text(cloud.label)))
        }
        setRows(rows)
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
                if !entry.isDirectory, let rich = RichPreview.makeView(for: entry.url, contentType: entry.contentType, fallback: { [weak self] in
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
        NSLayoutConstraint.activate([
            rich.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            rich.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            rich.topAnchor.constraint(equalTo: previewBox.topAnchor),
            rich.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
        ])
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
        let same = url?.standardizedFileURL.path == projectFolder?.standardizedFileURL.path
        guard !same || force else { return }
        projectFolder = url
        projectTask?.cancel()
        if !same { showProject(nil) }
        guard let url else { return }
        projectTask = Task { [weak self] in
            let info = await ProjectInfo.load(for: url, store: .shared) { partial in
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
        let path = info.folder.standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path + "/") else { return }
        projectView.configure(info.withCurrentGit(store: .shared))
    }

    private func setRows(_ rows: [(String, NSView)]) {
        shownRows = rows
        infoRows.set(rows)
        infoCard.isHidden = rows.isEmpty
    }

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
            guard let text, index <= self.shownRows.count else { return }
            var rows = self.shownRows
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
