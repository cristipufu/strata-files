import AppKit

/// What a pane shows. Searches and Recents are places in the history like folders.
enum Destination: Equatable {
    case folder(URL)
    case search(String, scope: URL?)
    case recents
    case duplicates
}

/// One side of a window: a browser with its own place and back/forward history.
final class Pane {
    let browser: BrowserViewController
    var destination: Destination {
        didSet {
            opening.cancel()
            guard destination != oldValue else { return }
            navigationRevision += 1
            browser.cancelPendingActions()
            host.pathBar.cancelEditing()
        }
    }
    private(set) var navigationRevision = 0
    let opening = FolderOpenSession()
    /// The current folder, or the last one shown before a search or Recents.
    var location: URL
    var history = PaneHistory()
    /// The drag whose spring-loading last moved this pane: the rest of that dive adds no Back steps.
    var springDrag: Int?
    /// The folder on show, for the Inspector when nothing's selected; read away from the main thread.
    private(set) var folderEntry: FileEntry?
    private var folderEntryRead: Task<Void, Never>?
    /// In column view, the folder of the focused column (deeper than `location`).
    var columnLocation: URL?
    lazy var search = PaneSearch(pane: self, services: browser.services)
    /// A workspace folder this pane is kept for until its share or disk is connected (it shows Home meanwhile).
    /// Going anywhere else lets it go.
    var waiting: WaitingFolder?
    let host: PaneHostViewController

    init(location: URL, services: BrowserServices) {
        browser = BrowserViewController(services: services)
        self.location = location.standardizedFileURL
        destination = .folder(self.location)
        host = PaneHostViewController(browser: browser)
    }

    /// Stops what the pane is doing in the background (duplicate hashing, a folder scan): its window or the pane is
    /// closing.
    func stopBackgroundWork() {
        opening.cancel()
        host.pathBar.cancelEditing()
        browser.stopBackgroundWork()
        folderEntryRead?.cancel()
        search.stop()
    }

    /// Reads `url`'s entry for `folderEntry`, then `shown`; going elsewhere first drops it.
    func readFolderEntry(_ url: URL, then shown: @escaping () -> Void) {
        folderEntryRead?.cancel()
        folderEntry = nil
        folderEntryRead = Task { [weak self] in
            let entry = await FileEntry.read(url)
            guard !Task.isCancelled, let self else { return }
            folderEntry = entry
            folderEntryRead = nil
            shown()
        }
    }

    /// Short description for the pane header.
    var title: (text: String, symbol: String) {
        switch destination {
        case .folder(let url):
            let shown = (browser.mode == .columns ? columnLocation : nil) ?? url
            let name = Places.displayName(shown, copies: browser.services.copies, names: browser.services.folderNames)
            return (name, Trash.isTrash(shown) ? "trash" : "folder")
        case .search(let text, _): return (BrowserWindowController.searchTitle(text), "magnifyingglass")
        case .recents: return (String(localized: "Recents", comment: "Title of the view listing recently used files"), "clock")
        case .duplicates: return (String(localized: "Duplicates", comment: "Title of the view listing duplicate files"), "square.on.square")
        }
    }
}

/// A pane's browser plus, in dual-pane mode, a slim header that shows where it is and whether it has focus.
final class PaneHostViewController: NSViewController {
    let browser: BrowserViewController
    let pathBar: PathBar
    var onActivate: (() -> Void)?
    private let header: PaneHeaderView
    private let status = NSTextField(labelWithString: "")
    private let statusBar = NSView()
    private var underToolbar: NSLayoutConstraint?
    private var underHeader: NSLayoutConstraint?
    private var aboveBottom: NSLayoutConstraint?
    private var aboveStatus: NSLayoutConstraint?

    init(browser: BrowserViewController) {
        self.browser = browser
        let services = browser.services
        pathBar = PathBar(preferences: services.preferences, places: services.places, index: services.index, copies: services.copies,
                          names: services.folderNames, clipboard: services.clipboard,
                          embedded: true)
        header = PaneHeaderView(pathBar: pathBar)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        ThemeStyle.bind(root, to: .content)
        ThemeStyle.bind(header, to: .content)
        ThemeStyle.bind(statusBar, to: .content)
        addChild(browser)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.isHidden = true
        header.onClick = { [weak self] in self?.onActivate?() }
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        browser.view.clipsToBounds = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false
        // Spanning the pane, the status line mustn't size it (dragging the divider between panes): below the panes'
        // holding priority (250), it neither holds the pane wider nor pulls it narrower (a label hugs its text at 251).
        status.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        status.setContentHuggingPriority(.init(200), for: .horizontal)
        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.isHidden = true
        statusBar.addSubview(hairline)
        statusBar.addSubview(status)
        root.addSubview(browser.view)
        root.addSubview(header)
        root.addSubview(statusBar)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            browser.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            hairline.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: statusBar.topAnchor),
            status.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
        ])
        aboveBottom = browser.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        aboveStatus = browser.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        aboveBottom?.isActive = true
        // Clip scrolling files below the toolbar instead of letting them show through gaps in its native glass.
        underToolbar = browser.view.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        underHeader = browser.view.topAnchor.constraint(equalTo: header.bottomAnchor)
        underToolbar?.isActive = true
        view = root
    }

    /// A per-pane status line (dual-pane mode), or nil to hide it.
    func setStatus(_ text: String?) {
        loadViewIfNeeded()
        status.stringValue = text ?? ""
        statusBar.isHidden = text == nil
        hold(text == nil ? aboveBottom : aboveStatus, over: text == nil ? aboveStatus : aboveBottom)
    }

    func setHeader(visible: Bool, title: String, symbol: String, active: Bool, showsPathBar: Bool = false) {
        loadViewIfNeeded()
        header.isHidden = !visible
        header.configure(title: title, symbol: symbol, active: active, showsPathBar: showsPathBar)
        hold(visible ? underHeader : underToolbar, over: visible ? underToolbar : underHeader)
    }

    /// Switches from one of two contradicting constraints to the other, letting go of the old one first: with both
    /// active for a moment, Auto Layout breaks one of the bar's own constraints to recover.
    private func hold(_ on: NSLayoutConstraint?, over off: NSLayoutConstraint?) {
        off?.isActive = false
        on?.isActive = true
    }
}

private final class PaneHeaderView: NSVisualEffectView, ColorThemeUpdating {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let pathBar: PathBar
    private let underline = NSView()

    init(pathBar: PathBar) {
        self.pathBar = pathBar
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        // A long folder name truncates instead of holding the pane (and the window) wider; the header is laid out even
        // while hidden.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathBar.isHidden = true
        underline.wantsLayer = true
        for view in [icon, label, pathBar, underline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pathBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pathBar.topAnchor.constraint(equalTo: topAnchor),
            pathBar.bottomAnchor.constraint(equalTo: underline.topAnchor),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, symbol: String, active: Bool, showsPathBar: Bool) {
        label.stringValue = title
        setAccessibilityElement(!showsPathBar)
        setAccessibilityRole(.button)
        setAccessibilityLabel(active ? String(localized: "\(title), focused pane", comment: "Accessibility: the pane header; where the pane is")
                                     : String(localized: "\(title), pane", comment: "Accessibility: the pane header; where the pane is"))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.textColor = active ? .labelColor : .secondaryLabelColor
        icon.contentTintColor = active ? ThemeStyle.accent : .tertiaryLabelColor
        icon.isHidden = showsPathBar
        label.isHidden = showsPathBar
        pathBar.isHidden = !showsPathBar
        if !showsPathBar, pathBar.isEditing { pathBar.cancelEditing() }
        pathBar.alphaValue = active || pathBar.isEditing ? 1 : 0.75
        isActive = active
        updateUnderline()
    }

    private var isActive = false

    private func updateUnderline() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            underline.layer?.backgroundColor = isActive ? ThemeStyle.accent.cgColor : NSColor.separatorColor.cgColor
        }
    }

    func updateColorTheme() {
        icon.contentTintColor = isActive ? ThemeStyle.accent : .tertiaryLabelColor
        updateUnderline()
    }

    /// Light or dark changed: the line's color is worked out again (a layer keeps the old one).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateUnderline()
    }

    override func mouseDown(with event: NSEvent) {
        if !pathBar.isHidden {
            pathBar.onActivate?()
            pathBar.beginEditing()
        } else {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Holds one or two panes side by side.
final class PaneContainerViewController: NSSplitViewController {
    init(first: PaneHostViewController) {
        super.init(nibName: nil, bundle: nil)
        splitView = PaneSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        add(first)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func add(_ host: PaneHostViewController) {
        let item = NSSplitViewItem(viewController: host)
        item.minimumThickness = 300
        addSplitViewItem(item)
        // A new second pane starts as an even split, not squeezed to its minimum width.
        guard splitViewItems.count == 2 else { return }
        DispatchQueue.main.async { [weak self] in
            // The pane may have been closed again before this runs.
            guard let self, splitViewItems.count == 2 else { return }
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
        }
    }

    func remove(_ host: PaneHostViewController) {
        guard let item = splitViewItems.first(where: { $0.viewController === host }) else { return }
        removeSplitViewItem(item)
    }
}

/// The line between the panes stays below the toolbar and above the shared status bar.
private final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { .separatorColor }

    override func drawDivider(in rect: NSRect) {
        let line = rect.intersection(safeAreaRect)
        guard !line.isEmpty else { return }
        super.drawDivider(in: line)
    }

    /// The toolbar, search bar and status bar can change either end of the line.
    private var drawnArea: NSRect?

    override func layout() {
        super.layout()
        guard drawnArea != safeAreaRect else { return }
        drawnArea = safeAreaRect
        needsDisplay = true
    }
}
