import AppKit

/// A floating shelf: drop files from anywhere, then drag them all out at once or move/copy them into the current
/// folder. Handy for gathering files from several places.
final class ShelfPanel: NSPanel {
    static let shared = ShelfPanel()

    private let well = ShelfWell()

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 210),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        title = String(localized: "Shelf", comment: "Window title: the floating shelf for gathering files")
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        setFrameAutosaveName("StrataShelf")

        let glass = NSGlassEffectView()
        glass.cornerRadius = 16
        well.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(well)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            well.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            well.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            well.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        glass.contentView = container
        contentView = glass
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            if frame.origin == .zero, let screen = NSScreen.main {
                setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 24, y: screen.visibleFrame.midY))
            }
            orderFront(nil)
        }
    }

    func add(_ urls: [URL]) {
        well.add(urls)
        if !isVisible { toggle() }
    }
}

final class ShelfWell: NSView, NSDraggingSource {
    private(set) var items: [URL] = []
    /// Each item's icon, and theirs together, as last read.
    private var icons: [URL: NSImage] = [:]
    private var together: NSImage?
    /// Reading which items are still there, and their icons.
    private(set) var checking: Task<Void, Never>?
    var activeWindow: () -> BrowserWindowController? = {
        NSApp.orderedWindows.compactMap({ $0.windowController as? BrowserWindowController }).first
    }
    let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(FileDrop.types)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        func button(_ localizedTitle: String.LocalizationValue, _ symbol: String, _ action: Selector) -> NSButton {
            let title = String(localized: localizedTitle)
            let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.imagePosition = .imageOnly
            button.toolTip = title
            return button
        }
        buttons.setViews([
            button("Copy into Current Folder", "plus.square.on.square", #selector(copyHere)),
            button("Move into Current Folder", "arrow.right.doc.on.clipboard", #selector(moveHere)),
            button("Clear Shelf", "xmark.circle", #selector(clear)),
        ], in: .center)
        buttons.spacing = 6
        for view in [iconView, label, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 76),
            iconView.heightAnchor.constraint(equalToConstant: 76),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.path))
        items += urls.filter { !known.contains($0.path) }
        refresh()
    }

    /// Shows the items, then reads which are still there and what they look like now, and shows that.
    private func refresh() {
        show()
        checking?.cancel()
        checking = nil
        let urls = items
        guard !urls.isEmpty else { return }
        checking = Task { [weak self] in
            let there = await Self.there(urls)
            var icons: [URL: NSImage] = [:]
            for url in there { icons[url] = await IconCache.shared.currentIcon(forPath: url.path) }
            let together = there.count > 1 ? await IconCache.shared.currentIcon(forPaths: there.map(\.path)) : nil
            guard let self, !Task.isCancelled else { return }
            checking = nil
            let gone = Set(urls).subtracting(there)
            items.removeAll(where: gone.contains)
            self.icons = icons
            self.together = together
            show()
        }
    }

    nonisolated private static func there(_ urls: [URL]) async -> [URL] {
        await OwnThread.run {
            urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func show() {
        let wasEmpty = buttons.isHidden
        buttons.isHidden = items.isEmpty
        if items.isEmpty {
            iconView.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 34, weight: .light))
            iconView.contentTintColor = .tertiaryLabelColor
            label.stringValue = String(localized: "Drop files here")
        } else {
            // Until they're read, the items' icon shown before, or a document's.
            if let read = items.count == 1 ? icons[items[0]] : together {
                iconView.image = read
            } else if wasEmpty {
                iconView.image = NSWorkspace.shared.icon(for: .item)
            }
            iconView.contentTintColor = nil
            label.stringValue = items.count == 1 ? items[0].lastPathComponent
                : String(localized: "\(items.count) items · drag out to drop them all", comment: "plural")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.lineWidth = 1.5
        (highlighted ? ThemeStyle.accent : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
        if highlighted {
            ThemeStyle.accent.withAlphaComponent(0.08).setFill()
            path.fill()
        }
    }

    // MARK: Drop in

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? ShelfWell !== self else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        return acceptDrop(sender.draggingPasteboard)
    }

    func acceptDrop(_ pasteboard: NSPasteboard) -> Bool {
        let copies = activeWindow()?.services.copies ?? .live
        let urls = FileDrop.urls(pasteboard, copies: copies)
        add(urls)
        return !urls.isEmpty
    }

    // MARK: Drag out

    func pasteboardWriters() -> [any NSPasteboardWriting] {
        let copies = activeWindow()?.services.copies ?? .live
        return items.map { ContainerDragItem.writer(for: $0, copies: copies) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !items.isEmpty else { return }
        let draggingItems = zip(items.indices, zip(items, pasteboardWriters())).map { index, pair -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: pair.1)
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(iconView.frame.offsetBy(dx: offset, dy: -offset), contents: icons[pair.0] ?? iconView.image)
            return item
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        sourceMask(session.draggingPasteboard)
    }

    func sourceMask(_ pasteboard: NSPasteboard) -> NSDragOperation {
        let copies = activeWindow()?.services.copies ?? .live
        return FileDrop.sourceMask([.copy, .move, .generic], pasteboard, copies: copies)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Items that were moved somewhere else leave the shelf.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    // MARK: Actions

    func transfer(move: Bool) {
        guard let controller = activeWindow(), case .folder = controller.destination,
              let target = controller.browser.targetDirectory else { return }
        let urls = items
        // Onto a server: copied there through the server (what's on the Shelf stays).
        if controller.services.remote.copies.contains(target) {
            return controller.browser.copyToServer(urls, into: target, move: false)
        }
        guard !ReadOnlyCopies.contains(target, copies: controller.services.copies), !Trash.isTrash(target) else { return }
        let job = controller.services.transfers.enqueue(urls, to: target, mode: move ? .move : .copy,
                                               undo: controller.window?.undoManager, conflicts: .sheet(for: controller.window))
        job.onFinish = { [weak self] job in
            if move {
                let moved = Set(job.completedMoves.map { $0.from.standardizedFileURL })
                self?.items.removeAll { moved.contains($0.standardizedFileURL) }
            }
            self?.refresh()
        }
    }

    @objc private func copyHere() { transfer(move: false) }
    @objc private func moveHere() { transfer(move: true) }

    @objc private func clear() {
        items.removeAll()
        refresh()
    }
}
