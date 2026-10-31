import AppKit
import StrataModel
import StrataTheme

// MARK: - Strip

/// Document view holding the columns side by side.
final class ColumnStripView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Folder column scroll & table views

/// Folder rows scroll vertically; a sideways gesture belongs to the strip containing all the columns.
final class ColumnScrollView: NSScrollView {
    private var horizontalGesture: Bool?

    override func scrollWheel(with event: NSEvent) {
        guard let strip = superview?.enclosingScrollView else { return super.scrollWheel(with: event) }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin)
            || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            horizontalGesture = nil
        }
        if horizontalGesture == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            horizontalGesture = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        if horizontalGesture == true {
            strip.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
        // Keep the direction through the zero-delta end event and any following momentum.
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
            horizontalGesture = nil
        }
    }
}

/// Column table: arrows move between columns, typing filters the first column (type-select elsewhere),
/// Return/Space/Escape go to the browser like the list.
final class ColumnTableView: NSTableView {
    weak var pane: ColumnPane?
    private let clickToRename = ClickToRename()
    private let copies: CopyProviders

    init(copies: CopyProviders) {
        self.copies = copies
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let url = ClickToRename.nameRow(in: self, column: 0, for: event).flatMap { row in
            pane.flatMap { $0.entries.indices.contains(row) ? $0.entries[row].url : nil }
        }
        super.mouseDown(with: event)
        clickToRename.clicked(event, armed: url != nil, in: self) { [weak self] in
            guard let self, let url, let pane, window?.isKeyWindow == true, window?.firstResponder === self,
                  pane.selectedEntries.map(\.url) == [url] else { return }
            pane.renameClicked(url)
        }
    }

    override func keyDown(with event: NSEvent) {
        clickToRename.cancel()
        guard let pane else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = mods.isDisjoint(with: [.command, .control])
        switch event.keyCode {
        case KeyCode.leftArrow where plain && !mods.contains(.shift): pane.moveLeft(); return
        case KeyCode.rightArrow where plain && !mods.contains(.shift): pane.moveRight(); return
        default: break
        }
        if let key = FileViewKey.from(event) {
            if case .type = key {
                if pane.handleKey(key) { return }
            } else {
                if !pane.handleKey(key) { super.keyDown(with: event) }
                return
            }
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { pane?.becameFirstResponder() }
        return result
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        pane?.springLoader.cancel()
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        FileDrop.sourceMask(super.draggingSession(session, sourceOperationMaskFor: context), session, copies: copies)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // No super: NSTableView doesn't implement this optional NSDraggingDestination method, and calling it throws
        // inside the drag's completion, which leaves the app unable to start another drag.
        pane?.springLoader.cancel()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickToRename.cancel()
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        return pane?.contextMenu()
    }
}

/// The list's name cell (icon + highlighted name) with a disclosure chevron for folders.
final class ColumnCellView: NSTableCellView, ColorThemeUpdating {
    static let identifier = NSUserInterfaceItemIdentifier("ColumnCell")

    let nameCell = NameCellView()
    private let chevron = NSImageView()
    private var isFolder = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        nameCell.translatesAutoresizingMaskIntoConstraints = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.setAccessibilityElement(false)
        addSubview(nameCell)
        addSubview(chevron)
        textField = nameCell.textField
        imageView = nameCell.imageView
        // One line, truncated in the middle; the name cell's attributed text would otherwise wrap.
        if let label = nameCell.textField {
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.cell?.wraps = false
            label.cell?.truncatesLastVisibleLine = true
            label.lineBreakMode = .byTruncatingMiddle
        }
        NSLayoutConstraint.activate([
            nameCell.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameCell.topAnchor.constraint(equalTo: topAnchor),
            nameCell.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameCell.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: FileEntry, matches: [Int], dimmed: Bool, git: GitBadge? = nil, tags: [FinderTag] = [],
                   cloud: CloudStatus? = nil, scale: CGFloat = 2, preferences: Prefs, typography: FileViewTypography,
                   thumbnails: FileThumbnails) {
        isFolder = entry.isFolder
        nameCell.configure(name: entry.displayName, icon: thumbnails.icon(for: entry), matches: matches, dimmed: dimmed, git: git,
                           tags: tags, cloud: cloud, thumbnail: preferences.showIconPreviews ? entry : nil,
                           thumbnails: thumbnails, scale: scale, typography: typography)
        applyTruncation()
        chevron.isHidden = !entry.isFolder
        setAccessibilityLabel(entry.isFolder
            ? String(localized: "\(entry.displayName), folder", comment: "Accessibility label of a folder row; the placeholder is its name") : entry.displayName)
        updateChevron()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            nameCell.backgroundStyle = backgroundStyle
            applyTruncation()
            updateChevron()
        }
    }

    /// The name cell renders an attributed string without a paragraph style, which wraps; truncate in the middle
    /// instead so extensions stay visible in narrow columns.
    private func applyTruncation() {
        guard let label = nameCell.textField else { return }
        let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
        guard text.length > 0 else { return }
        text.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: text.length))
        label.attributedStringValue = text
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    private func updateChevron() {
        chevron.contentTintColor = backgroundStyle == .emphasized ? ThemeStyle.selectedText : .tertiaryLabelColor
    }

    func updateColorTheme() { updateChevron() }
}

/// The column's right edge: a hairline you can drag to resize (Option resizes all), double-click to fit.
final class ColumnDividerView: NSView {
    var onDrag: ((CGFloat, Bool, CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    var startWidth: (() -> CGFloat)?
    private var dragOrigin: CGFloat = 0
    private var widthAtStart: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragOrigin = event.locationInWindow.x
        widthAtStart = startWidth?() ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - dragOrigin, event.modifierFlags.contains(.option), widthAtStart)
    }
}
