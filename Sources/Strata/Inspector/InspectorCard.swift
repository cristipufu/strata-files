import AppKit

/// One section of the Inspector: an icon, a title, an optional accessory and a chevron that collapses it
/// (remembered per section), with a hairline above. Every section looks and lines up the same way.
final class InspectorCard: NSView, ColorThemeUpdating {
    /// The card's content; it spans the card's width inside the padding.
    let content: NSView
    private let card = CardView()
    private let chevron = NSButton()
    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private let body = NSView()
    private let id: String
    private let preferences: Prefs
    private var bodyHeightWhenCollapsed: NSLayoutConstraint?
    private var contentBottom: NSLayoutConstraint?
    private var bodyTop: NSLayoutConstraint?

    static let padding: CGFloat = 12
    /// Side inset of a section's title and rows. Smaller than `padding` so a narrow inspector keeps room for values.
    static let horizontalPadding: CGFloat = 8

    init(id: String, title: String, symbol: String, content: NSView, accessory: NSView? = nil,
         preferences: Prefs) {
        self.id = id
        self.preferences = preferences
        self.content = content
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        icon.setAccessibilityElement(false)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityElement(false)

        chevron.isBordered = false
        chevron.bezelStyle = .accessoryBarAction
        chevron.imagePosition = .imageOnly
        chevron.contentTintColor = InspectorColors.tertiary
        chevron.target = self
        chevron.action = #selector(toggle)
        chevron.setAccessibilityLabel(title)

        var headerViews: [NSView] = [icon, titleLabel, NSView()]
        if let accessory {
            // A long accessory (an upstream branch, a size) gives way before the title does.
            accessory.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            headerViews.append(accessory)
        }
        headerViews.append(chevron)
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        // The whole header row collapses and expands, not just the chevron.
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggle))
        header.addGestureRecognizer(click)

        body.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        card.addSubview(header)
        card.addSubview(body)
        let pad = Self.padding
        let inset = Self.horizontalPadding
        let bottom = content.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        contentBottom = bottom
        let top = body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8)
        bodyTop = top
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset + 4),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            header.heightAnchor.constraint(equalToConstant: 20),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            top,
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            content.topAnchor.constraint(equalTo: body.topAnchor),
            bottom,
        ])
        bodyHeightWhenCollapsed = body.heightAnchor.constraint(equalToConstant: 0)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        apply(collapsed: isCollapsed, animated: false)
        updateColorTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateColorTheme() {
        let themed = ThemeStyle.options.palette != .system && !ThemeStyle.highContrast && !effectiveAppearance.isHighContrast
        let ink: NSColor = themed ? ThemeStyle.panelIcon : InspectorColors.secondary
        let symbol = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.symbolConfiguration = themed ? symbol : symbol.applying(.init(hierarchicalColor: ink))
        icon.contentTintColor = ink
        titleLabel.textColor = InspectorColors.primary
        chevron.contentTintColor = themed ? ThemeStyle.panelIcon : InspectorColors.tertiary
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorTheme()
    }

    private var defaultsKey: String { "inspector.collapsed." + id }

    var isCollapsed: Bool {
        get { preferences.defaults.bool(forKey: defaultsKey) }
        set {
            preferences.defaults.set(newValue, forKey: defaultsKey)
            apply(collapsed: newValue, animated: true)
        }
    }

    @objc private func toggle() {
        isCollapsed.toggle()
    }

    private func apply(collapsed: Bool, animated: Bool) {
        // Typing into a field that's being hidden would go on, unseen: editing ends first.
        if collapsed, let window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: content) {
            window.makeFirstResponder(nil)
        }
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.setAccessibilityValue(collapsed ? String(localized: "Collapsed") : String(localized: "Expanded"))
        // Collapsed: the body takes no room (its content stays laid out, just hidden). The constraint going away goes
        // first: for a moment both would ask for different heights, and AppKit reports the conflict.
        content.isHidden = collapsed
        let (off, on) = collapsed ? (contentBottom, bodyHeightWhenCollapsed) : (bodyHeightWhenCollapsed, contentBottom)
        off?.isActive = false
        on?.isActive = true
        bodyTop?.constant = collapsed ? 0 : 8
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                window?.layoutIfNeeded()
            }
        }
    }
}

/// Label–value rows with one label column, as every Inspector card lays them out.
final class InspectorRows: NSView {
    private let grid = NSGridView()
    static let labelWidth: CGFloat = 74
    /// What the grid shows: each row's title and value view.
    private(set) var shown: [(title: String, value: NSView)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Text rows: values wrap in full (long sizes) and can be selected and copied.
    func setText(_ rows: [(String, String)]) {
        set(rows.map { ($0, Self.text($1)) })
    }

    /// A value as text that wraps and can be selected.
    static func text(_ value: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: 12)
        field.textColor = InspectorColors.primary
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// Rows whose values are controls (pop-up menus, switches).
    func set(_ rows: [(String, NSView)]) {
        // The Inspector refreshes whenever files change; the same rows again only update their text, so the card isn't
        // torn down and laid out anew (and a selection in a value survives).
        if updateInPlace(rows) { return }
        shown = rows.map { (title: $0.0, value: $0.1) }
        // NSGridView.removeRow leaves the cell views behind, so remove them explicitly.
        while grid.numberOfRows > 0 {
            let row = grid.row(at: 0)
            for index in 0..<row.numberOfCells { row.cell(at: index).contentView?.removeFromSuperview() }
            grid.removeRow(at: 0)
        }
        // Empty columns left behind collapse to nothing, which the 74-point label column can't do: with no rows, that
        // contradicts the grid filling the card. addRow makes the columns again (set up below).
        while grid.numberOfColumns > 0 { grid.removeColumn(at: 0) }
        for (name, value) in rows {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12)
            label.textColor = InspectorColors.secondary
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = name
            grid.addRow(with: [label, value])
        }
        guard grid.numberOfColumns == 2 else { return }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).width = Self.labelWidth
        grid.column(at: 1).xPlacement = .fill
        // Text lines up on its baseline; a control (switch, pop-up menu) is centred against its label.
        for (index, row) in rows.enumerated() {
            if row.1 is NSTextField || row.1 is InspectorLocationView {
                grid.row(at: index).rowAlignment = .firstBaseline
            } else {
                grid.row(at: index).yPlacement = .center
            }
            // A control of a fixed size (the Locked switch) sits at the start of its cell. Stretched to fill it, its
            // hugging would outrank the divider and hold the whole Inspector at one width.
            if row.1.contentHuggingPriority(for: .horizontal) > .dragThatCannotResizeWindow {
                grid.cell(atColumnIndex: 1, rowIndex: index).xPlacement = .leading
            }
        }
    }

    /// Applies `rows` to the rows shown when they're the same rows (titles, and values of the same kind showing the
    /// same thing), changing only text that differs. False when the grid has to be rebuilt.
    private func updateInPlace(_ rows: [(String, NSView)]) -> Bool {
        guard rows.count == shown.count, grid.numberOfRows == shown.count else { return false }
        for (row, current) in zip(rows, shown) {
            guard row.0 == current.title else { return false }
            switch (row.1, current.value) {
            case let (new, old) where new === old: continue
            case let (new as NSTextField, old as NSTextField) where type(of: new) == type(of: old): continue
            case let (new as InspectorLocationView, old as InspectorLocationView) where new.showsSamePlace(as: old):
                // Same folder, but maybe another item in it to select when clicked.
                old.action = new.action
                continue
            default: return false
            }
        }
        for (row, current) in zip(rows, shown) {
            if let new = row.1 as? NSTextField, let old = current.value as? NSTextField, new !== old,
               old.stringValue != new.stringValue {
                old.stringValue = new.stringValue
            }
        }
        return true
    }
}

/// "Where": the folder's icon and its path, read in order and ending in the folder's name ("/Users/me"). A long path
/// wraps after a slash rather than losing its start. Clicking shows the folder.
final class InspectorLocationView: NSView {
    fileprivate(set) var action: () -> Void
    private let folder: URL
    private let path: URL
    let nameText: String
    let locationText: String
    /// False when the location describes the folder (a server's address) instead of leading to it.
    let locationLeadsHere: Bool
    let pathLabel = NSTextField(wrappingLabelWithString: "")

    /// `name` and `location` replace the folder's own (a container's folder, shown as it is in the container).
    init(folder: URL, shownAs path: URL, name shownName: String? = nil, location shownLocation: String? = nil,
         locationLeadsHere: Bool = true, action: @escaping () -> Void) {
        self.action = action
        self.folder = folder
        self.path = path
        self.nameText = shownName ?? FileManager.default.displayName(atPath: path.path)
        // The top of the disk has nothing above it; its name ("Macintosh HD") is the whole location.
        self.locationText = shownLocation ?? (path.path == "/" ? "" : Format.tildePath(path.deletingLastPathComponent()))
        self.locationLeadsHere = locationLeadsHere
        super.init(frame: .zero)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: folder.path))
        icon.image?.size = NSSize(width: 16, height: 16)
        icon.translatesAutoresizingMaskIntoConstraints = false
        // A path names the folder as it's stored ("Xcode.app", not "Xcode"; "a:b", not "a/b"), so it can't read as
        // another place. VoiceOver keeps Finder's display name.
        let stored = shownName ?? (path.path == "/" ? nameText : path.lastPathComponent)
        pathLabel.attributedStringValue = Self.text(name: stored, location: locationText, leadsHere: locationLeadsHere)
        pathLabel.baseWritingDirection = .leftToRight
        pathLabel.isSelectable = false
        pathLabel.maximumNumberOfLines = 0
        pathLabel.lineBreakMode = .byWordWrapping
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(pathLabel)
        // Centred on the path's first line. An image view's baseline is its image's height, so aligning baselines
        // placed the icon by whatever size the folder's icon image had at the time.
        let firstLine = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 12))
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: pathLabel.topAnchor, constant: firstLine / 2),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            pathLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: topAnchor),
            pathLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The same path as plain text: a server's or a container's own, never Strata's copy of it.
        toolTip = Self.plain(pathLabel.stringValue)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Show “\(nameText)”", comment: "Inspector: the item’s folder, as a button that shows it"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The path leading to the folder in secondary ink, then the folder's name; a description (a server's address)
    /// goes on its own line under the name instead. Dynamic ink follows theme and appearance changes.
    /// A path reads left to right whatever the script of its names. Each part is isolated (U+2066/U+2068…U+2069),
    /// so a name's direction marks can't reorder the slashes or the other parts.
    static func text(name: String, location: String, leadsHere: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let result = NSMutableAttributedString()
        if leadsHere, !location.isEmpty {
            let leading = location.hasSuffix("/") ? location : location + "/"
            result.append(NSAttributedString(string: "\u{2066}" + leading + "\u{2069}",
                                             attributes: [.font: font, .foregroundColor: InspectorColors.secondary]))
        }
        result.append(NSAttributedString(string: "\u{2068}" + name + "\u{2069}",
                                         attributes: [.font: font, .foregroundColor: InspectorColors.primary]))
        if !leadsHere, !location.isEmpty {
            result.append(NSAttributedString(string: "\n\u{2068}" + location + "\u{2069}", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: InspectorColors.secondary,
            ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = .leftToRight
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Shown text without its invisible direction isolates.
    static func plain(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) }))
    }

    /// Shows the same folder, the same way (its action shows the same place too).
    func showsSamePlace(as other: InspectorLocationView) -> Bool {
        folder == other.folder && path == other.path && nameText == other.nameText && locationText == other.locationText
            && locationLeadsHere == other.locationLeadsHere
    }

    override var firstBaselineOffsetFromTop: CGFloat {
        pathLabel.firstBaselineOffsetFromTop
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The icon and the whole path are one button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
