import AppKit

/// Disk usage of the current folder as a squarified treemap, fed by the browser. Folder sizes may arrive later;
/// each update relayouts with a short animation.
final class TreemapViewController: NSViewController, FileCollectionController {
    let copies: CopyProviders
    weak var fileDelegate: FileCollectionViewDelegate?
    /// Double-click (or Return when the browser doesn't handle it) on a folder tile.
    var onDrill: ((URL) -> Void)?

    init(copies: CopyProviders) {
        self.copies = copies
        treemapView = TreemapView(copies: copies)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private(set) var items: [TreemapItem] = []
    private var indexByKey: [String: Int] = [:]
    private var entries: [String: FileEntry] = [:]
    let treemapView: TreemapView
    private let legend = TreemapLegendView()
    private var relayoutWork: DispatchWorkItem?

    var focusView: NSView { treemapView }

    override func loadView() {
        let root = NSView()
        ThemeStyle.bind(root, to: .content)
        treemapView.translatesAutoresizingMaskIntoConstraints = false
        legend.translatesAutoresizingMaskIntoConstraints = false
        treemapView.controller = self
        root.addSubview(treemapView)
        root.addSubview(legend)
        NSLayoutConstraint.activate([
            treemapView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            treemapView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            treemapView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            treemapView.bottomAnchor.constraint(equalTo: legend.topAnchor),
            legend.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            legend.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            legend.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
            legend.heightAnchor.constraint(equalToConstant: 30),
        ])
        view = root
    }

    // MARK: - Content

    func apply(_ content: FileCollectionContent, metadata: FileCollectionMetadata, animated: Bool) {
        // Unmeasurable folders must not silently shrink the total shown in the legend.
        unmeasured = content.entries.filter {
            $0.isDirectory && !$0.isSymlink && !$0.isVolume && !metadata.canMeasure($0)
        }.count
        setEntries(content.entries, size: metadata.size, animated: animated)
    }

    /// Replaces everything shown. Pass `animated: false` when switching folders.
    func setItems(_ items: [TreemapItem], animated: Bool = true) {
        loadViewIfNeeded()
        self.items = items
        indexByKey = Dictionary(items.enumerated().map { ($1.url.fileViewKey, $0) }, uniquingKeysWith: { a, _ in a })
        let keys = Set(indexByKey.keys)
        treemapView.selectedKeys = treemapView.selectedKeys.filter { keys.contains($0) }
        relayout(animated: animated)
    }

    /// Folders left out because measuring them needs Full Disk Access (the legend mentions them).
    var unmeasured = 0

    /// Convenience for the browser: the folder's entries plus a size lookup (nil while a folder is measuring).
    func setEntries(_ entries: [FileEntry], size: (FileEntry) -> Int64?, animated: Bool = true) {
        self.entries = Dictionary(entries.map { ($0.url.fileViewKey, $0) }, uniquingKeysWith: { a, _ in a })
        setItems(entries.map { TreemapItem(entry: $0, bytes: size($0)) }, animated: animated)
    }

    /// A folder's size arrived (or changed). Bursts are coalesced into one animated relayout.
    func updateSize(_ bytes: Int64?, for url: URL) {
        guard let index = indexByKey[url.fileViewKey], items[index].bytes != bytes else { return }
        items[index].bytes = bytes
        guard relayoutWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.relayoutWork = nil
                self?.relayout(animated: true)
            }
        }
        relayoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    fileprivate func relayout(animated: Bool) {
        let total = items.map { max($0.bytes ?? 0, 0) }.saturatingSum
        treemapView.totalBytes = total
        treemapView.setItems(items, animated: animated && view.window != nil)
        legend.update(items: items, total: total, unmeasured: unmeasured)
    }

    // MARK: - Selection

    var selectedEntries: [FileEntry] {
        treemapView.selectedKeys.sorted().compactMap { key in
            guard let index = indexByKey[key] else { return nil }
            return entries[key] ?? FileEntry(url: items[index].url)
        }
    }

    func select(_ urls: [URL], scroll: Bool = true) {
        treemapView.selectedKeys = Set(urls.map(\.fileViewKey).filter { indexByKey[$0] != nil })
        treemapView.needsDisplay = true
        fileDelegate?.fileView(self, selectionDidChange: selectedEntries.map(\.url))
    }

    func screenRect(for url: URL) -> NSRect? {
        guard let window = view.window, let frame = treemapView.frame(forKey: url.fileViewKey) else { return nil }
        return window.convertToScreen(treemapView.convert(frame, to: nil))
    }

    @discardableResult func beginRename(_ url: URL) -> Bool { false }

    // MARK: - From the map

    fileprivate func selectionChanged() {
        fileDelegate?.fileView(self, selectionDidChange: selectedEntries.map(\.url))
    }

    fileprivate func activate(_ tile: TreemapTile) {
        guard let item = tile.item else { return }
        if item.isFolder {
            onDrill?(item.url)
        } else if let entry = entries[tile.key] ?? FileEntry(url: item.url) {
            fileDelegate?.fileView(self, open: [entry])
        }
    }

    fileprivate func handleKey(_ key: FileViewKey) -> Bool {
        if fileDelegate?.fileView(self, handle: key) == true { return true }
        if key == .returnKey, treemapView.selectedKeys.count == 1, let key = treemapView.selectedKeys.first,
           let tile = treemapView.tile(forKey: key) {
            activate(tile)
            return true
        }
        return false
    }

    fileprivate func menu() -> NSMenu? {
        fileDelegate?.fileView(self, menuFor: selectedEntries)
    }
}

// MARK: - Map view

final class TreemapView: NSView, NSViewToolTipOwner, NSDraggingSource {
    /// Folders stay blue (the legend's color) but each gets its own shade, so neighbours are easy to tell apart.
    /// The shade is picked from the name, so a folder keeps its color between visits.
    static func folderShade(for key: String) -> NSColor {
        let shades: [(hue: CGFloat, saturation: CGFloat)] = [
            (0.585, 0.78), (0.62, 0.62), (0.55, 0.70), (0.66, 0.55), (0.60, 0.48), (0.53, 0.60), (0.635, 0.72),
        ]
        var hash: UInt64 = 1469598103934665603
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let shade = shades[Int(hash % UInt64(shades.count))]
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedHue: shade.hue, saturation: shade.saturation, brightness: dark ? 0.95 : 0.85, alpha: 1)
        }
    }

    fileprivate weak var controller: TreemapViewController?
    var selectedKeys: Set<String> = []
    var totalBytes: Int64 = 0
    let padding: CGFloat = 8

    private struct Drawn {
        var tile: TreemapTile
        var from: CGRect
        var to: CGRect
        var fromAlpha: CGFloat
        var toAlpha: CGFloat
    }

    private var items: [TreemapItem] = []
    private var tiles: [TreemapTile] = []
    private var drawn: [Drawn] = []
    private var animationStart: CFTimeInterval = 0
    private let duration: CFTimeInterval = 0.32
    private var link: CADisplayLink?
    private var hoveredKey: String?
    private var mouseDownTile: TreemapTile?
    private var mouseDownPoint: NSPoint = .zero
    private var lastSize: NSSize = .zero
    private var accessibilityTiles: [NSAccessibilityElement]?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private let copies: CopyProviders

    init(copies: CopyProviders) {
        self.copies = copies
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Disk usage", comment: "Accessibility label of the disk usage map"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var mapRect: CGRect { bounds.insetBy(dx: padding, dy: padding) }

    func setItems(_ items: [TreemapItem], animated: Bool) {
        // Index refreshes come several times a second while files change elsewhere; when nothing here moved or grew,
        // the map stays as it is (re-animating it each time kept it redrawing without end).
        if link == nil, items == self.items, !drawn.isEmpty { return }
        self.items = items
        let next = Treemap.tiles(items, in: mapRect)
        let now = CACurrentMediaTime()
        let progress = currentProgress(now)
        var previous: [String: (frame: CGRect, alpha: CGFloat)] = [:]
        for d in drawn {
            previous[d.tile.key] = (lerp(d.from, d.to, progress), d.fromAlpha + (d.toAlpha - d.fromAlpha) * progress)
        }
        tiles = next
        accessibilityTiles = nil
        let shared = next.filter { previous[$0.key] != nil }.count
        // Nothing in common (a different folder): just show it.
        guard animated, !drawn.isEmpty, shared > 0 else {
            drawn = next.map { Drawn(tile: $0, from: $0.frame, to: $0.frame, fromAlpha: 1, toAlpha: 1) }
            finishAnimation()
            needsDisplay = true
            return
        }
        var result: [Drawn] = []
        let nextKeys = Set(next.map(\.key))
        for tile in next {
            if let old = previous[tile.key] {
                result.append(Drawn(tile: tile, from: old.frame, to: tile.frame, fromAlpha: old.alpha, toAlpha: 1))
            } else {
                let start = tile.frame.insetBy(dx: tile.frame.width * 0.08, dy: tile.frame.height * 0.08)
                result.append(Drawn(tile: tile, from: start, to: tile.frame, fromAlpha: 0, toAlpha: 1))
            }
        }
        for d in drawn where !nextKeys.contains(d.tile.key) {
            guard let old = previous[d.tile.key], old.alpha > 0.01 else { continue }
            // Fading out tiles go underneath.
            result.insert(Drawn(tile: d.tile, from: old.frame, to: old.frame, fromAlpha: old.alpha, toAlpha: 0), at: 0)
        }
        drawn = result
        animationStart = now
        startLink()
        needsDisplay = true
    }

    func tile(forKey key: String) -> TreemapTile? { tiles.first { $0.key == key } }

    func frame(forKey key: String) -> CGRect? { tile(forKey: key)?.frame }

    func tile(at point: NSPoint) -> TreemapTile? { tiles.first { $0.frame.contains(point) } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize != lastSize else { return }
        lastSize = newSize
        // Resizes relayout immediately; animating every live-resize step would lag.
        tiles = Treemap.tiles(items, in: mapRect)
        drawn = tiles.map { Drawn(tile: $0, from: $0.frame, to: $0.frame, fromAlpha: 1, toAlpha: 1) }
        accessibilityTiles = nil
        finishAnimation()
    }

    // MARK: Animation

    private func currentProgress(_ now: CFTimeInterval) -> CGFloat {
        guard link != nil, duration > 0 else { return 1 }
        let t = min(max((now - animationStart) / duration, 0), 1)
        // Ease in-out (cubic).
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return CGFloat(eased)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, link != nil { finishAnimation() }
    }

    private func startLink() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        needsDisplay = true
        if CACurrentMediaTime() - animationStart >= duration { finishAnimation() }
    }

    private func finishAnimation() {
        link?.invalidate()
        link = nil
        drawn = drawn.filter { $0.toAlpha > 0 }.map { Drawn(tile: $0.tile, from: $0.to, to: $0.to, fromAlpha: 1, toAlpha: 1) }
        needsDisplay = true
        rebuildToolTips()
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    // MARK: Drawing

    private var isDark: Bool { FileViewStyle.isDark(effectiveAppearance) }

    private var isEmphasized: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    override func draw(_ dirtyRect: NSRect) {
        // Views don't clip to bounds by default (macOS 14+); never paint outside our own.
        let dirtyRect = dirtyRect.intersection(bounds)
        ThemeStyle.surface(.content).setFill()
        dirtyRect.fill()
        let progress = currentProgress(CACurrentMediaTime())
        if drawn.isEmpty {
            drawPlaceholder()
            return
        }
        let dark = isDark
        let emphasized = isEmphasized
        for d in drawn {
            let frame = lerp(d.from, d.to, progress)
            guard frame.intersects(dirtyRect) else { continue }
            let alpha = d.fromAlpha + (d.toAlpha - d.fromAlpha) * progress
            drawTile(d.tile, frame: frame, alpha: alpha, dark: dark, emphasized: emphasized)
        }
    }

    private func drawPlaceholder() {
        // An empty folder (or a filter matching nothing) is the browser's empty state, drawn over the map.
        guard !items.isEmpty else { return }
        let pending = items.contains { $0.bytes == nil }
        let text = pending ? String(localized: "Calculating sizes…") : String(localized: "Nothing here takes up space")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        string.draw(in: NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20))
    }

    private func drawTile(_ tile: TreemapTile, frame: CGRect, alpha: CGFloat, dark: Bool, emphasized: Bool) {
        // 2 pt gaps between tiles.
        let rect = frame.insetBy(dx: 1, dy: 1)
        guard rect.width >= 1, rect.height >= 1, alpha > 0.01 else { return }
        let radius = min(6, min(rect.width, rect.height) / 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let group = tile.item?.group ?? .other
        let color = tile.item?.isFolder == true ? Self.folderShade(for: tile.key) : group.color
        let hovered = tile.key == hoveredKey
        let selected = selectedKeys.contains(tile.key)
        var fill: CGFloat = dark ? 0.36 : 0.22
        if tile.item?.isFolder == true { fill += dark ? 0.06 : 0.06 }
        if tile.isOther { fill = dark ? 0.26 : 0.2 }
        if hovered { fill += 0.12 }
        if selected { fill += 0.14 }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Solid background first so translucent fills look the same over anything.
        NSColor.controlBackgroundColor.withAlphaComponent(alpha).setFill()
        path.fill()
        color.withAlphaComponent(fill * alpha).setFill()
        path.fill()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: max(radius - 0.5, 0), yRadius: max(radius - 0.5, 0))
        edge.lineWidth = 1
        color.withAlphaComponent((dark ? 0.5 : 0.42) * alpha * (hovered ? 1.5 : 1)).setStroke()
        edge.stroke()
        if selected {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25), xRadius: max(radius - 1, 0), yRadius: max(radius - 1, 0))
            ring.lineWidth = 2.5
            (emphasized ? ThemeStyle.accent : NSColor.secondaryLabelColor).withAlphaComponent(alpha).setStroke()
            ring.stroke()
        }
        drawLabels(tile, in: rect, alpha: alpha, path: path)
    }

    private func drawLabels(_ tile: TreemapTile, in rect: CGRect, alpha: CGFloat, path: NSBezierPath) {
        let inset: CGFloat = rect.width > 120 && rect.height > 60 ? 8 : 5
        let content = rect.insetBy(dx: inset, dy: inset - 1)
        // Too small for a readable label: the tooltip and accessibility carry it.
        guard content.width >= 40, content.height >= 13 else { return }
        path.addClip()
        let large = rect.width >= 150 && rect.height >= 64
        let isFolder = tile.item?.isFolder == true
        let nameFont = large ? NSFont.systemFont(ofSize: 13, weight: .semibold)
            : NSFont.systemFont(ofSize: 11, weight: isFolder ? .semibold : .medium)
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: large ? 12 : 10.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let name = tile.item?.name ?? String(localized: "Other · \(tile.otherCount) items", comment: "plural")
        let nameText = NSAttributedString(string: name, attributes: [
            .font: nameFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha), .paragraphStyle: paragraph,
        ])
        let nameHeight = ceil(nameFont.ascender - nameFont.descender)
        var x = content.minX
        var y = content.minY
        // Folder icons mark what you can drill into; file icons only where there's plenty of room.
        let iconSide: CGFloat = large ? 18 : 14
        if let item = tile.item, isFolder || large, content.width >= 90, content.height >= iconSide {
            icon(for: item).draw(in: NSRect(x: x, y: y + (nameHeight - iconSide) / 2, width: iconSide, height: iconSide),
                                 from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            x += iconSide + 4
        }
        // A truncated name needs room for a recognizable start and end.
        let nameWidth = ceil(nameText.size().width)
        let available = content.maxX - x
        if nameWidth <= available || available >= 56 {
            nameText.draw(with: NSRect(x: x, y: y, width: available, height: nameHeight),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += nameHeight + (large ? 2 : 1)
        }
        let sizeHeight = ceil(sizeFont.ascender - sizeFont.descender)
        guard y + sizeHeight <= content.maxY + 2 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: sizeFont, .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.9 * alpha),
        ]
        var detail = Format.bytes(tile.bytes)
        if large, totalBytes > 0 {
            let share = Double(tile.bytes) / Double(totalBytes)
            detail += "  ·  " + share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)))
        }
        // Numbers are never truncated: shown whole or not at all.
        var sizeText = NSAttributedString(string: detail, attributes: attributes)
        if sizeText.size().width > content.width {
            sizeText = NSAttributedString(string: Format.bytes(tile.bytes), attributes: attributes)
            guard sizeText.size().width <= content.width else { return }
        }
        sizeText.draw(with: NSRect(x: content.minX, y: y, width: content.width, height: sizeHeight),
                      options: [.usesLineFragmentOrigin])
    }

    /// Folder icons per path (they can be custom), document icons per type; no file reads beyond Finder's icon lookup.
    private func icon(for item: TreemapItem) -> NSImage {
        guard !item.isFolder, let type = item.contentType else {
            return IconCache.shared.icon(forPath: item.url.path, folder: item.isFolder)
        }
        return IconCache.shared.icon(forType: type)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(tile(at: convert(event.locationInWindow, from: nil))?.key)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ key: String?) {
        guard key != hoveredKey else { return }
        for old in [hoveredKey, key].compactMap({ $0 }) {
            if let frame = frame(forKey: old) { setNeedsDisplay(frame.insetBy(dx: -2, dy: -2)) }
        }
        hoveredKey = key
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        let hit = tile(at: point)
        mouseDownTile = hit
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let hit, hit.item != nil {
            if mods.contains(.command) {
                if selectedKeys.contains(hit.key) { selectedKeys.remove(hit.key) } else { selectedKeys.insert(hit.key) }
            } else if mods.contains(.shift) {
                selectedKeys.insert(hit.key)
            } else if !selectedKeys.contains(hit.key) || event.clickCount == 1 && selectedKeys.count > 1 {
                selectedKeys = [hit.key]
            }
        } else if !mods.contains(.command) && !mods.contains(.shift) {
            selectedKeys = []
        }
        needsDisplay = true
        controller?.selectionChanged()
        if event.clickCount == 2, let hit { controller?.activate(hit) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tile = mouseDownTile, tile.item != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        mouseDownTile = nil
        let dragged = tiles.filter { selectedKeys.contains($0.key) && $0.item != nil }
        let items: [NSDraggingItem] = dragged.compactMap { t in
            guard let tileItem = t.item else { return nil }
            // A container's or a server's item as a promise: dropped outside Strata it's fetched and finished first.
            let item = NSDraggingItem(pasteboardWriter: ContainerDragItem.writer(for: tileItem.url, copies: copies))
            let icon = icon(for: tileItem)
            let side: CGFloat = 48
            item.setDraggingFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), contents: icon)
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        FileDrop.sourceMask(context == .withinApplication ? [.copy, .move, .generic] : [.copy, .move, .link, .generic],
                            session, copies: copies)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hit = tile(at: point), hit.item != nil {
            if !selectedKeys.contains(hit.key) { selectedKeys = [hit.key] }
        } else {
            selectedKeys = []
        }
        needsDisplay = true
        controller?.selectionChanged()
        return controller?.menu()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = mods.isDisjoint(with: [.command, .control])
        switch event.keyCode {
        case KeyCode.leftArrow where plain: moveSelection(dx: -1, dy: 0); return
        case KeyCode.rightArrow where plain: moveSelection(dx: 1, dy: 0); return
        case KeyCode.downArrow where plain: moveSelection(dx: 0, dy: 1); return
        case KeyCode.upArrow where plain: moveSelection(dx: 0, dy: -1); return
        default: break
        }
        if let key = FileViewKey.from(event) {
            switch key {
            case .escape:
                if controller?.handleKey(.escape) == true { return }
                if !selectedKeys.isEmpty {
                    selectedKeys = []
                    needsDisplay = true
                    controller?.selectionChanged()
                }
                return
            case .type:
                if controller?.handleKey(key) == true { return }
            default:
                if controller?.handleKey(key) != true { super.keyDown(with: event) }
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Moves to the nearest tile in a direction, measured from the current tile's center.
    private func moveSelection(dx: CGFloat, dy: CGFloat) {
        let candidates = tiles.filter { $0.item != nil }
        guard !candidates.isEmpty else { return }
        guard let currentKey = selectedKeys.first, let current = tile(forKey: currentKey) else {
            selectedKeys = [candidates[0].key]
            needsDisplay = true
            controller?.selectionChanged()
            return
        }
        let origin = CGPoint(x: current.frame.midX, y: current.frame.midY)
        var best: (TreemapTile, CGFloat)?
        for tile in candidates where tile.key != current.key {
            let vx = tile.frame.midX - origin.x, vy = tile.frame.midY - origin.y
            let along = vx * dx + vy * dy
            guard along > 1 else { continue }
            let across = abs(vx * dy) + abs(vy * dx)
            let score = along + across * 2
            if best.map({ score < $0.1 }) ?? true { best = (tile, score) }
        }
        guard let next = best?.0 else { return }
        selectedKeys = [next.key]
        needsDisplay = true
        controller?.selectionChanged()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: Tooltips and accessibility

    private func rebuildToolTips() {
        removeAllToolTips()
        for tile in tiles { addToolTip(tile.frame, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let tile = tile(at: point) else { return "" }
        return description(of: tile, separator: "\n")
    }

    private func description(of tile: TreemapTile, separator: String) -> String {
        var share = ""
        if totalBytes > 0 {
            let fraction = Double(tile.bytes) / Double(totalBytes)
            let percent = fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)))
            share = " — " + String(localized: "\(percent) of this folder", comment: "Share of the folder's size; placeholder: a percentage, e.g. 12%")
        }
        guard let item = tile.item else {
            let count = String(localized: "\(tile.otherCount) smaller items", comment: "plural")
            return "\(count)\(separator)\(Format.bytes(tile.bytes))\(share)"
        }
        let kind = item.isFolder ? String(localized: "Folder", comment: "Kind of item") : item.group.title
        return "\(item.name)\(separator)\(Format.bytes(tile.bytes))\(share)\(separator)\(kind)"
    }

    override func accessibilityChildren() -> [Any]? {
        if let accessibilityTiles { return accessibilityTiles }
        let elements = tiles.map { tile -> NSAccessibilityElement in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(description(of: tile, separator: ", "))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(tile.frame)
            element.setAccessibilitySelected(selectedKeys.contains(tile.key))
            return element
        }
        accessibilityTiles = elements
        return elements
    }
}

// MARK: - Legend

/// Color key along the bottom: one swatch per kind present with its total, and the folder total on the right.
final class TreemapLegendView: NSView {
    private let stack = NSStackView()
    private let total = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        // The legend must never widen the window, or hold a pane wider (dragging the divider between panes, whose
        // holding priority is 250): it may be narrower than its content, dropping the smallest groups first, then
        // shortening the total.
        stack.setClippingResistancePriority(.init(150), for: .horizontal)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        total.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        total.textColor = .secondaryLabelColor
        total.alignment = .right
        total.translatesAutoresizingMaskIntoConstraints = false
        total.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        total.lineBreakMode = .byTruncatingHead
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(total)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -12),
            spinner.trailingAnchor.constraint(equalTo: total.leadingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            total.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            total.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        ThemeStyle.surface(.content).setFill()
        dirtyRect.intersection(bounds).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    private struct Shown: Equatable {
        let groups: [[String]]
        let count: Int
        let bytes: Int64
        let pending: Int
        let unmeasured: Int
    }
    private var lastShown: Shown?

    func update(items: [TreemapItem], total bytes: Int64, unmeasured: Int) {
        var byGroup: [FileKindGroup: Int64] = [:]
        for item in items { byGroup[item.group] = [byGroup[item.group, default: 0], max(item.bytes ?? 0, 0)].saturatingSum }
        let groups = byGroup.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let pending = items.filter { $0.bytes == nil }.count
        // The same legend again (an index refresh): leave it be.
        let shown = Shown(groups: groups.map { [$0.key.title, "\($0.value)"] }, count: items.count, bytes: bytes,
                          pending: pending, unmeasured: unmeasured)
        guard shown != lastShown else { return }
        lastShown = shown
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // When the strip is too narrow, the smallest groups drop out first.
        for (index, (group, groupBytes)) in groups.enumerated() {
            let entry = LegendEntry(group: group, bytes: groupBytes)
            stack.addArrangedSubview(entry)
            stack.setVisibilityPriority(index == 0 ? .mustHold : NSStackView.VisibilityPriority(rawValue: 900 - Float(index) * 10), for: entry)
        }
        var text = String(localized: "\(items.count) items", comment: "plural") + " · " + Format.bytes(bytes)
        if pending > 0 { text = String(localized: "Measuring \(pending) folders…", comment: "plural") + "  " + text }
        if unmeasured > 0 { text += " · " + String(localized: "\(unmeasured) folders need Full Disk Access to be measured", comment: "plural") }
        total.stringValue = text
        if pending > 0 { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let legend = groups.map { "\($0.key.title) \(Format.bytes($0.value))" }.joined(separator: ", ")
        setAccessibilityLabel(String(localized: "Legend: \(legend). \(text)",
                                     comment: "Accessibility: the disk usage legend; placeholders: kinds with their sizes, then the totals"))
    }
}

private final class LegendEntry: NSView {
    private let group: FileKindGroup

    init(group: FileKindGroup, bytes: Int64) {
        self.group = group
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(string: group.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        text.append(NSAttributedString(string: " " + Format.bytes(bytes), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        label.attributedStringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let swatch = NSRect(x: 0, y: (bounds.height - 9) / 2, width: 9, height: 9)
        let path = NSBezierPath(roundedRect: swatch, xRadius: 2.5, yRadius: 2.5)
        let dark = FileViewStyle.isDark(effectiveAppearance)
        group.color.withAlphaComponent(dark ? 0.75 : 0.65).setFill()
        path.fill()
        group.color.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
