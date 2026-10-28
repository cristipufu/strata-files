import AppKit
import CoreText

/// How an icon cell is highlighted.
struct GridItemState: Equatable {
    var selected = false
    /// The stronger selection color when the grid has focus in the key window.
    var emphasized = false
    var dropTarget = false
    var dimmed = false
}

/// One icon cell: thumbnail/icon in a rounded selection box, a two-line middle-truncated name in a capsule, and an
/// optional detail line. Text and highlights are drawn; the image is an image view so thumbnails can crossfade in.
final class GridItemView: NSView, ColorThemeUpdating {
    let imageView = NSImageView()
    /// Git status, at the icon's top-right corner.
    let gitBadge = GitStatusBadge()
    let cloudBadge = CloudBadge()
    private(set) var metrics = GridMetrics(iconSize: 64, typography: .standard)
    private var name = ""
    private var matches: [Int] = []
    private var detail: String?
    /// Finder tags, as dots before the name.
    private var tags: [FinderTag] = []
    private(set) var state = GridItemState()
    var isRenaming = false { didSet { needsDisplay = true } }

    private var lines: [NSAttributedString] = []
    private var lineWidths: [CGFloat] = []
    private var linesKey: String = ""

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignBottom
        imageView.wantsLayer = true
        imageView.isEditable = false
        imageView.unregisterDraggedTypes()
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        gitBadge.drawsBacking = true
        addSubview(gitBadge)
        cloudBadge.drawsBacking = true
        addSubview(cloudBadge)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateColorTheme() {
        linesKey = ""
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorTheme()
    }

    // The collection view selects, rubber-bands and drags from the view hit-testing returns. Subviews (the icon, the
    // badges) must not take the click. Returning nil makes a click on the icon look like empty space, so only a drag
    // selects; this view is the hit target and then hands the click to the collection view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        collectionView?.mouseDown(with: event)
    }

    /// A click on an icon in a window in the background does what the collection view would do with it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        collectionView?.acceptsFirstMouse(for: event) ?? false
    }

    private var collectionView: NSCollectionView? {
        var ancestor: NSView? = superview
        while let view = ancestor, !(view is NSCollectionView) { ancestor = view.superview }
        return ancestor as? NSCollectionView
    }

    func configure(name: String, matches: [Int], detail: String?, metrics: GridMetrics) {
        let changed = name != self.name || matches != self.matches || metrics != self.metrics
        self.name = name
        self.matches = matches
        self.detail = detail
        if metrics != self.metrics {
            self.metrics = metrics
            needsLayout = true
        }
        if changed { linesKey = "" }
        setAccessibilityLabel(accessibilityText)
        needsDisplay = true
    }

    func setTags(_ tags: [FinderTag]) {
        guard tags != self.tags else { return }
        self.tags = tags
        linesKey = ""
        setAccessibilityLabel(accessibilityText)
        needsDisplay = true
    }

    /// Room before the first line for tag dots (clear of the name's selection capsule, which reaches past the text).
    private var dotsLead: CGFloat {
        tags.isEmpty ? 0 : TagDotsView.width(for: tags, diameter: Self.dotDiameter) + 3 + Self.capsulePad
    }

    private static let capsulePad: CGFloat = 5

    /// Name, tags and detail, for VoiceOver.
    private var accessibilityText: String {
        let cloud = cloudBadge.status.flatMap { $0 == .downloaded || $0 == .local ? nil : $0.label }
        let tagList = tags.isEmpty ? nil
            : String(localized: "tags \(tags.map(\.shownName).joined(separator: ", "))",
                     comment: "Accessibility, after an item's name; the placeholder is a list of tag names")
        return [name, tagList, cloud, detail].compactMap { $0 }
            .joined(separator: ", ")
    }

    private static let dotDiameter: CGFloat = 8

    /// Where a line of the name starts: the first one leaves room for the tag dots, and the pair stays centered.
    private func lineX(_ index: Int, width: CGFloat) -> CGFloat {
        index == 0 ? ((bounds.width - width - dotsLead) / 2).rounded(.down) + dotsLead : ((bounds.width - width) / 2).rounded(.down)
    }

    func setDetail(_ detail: String?) {
        guard detail != self.detail else { return }
        self.detail = detail
        setAccessibilityLabel(accessibilityText)
        needsDisplay = true
    }

    func setState(_ state: GridItemState) {
        guard state != self.state else { return }
        let textChanged = state.selected != self.state.selected || state.emphasized != self.state.emphasized
            || state.dimmed != self.state.dimmed
        self.state = state
        if textChanged { linesKey = "" }
        imageView.alphaValue = state.dimmed ? 0.45 : 1
        setAccessibilitySelected(state.selected)
        needsDisplay = true
    }

    /// Fades a new image in (thumbnail arrival) or swaps it instantly. Icons scale to the icon size; thumbnails
    /// only shrink, so tiny images stay crisp instead of being blown up.
    func setImage(_ image: NSImage?, animated: Bool, upscale: Bool = true) {
        imageView.imageScaling = upscale ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        if animated, imageView.image != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageView.layer?.add(fade, forKey: "thumbnail")
        }
        imageView.image = image
    }

    // MARK: Geometry

    var iconBoxRect: NSRect {
        let side = metrics.iconBoxSide
        return NSRect(x: ((bounds.width - side) / 2).rounded(), y: metrics.topPad, width: side, height: side)
    }

    var iconRect: NSRect { iconBoxRect.insetBy(dx: metrics.iconPad, dy: metrics.iconPad) }

    private var labelWidth: CGFloat { max(min(metrics.labelWidth, bounds.width - 8), 1) }

    /// The area the name occupies (for the rename field and drag images).
    var nameRect: NSRect {
        ensureLines()
        // Spans every line as drawn (the first one sits right of the tag dots, which are included).
        let lefts = lineWidths.enumerated().map { lineX($0.offset, width: $0.element) }
        let rights = lineWidths.enumerated().map { lineX($0.offset, width: $0.element) + $0.element }
        let minX = (lefts.min() ?? bounds.midX) - (tags.isEmpty ? 0 : dotsLead)
        let maxX = rights.max() ?? bounds.midX
        let height = CGFloat(max(lines.count, 1)) * metrics.lineHeight
        return NSRect(x: minX.rounded(.down), y: iconBoxRect.maxY + metrics.nameGap, width: (maxX - minX).rounded(.up),
                      height: height)
    }

    var nameAreaRect: NSRect {
        NSRect(x: ((bounds.width - labelWidth) / 2).rounded(), y: iconBoxRect.maxY + metrics.nameGap,
               width: labelWidth, height: metrics.lineHeight * 2)
    }

    override func layout() {
        super.layout()
        imageView.frame = iconRect
        let size = NSSize(width: GitStatusBadge.tileSize.width + 4, height: GitStatusBadge.tileSize.height + 4)
        gitBadge.frame = NSRect(x: iconRect.maxX - size.width + 3, y: iconRect.minY - 3, width: size.width, height: size.height)
        // The cloud state sits in the other corner.
        cloudBadge.frame = NSRect(x: iconRect.minX - 3, y: iconRect.minY - 3, width: size.width + 3, height: size.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width { linesKey = "" }
        super.setFrameSize(newSize)
    }

    // MARK: Drawing

    private var textColor: NSColor {
        let base: NSColor = state.selected && state.emphasized ? ThemeStyle.selectedText : .labelColor
        return state.dimmed ? base.withAlphaComponent(0.5) : base
    }

    /// Names like "onboarding-1.png" have no line-break opportunity, so the typesetter splits mid-word
    /// ("onboarding-1.pn" / "g"). Prefer breaking after a space, hyphen or underscore, then before the extension.
    private static func friendlierBreak(in name: NSString, at index: Int) -> Int {
        guard index > 0, index < name.length else { return index }
        let separators: Set<unichar> = [32, 45, 95] // space, -, _
        if separators.contains(name.character(at: index - 1)) { return index }
        let floor = max(1, index / 3)
        var i = index - 1
        while i >= floor {
            if separators.contains(name.character(at: i)) { return i + 1 }
            i -= 1
        }
        i = index - 1
        while i >= floor {
            if name.character(at: i) == 46 { return i } // "."
            i -= 1
        }
        return index
    }

    /// Splits the name into at most two lines: the first breaks at a word (or character) boundary, the second
    /// holds the rest and truncates in the middle so extensions stay visible, like Finder.
    private func ensureLines() {
        let key = "\(name)|\(labelWidth)|\(matches)|\(state.selected)|\(state.emphasized)|\(state.dimmed)|\(dotsLead)"
        guard key != linesKey else { return }
        linesKey = key
        let color = textColor
        let highlight: NSColor = state.selected && state.emphasized ? color : ThemeStyle.accent
        let full = FileViewStyle.highlightedName(name, matches: matches, font: metrics.typography.font, boldFont: metrics.typography.bold, color: color, highlight: highlight)
        let width = max(labelWidth - dotsLead, 1)
        let typesetter = CTTypesetterCreateWithAttributedString(full)
        let length = full.length
        var breakIndex = CTTypesetterSuggestLineBreak(typesetter, 0, Double(width))
        if breakIndex <= 0 { breakIndex = max(CTTypesetterSuggestClusterBreak(typesetter, 0, Double(width)), 1) }
        breakIndex = Self.friendlierBreak(in: full.string as NSString, at: breakIndex)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        if breakIndex >= length {
            let line = NSMutableAttributedString(attributedString: full)
            line.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: line.length))
            lines = [line]
            lineWidths = [min(ceil(full.size().width), width)]
            return
        }
        let first = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(location: 0, length: breakIndex)))
        // Trailing spaces at the break shouldn't widen the capsule.
        while first.length > 0, first.string.last?.isWhitespace == true {
            first.deleteCharacters(in: NSRange(location: first.length - 1, length: 1))
        }
        first.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: first.length))
        let second = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(location: breakIndex, length: length - breakIndex)))
        let truncating = NSMutableParagraphStyle()
        truncating.alignment = .center
        truncating.lineBreakMode = .byTruncatingMiddle
        second.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: second.length))
        lines = [first, second]
        lineWidths = [min(ceil(first.size().width), width), min(ceil(second.size().width), labelWidth)]
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = iconBoxRect
        if state.selected || state.dropTarget {
            let path = NSBezierPath(roundedRect: box, xRadius: min(8, box.width * 0.09), yRadius: min(8, box.width * 0.09))
            ThemeStyle.iconSelection.setFill()
            path.fill()
            if state.dropTarget {
                ThemeStyle.accent.setStroke()
                path.lineWidth = 2
                let inset = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
                inset.lineWidth = 2
                inset.stroke()
            }
        }
        guard !isRenaming else { return }
        ensureLines()
        var y = box.maxY + metrics.nameGap
        if state.selected {
            let capsule = capsulePath(top: y)
            ThemeStyle.selection(emphasized: state.emphasized).setFill()
            capsule.fill()
        }
        if !tags.isEmpty, let first = lineWidths.first {
            let x = lineX(0, width: first) - dotsLead
            // Outside the name's capsule, so the rings match the grid's background.
            TagDotsView.draw(tags, at: NSPoint(x: x, y: y + (metrics.lineHeight - Self.dotDiameter) / 2),
                             diameter: Self.dotDiameter, alpha: state.dimmed ? 0.45 : 1)
        }
        for (index, (line, width)) in zip(lines, lineWidths).enumerated() {
            let rect = NSRect(x: lineX(index, width: width), y: y, width: width + 1, height: metrics.lineHeight)
            line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += metrics.lineHeight
        }
        if let detail, !detail.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let color: NSColor = state.dimmed ? NSColor.secondaryLabelColor.withAlphaComponent(0.5) : .secondaryLabelColor
            let text = NSAttributedString(string: detail, attributes: [
                .font: FileViewStyle.detailFont, .foregroundColor: color, .paragraphStyle: paragraph,
            ])
            let rect = NSRect(x: (bounds.width - labelWidth) / 2, y: y + 2, width: labelWidth, height: metrics.detailHeight)
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// One rounded shape hugging each line, merged so a long first line over a short second reads as one label.
    private func capsulePath(top: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let padX = Self.capsulePad, padY: CGFloat = 0.5
        var y = top
        var rects: [NSRect] = []
        for (index, width) in lineWidths.enumerated() {
            rects.append(NSRect(x: lineX(index, width: width) - padX, y: y - padY,
                                width: width + padX * 2 + 1, height: metrics.lineHeight + padY * 2))
            y += metrics.lineHeight
        }
        if rects.count == 2 {
            // Overlap the two pills so the join has no seam.
            rects[0].size.height += 2
            rects[1].origin.y -= 2
            rects[1].size.height += 2
        }
        let radius = min(metrics.lineHeight / 2, 6)
        for rect in rects { path.append(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)) }
        path.windingRule = .nonZero
        return path
    }

    /// The name drawn on its own, for drag images.
    func nameImage() -> NSImage? {
        let rect = nameRect.insetBy(dx: -6, dy: -1)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let wasSelected = state
        var plain = state
        plain.selected = false
        setState(plain)
        defer { setState(wasSelected) }
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }
}

final class GridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GridItem")

    let itemView = GridItemView()
    private(set) var entry: FileEntry?
    private var thumbnails: FileThumbnails = .shared
    private var itemInfo: ItemInfoLoader = .shared
    private var thumbnailTicket: FileThumbnails.Ticket?
    private var infoTicket: ItemInfoLoader.Ticket?
    /// Set by the grid; returns whether selections should be drawn emphasized.
    var emphasis: () -> Bool = { false }
    var dimmed = false

    isolated deinit {
        thumbnails.cancel(thumbnailTicket)
        itemInfo.cancel(infoTicket)
    }

    override func loadView() {
        view = itemView
        imageView = itemView.imageView
    }

    override var isSelected: Bool {
        didSet { updateState() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateState() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnails.cancel(thumbnailTicket)
        itemInfo.cancel(infoTicket)
        thumbnailTicket = nil
        infoTicket = nil
        entry = nil
        itemView.isRenaming = false
        itemView.setImage(nil, animated: false)
    }

    func updateState() {
        var state = GridItemState()
        switch highlightState {
        case .forSelection: state.selected = true
        case .forDeselection: state.selected = false
        default: state.selected = isSelected
        }
        state.dropTarget = highlightState == .asDropTarget
        state.emphasized = emphasis()
        state.dimmed = dimmed
        itemView.setState(state)
    }

    func configure(_ entry: FileEntry, matches: [Int], metrics: GridMetrics, showsInfo: Bool, dimmed: Bool, scale: CGFloat,
                   git: GitBadge? = nil, tags: [FinderTag] = [], cloud: CloudStatus? = nil, folderSizeText: String? = nil,
                   preferences: Prefs, thumbnails: FileThumbnails = .shared, itemInfo: ItemInfoLoader = .shared) {
        self.itemInfo.cancel(infoTicket)
        self.itemInfo = itemInfo
        infoTicket = nil
        itemView.gitBadge.badge = git
        itemView.cloudBadge.status = cloud
        itemView.setTags(tags)
        let sameFile = self.entry == entry
        self.entry = entry
        self.dimmed = dimmed
        let showHidden = preferences.showHidden
        let detail = showsInfo ? folderSizeText ?? itemInfo.immediate(entry, showHidden: showHidden) : nil
        itemView.configure(name: entry.displayName, matches: matches, detail: detail, metrics: metrics)
        itemView.setAccessibilityHelp(entry.kind)
        updateState()

        if showsInfo, detail == nil {
            itemInfo.cancel(infoTicket)
            infoTicket = itemInfo.request(entry, showHidden: showHidden) { [weak self] text in
                guard let self, self.entry == entry else { return }
                self.infoTicket = nil
                self.itemView.setDetail(text)
            }
        }
        loadImage(entry, size: metrics.iconSize, scale: scale, keepCurrent: sameFile, preferences: preferences,
                  thumbnails: thumbnails)
    }

    /// Shows the icon (or the best cached thumbnail) now and asks Quick Look for a sharper one if needed.
    func loadImage(_ entry: FileEntry, size: CGFloat, scale: CGFloat, keepCurrent: Bool, preferences: Prefs,
                   thumbnails: FileThumbnails = .shared) {
        self.thumbnails.cancel(thumbnailTicket)
        self.thumbnails = thumbnails
        thumbnailTicket = nil
        let canThumbnail = preferences.showIconPreviews && thumbnails.canThumbnail(entry)
        let cached = canThumbnail ? thumbnails.cached(entry, size: size, scale: scale) : nil
        if let cached {
            itemView.setImage(cached.image, animated: false, upscale: !cached.exact)
            if cached.exact { return }
        } else if !canThumbnail || !(keepCurrent && itemView.imageView.image != nil) {
            itemView.setImage(thumbnails.icon(for: entry), animated: false)
        }
        guard canThumbnail, !thumbnails.hasFailed(entry, size: size, scale: scale) else { return }
        thumbnailTicket = thumbnails.request(entry, size: size, scale: scale) { [weak self] image in
            guard let self, self.entry == entry else { return }
            self.thumbnailTicket = nil
            self.itemView.setImage(image, animated: true, upscale: false)
        }
    }

    override var draggingImageComponents: [NSDraggingImageComponent] {
        let iconRect = itemView.iconRect
        let icon = NSDraggingImageComponent(key: .icon)
        icon.contents = itemView.imageView.image
        // Aspect-fit and bottom-aligned, like the image view draws it.
        if let image = itemView.imageView.image, image.size.width > 0, image.size.height > 0 {
            let scale = min(iconRect.width / image.size.width, iconRect.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            icon.frame = NSRect(x: iconRect.midX - size.width / 2, y: itemView.bounds.height - iconRect.maxY,
                                width: size.width, height: size.height)
        } else {
            icon.frame = iconRect
        }
        var components = [icon]
        if let nameImage = itemView.nameImage() {
            let label = NSDraggingImageComponent(key: .label)
            label.contents = nameImage
            let rect = itemView.nameRect.insetBy(dx: -6, dy: -1)
            label.frame = NSRect(x: rect.minX, y: itemView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            components.append(label)
        }
        return components
    }
}
