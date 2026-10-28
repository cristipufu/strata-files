import AppKit
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension ConflictResolver {
    /// Asks with a `ConflictSheetController` on `window` (or a standalone panel when the window is gone).
    /// Cancelling the job while the sheet is up closes it.
    static func sheet(for window: NSWindow?) -> ConflictResolver {
        ConflictResolver { [weak window] conflict in
            let controller = ConflictSheetController(conflict: conflict)
            return await controller.run(on: window)
        }
    }
}

/// "An item named … already exists": the existing and incoming items side by side, with a line diff for small text
/// files, and Skip / Keep Both / Replace. Esc stops the whole job.
final class ConflictSheetController: NSWindowController {
    let conflict: TransferConflict
    private let applyToAll = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var continuation: CheckedContinuation<ConflictResolution, Never>?
    private var loadTasks: [Task<Void, Never>] = []
    private let existingCard: ItemCard
    private let incomingCard: ItemCard
    private let diffSection = NSStackView()

    static let width: CGFloat = 620

    init(conflict: TransferConflict) {
        self.conflict = conflict
        existingCard = ItemCard(caption: String(localized: "Existing", comment: "Conflict sheet: over the item already there"),
                                url: conflict.existing)
        incomingCard = ItemCard(caption: String(localized: "Incoming", comment: "Conflict sheet: over the item being copied or moved"),
                                url: conflict.source)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400), styleMask: [.titled],
                            backing: .buffered, defer: true)
        super.init(window: panel)
        panel.contentView = buildContent()
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        loadDetails()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Presenting

    /// Shows the sheet and waits for an answer.
    func run(on parent: NSWindow?) async -> ConflictResolution {
        // One sheet at a time per window; a job cancelled while waiting its turn never shows one.
        while let parent, parent.attachedSheet != nil {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return ConflictResolution(decision: .stop) }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard let window else { return finish(.stop) }
                if let parent, parent.isVisible {
                    parent.beginSheet(window)
                } else {
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.stop) }
        }
    }

    private func finish(_ decision: ConflictDecision) {
        loadTasks.forEach { $0.cancel() }
        if let window {
            if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
        }
        let answer = ConflictResolution(decision: decision, applyToAll: applyToAll.state == .on && conflict.remaining > 1)
        continuation?.resume(returning: answer)
        continuation = nil
    }

    @objc private func replace(_ sender: Any?) { finish(.replace) }
    @objc private func keepBoth(_ sender: Any?) { finish(.keepBoth) }
    @objc private func merge(_ sender: Any?) { finish(.merge) }
    @objc private func skip(_ sender: Any?) { finish(.skip) }
    @objc private func stop(_ sender: Any?) { finish(.stop) }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let name = conflict.existing.lastPathComponent
        let folder = FileManager.default.displayName(atPath: conflict.existing.deletingLastPathComponent().path)
        let title = NSTextField(wrappingLabelWithString: String(localized: "An item named “\(name)” already exists in “\(folder)”."))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.preferredMaxLayoutWidth = Self.width - 48
        let detail = switch (conflict.mode, ItemCard.isFolder(conflict.existing)) {
        case (.copy, true): String(localized: "Replace it with the one you’re copying? The existing folder will be moved to the Trash.")
        case (.copy, false): String(localized: "Replace it with the one you’re copying? The existing item will be moved to the Trash.")
        case (.move, true): String(localized: "Replace it with the one you’re moving? The existing folder will be moved to the Trash.")
        case (.move, false): String(localized: "Replace it with the one you’re moving? The existing item will be moved to the Trash.")
        }
        let subtitle = NSTextField(wrappingLabelWithString: detail)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = Self.width - 48

        let cards = NSStackView(views: [existingCard, incomingCard])
        cards.distribution = .fillEqually
        cards.alignment = .top
        cards.spacing = 12

        diffSection.orientation = .vertical
        diffSection.alignment = .leading
        diffSection.spacing = 6
        diffSection.isHidden = true

        let buttons = buildButtons()

        let stack = NSStackView(views: [title, subtitle, cards, diffSection, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(16, after: cards)
        stack.setCustomSpacing(18, after: diffSection)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            cards.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            diffSection.widthAnchor.constraint(equalTo: cards.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: cards.widthAnchor),
            existingCard.heightAnchor.constraint(equalTo: incomingCard.heightAnchor),
        ])
        return content
    }

    private func buildButtons() -> NSView {
        func button(_ title: String.LocalizationValue, _ action: Selector) -> NSButton {
            let button = NSButton(title: String(localized: title), target: self, action: action)
            button.bezelStyle = .push
            button.controlSize = .large
            return button
        }
        let stop = button("Stop", #selector(stop(_:)))
        stop.keyEquivalent = "\u{1b}"
        stop.toolTip = conflict.mode == .copy ? String(localized: "Cancel the whole copy (Esc)")
            : String(localized: "Cancel the whole move (Esc)")
        let skip = button("Skip", #selector(skip(_:)))
        let keepBoth = button("Keep Both", #selector(keepBoth(_:)))
        let replace = button("Replace", #selector(replace(_:)))
        replace.keyEquivalent = "\r"
        let merge = button("Merge", #selector(merge(_:)))
        merge.toolTip = String(localized: "Add what’s missing and merge the folders; where both have the same item, the newer one is kept")
        merge.isHidden = !conflict.canMerge

        applyToAll.title = String(localized: "Apply to all \(conflict.remaining) conflicts", comment: "plural")
        applyToAll.font = .systemFont(ofSize: 12)
        applyToAll.isHidden = conflict.remaining <= 1

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [stop, spacer, skip, keepBoth, merge, replace])
        row.spacing = 10
        row.setCustomSpacing(10, after: spacer)

        let column = NSStackView(views: [applyToAll, row])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    // MARK: - Details

    private func loadDetails() {
        let existing = conflict.existing, incoming = conflict.source
        loadTasks.append(Task { [weak self] in
            async let a = ItemFacts.load(existing)
            async let b = ItemFacts.load(incoming)
            let (old, new) = await (a, b)
            guard let self, !Task.isCancelled else { return }
            self.existingCard.show(old, comparedTo: new)
            self.incomingCard.show(new, comparedTo: old)
            self.resize()
            if let diff = await ItemFacts.diff(old, new), !Task.isCancelled {
                self.showDiff(diff)
            }
        })
        for card in [existingCard, incomingCard] {
            loadTasks.append(Task { [weak card] in
                guard let url = card?.url, let image = await Thumbnails.image(for: url, side: 96) else { return }
                card?.setThumbnail(image)
            })
        }
    }

    private func showDiff(_ diff: LineDiff.Result) {
        diffSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = NSTextField(labelWithString: diff.isIdentical
            ? String(localized: "Contents", comment: "Conflict sheet: heading over the files’ contents")
            : String(localized: "Changes", comment: "Conflict sheet: heading over the line differences"))
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor

        if diff.isIdentical {
            let note = NSTextField(labelWithString: String(localized: "Both files have identical contents."))
            note.font = .systemFont(ofSize: 12)
            note.textColor = .secondaryLabelColor
            let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .systemGreen
            icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            let line = NSStackView(views: [icon, note])
            line.spacing = 5
            diffSection.addArrangedSubview(header)
            diffSection.addArrangedSubview(line)
        } else {
            let counts = NSTextField(labelWithAttributedString: DiffView.summary(added: diff.added, removed: diff.removed))
            let top = NSStackView(views: [header, counts])
            top.spacing = 8
            let view = DiffView(rows: diff.rows)
            let box = DiffBox(diffView: view)
            diffSection.addArrangedSubview(top)
            diffSection.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: diffSection.widthAnchor).isActive = true
            // When it scrolls, end on half a row so it's obvious there's more.
            let visible = min(view.contentHeight, 4 + DiffView.rowHeight * 12.5)
            box.heightAnchor.constraint(equalToConstant: visible + 2).isActive = true
        }
        diffSection.isHidden = false
        resize()
    }

    private func resize() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.height != content.frame.height else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let old = window.frame
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible && window.sheetParent == nil)
    }
}

// MARK: - Facts about each side

/// Size, date and (for small text files) contents of one side of a conflict.
nonisolated struct ItemFacts: Sendable {
    let url: URL
    let isFolder: Bool
    let kind: String?
    let bytes: Int64?
    let files: Int?
    let modified: Date?
    let text: String?
    /// For files up to 8 MB: a digest to say "identical" when the bytes match.
    let digest: Data?

    static let textLimit = 1_000_000

    @concurrent
    static func load(_ url: URL) async -> ItemFacts {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .fileSizeKey,
                                                        .contentModificationDateKey, .localizedTypeDescriptionKey,
                                                        .contentTypeKey])
        let isFolder = values?.isDirectory == true
        var bytes = values?.fileSize.map(Int64.init)
        var files: Int?
        if isFolder, let size = FolderSizer.measure(url.path, isCancelled: { Task.isCancelled }) {
            bytes = size.bytes
            files = size.files
        }
        var text: String?
        var digest: Data?
        if !isFolder, values?.isRegularFile == true, let size = bytes, size <= 8_000_000,
           let (data, truncated) = try? TextFile.readPrefix(url, limit: 8_000_000), !truncated {
            digest = Data(SHA256.hash(data: data))
            if size <= Int64(textLimit), isText(data, type: values?.contentType) {
                text = String(decoding: data, as: UTF8.self)
            }
        }
        let kind = FileEntry.kind(extension: url.pathExtension, isDirectory: isFolder, isPackage: values?.isPackage == true,
                                  size: values?.fileSize.map(Int64.init), system: values?.localizedTypeDescription)
        return ItemFacts(url: url, isFolder: isFolder && values?.isPackage != true, kind: kind,
                         bytes: bytes, files: files, modified: values?.contentModificationDate, text: text, digest: digest)
    }

    @concurrent
    static func diff(_ old: ItemFacts, _ new: ItemFacts) async -> LineDiff.Result? {
        guard let a = old.text, let b = new.text else { return nil }
        if a == b { return LineDiff.Result(rows: [], added: 0, removed: 0) }
        return LineDiff.compute(old: a, new: b)
    }

    private static func isText(_ data: Data, type: UTType?) -> Bool {
        if data.isEmpty { return type?.conforms(to: .text) ?? false }
        let sample = data.prefix(8192)
        if sample.contains(0) { return false }
        if let type, type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) { return true }
        // Unknown types: accept valid UTF-8 without control characters other than whitespace.
        guard String(data: sample, encoding: .utf8) != nil || sample.count == 8192 else { return false }
        return !sample.contains { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }
    }
}

enum Thumbnails {
    /// Quick Look thumbnail, or the Finder icon when there isn't one.
    static func image(for url: URL, side: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .thumbnail)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }
        return nil
    }
}

// MARK: - Card

/// One side of the conflict: thumbnail, name, size, date and comparison pills.
final class ItemCard: NSView {
    let url: URL
    private let captionLabel = NSTextField(labelWithString: "")
    private let imageView = ThumbnailView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let pills = NSStackView()

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    init(caption: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        captionLabel.stringValue = caption.uppercased()
        captionLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.attributedStringValue = NSAttributedString(string: caption.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .kern: 0.6, .foregroundColor: NSColor.secondaryLabelColor,
        ])

        imageView.image = NSWorkspace.shared.icon(forFile: url.path)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.stringValue = url.lastPathComponent
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.toolTip = Format.tildePath(url)
        for label in [sizeLabel, dateLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
        }
        sizeLabel.stringValue = " "
        dateLabel.stringValue = " "
        pills.spacing = 6
        let pillRow = NSView()
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        pills.translatesAutoresizingMaskIntoConstraints = false
        pillRow.addSubview(pills)

        let stack = NSStackView(views: [captionLabel, imageView, nameLabel, sizeLabel, dateLabel, pillRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.setCustomSpacing(10, after: captionLabel)
        stack.setCustomSpacing(10, after: imageView)
        stack.setCustomSpacing(8, after: dateLabel)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 96),
            imageView.heightAnchor.constraint(equalToConstant: 96),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28),
            sizeLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28),
            dateLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28),
            pillRow.heightAnchor.constraint(equalToConstant: 18),
            pillRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            pills.centerXAnchor.constraint(equalTo: pillRow.centerXAnchor),
            pills.centerYAnchor.constraint(equalTo: pillRow.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ facts: ItemFacts, comparedTo other: ItemFacts) {
        var size: [String] = []
        if facts.isFolder {
            size.append(facts.files.map { String(localized: "\($0) items", comment: "plural") }
                ?? String(localized: "Folder", comment: "Kind of item"))
        } else if let kind = facts.kind {
            size.append(kind)
        }
        if let bytes = facts.bytes {
            // "1 KB" on both sides hides which is larger: show exact bytes when the rounded sizes match.
            let rounded = Format.bytes(bytes)
            let exact = other.bytes.map { $0 != bytes && Format.bytes($0) == rounded } ?? false
            size.append(exact ? String(localized: "\(Int(bytes)) bytes", comment: "plural") : rounded)
        }
        sizeLabel.stringValue = size.joined(separator: " · ")
        dateLabel.stringValue = String(localized: "Modified \(Format.date(facts.modified))",
                                       comment: "Conflict sheet: the item’s modification date")

        pills.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let digest = facts.digest, digest == other.digest {
            pills.addArrangedSubview(PillView(String(localized: "Identical", comment: "Conflict sheet: both items hold the same bytes"),
                                              tint: .systemGray))
            return
        }
        if let mine = facts.modified, let theirs = other.modified, mine.timeIntervalSince(theirs) > 1 {
            pills.addArrangedSubview(PillView(String(localized: "Newer", comment: "Conflict sheet: this item was modified later"),
                                              tint: .systemBlue))
        }
        if let mine = facts.bytes, let theirs = other.bytes, mine > theirs {
            pills.addArrangedSubview(PillView(String(localized: "Larger", comment: "Conflict sheet: this item is bigger"),
                                              tint: .systemOrange))
        }
    }

    func setThumbnail(_ image: NSImage) {
        imageView.image = image
        imageView.isPicture = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.quaternarySystemFill.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The card's picture: Finder icons as they are, real thumbnails with rounded corners and a hairline edge.
final class ThumbnailView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var isPicture = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            .integral
        guard isPicture else {
            image.draw(in: rect)
            return
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        edge.lineWidth = 1
        edge.stroke()
    }
}

/// Small capsule label: "Newer", "Larger", "Identical".
final class PillView: NSView {
    private let label: NSTextField
    private let tint: NSColor

    init(_ text: String, tint: NSColor) {
        self.tint = tint
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = tint
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

// MARK: - Diff

/// Rounded, bordered frame around the scrolling diff.
final class DiffBox: NSView {
    init(diffView: DiffView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = diffView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            diffView.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Unified diff rows: old and new line numbers, a +/− marker, and the line, tinted green or red.
final class DiffView: NSView {
    private let rows: [LineDiff.Row]
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    static let rowHeight: CGFloat = 16
    private static let padding: CGFloat = 4
    private let numberWidth: CGFloat
    private let textWidth: CGFloat

    override var isFlipped: Bool { true }

    init(rows: [LineDiff.Row]) {
        self.rows = rows
        let biggest = rows.reduce(0) { result, row in
            guard case .line(let line) = row else { return result }
            return max(result, line.oldNumber ?? 0, line.newNumber ?? 0)
        }
        let digits = max(2, String(biggest).count)
        numberWidth = CGFloat(digits) * 6 + 8
        let longest = rows.reduce(0) { result, row in
            guard case .line(let line) = row else { return result }
            return max(result, min(line.text.count, 400))
        }
        let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        textWidth = CGFloat(longest) * charWidth + 24
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: contentHeight).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: gutterWidth + textWidth).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var contentHeight: CGFloat { CGFloat(rows.count) * Self.rowHeight + Self.padding * 2 }
    private var gutterWidth: CGFloat { numberWidth * 2 + 18 }

    static func summary(added: Int, removed: Int) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let text = NSMutableAttributedString(string: "+\(added.formatted())", attributes: [.font: font, .foregroundColor: NSColor.systemGreen])
        text.append(NSAttributedString(string: "  −\(removed.formatted())", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        return text
    }

    override func draw(_ dirtyRect: NSRect) {
        let first = max(0, Int((dirtyRect.minY - Self.padding) / Self.rowHeight))
        let last = min(rows.count - 1, Int((dirtyRect.maxY - Self.padding) / Self.rowHeight))
        guard first <= last else { return }
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let right = NSMutableParagraphStyle()
        right.alignment = .right

        // Gutter divider.
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSRect(x: numberWidth * 2 + 4, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        for index in first...last {
            let y = Self.padding + CGFloat(index) * Self.rowHeight
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
            switch rows[index] {
            case .gap(let count):
                NSColor.quaternarySystemFill.setFill()
                rowRect.fill()
                let label = "⋯  " + String(localized: "\(count) unchanged lines", comment: "plural")
                (label as NSString).draw(at: NSPoint(x: gutterWidth, y: y + 1.5), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.tertiaryLabelColor,
                ])
            case .line(let line):
                let (tint, marker): (NSColor?, String) = switch line.kind {
                case .added: (.systemGreen, "+")
                case .removed: (.systemRed, "−")
                case .same: (nil, "")
                }
                if let tint {
                    tint.withAlphaComponent(0.13).setFill()
                    rowRect.fill()
                    tint.withAlphaComponent(0.7).setFill()
                    NSRect(x: 0, y: y, width: 2, height: Self.rowHeight).fill()
                }
                let old = line.oldNumber.map(String.init) ?? ""
                let new = line.newNumber.map(String.init) ?? ""
                var attributes = numberAttributes
                attributes[.paragraphStyle] = right
                (old as NSString).draw(in: NSRect(x: 0, y: y + 2.5, width: numberWidth - 2, height: 13), withAttributes: attributes)
                (new as NSString).draw(in: NSRect(x: numberWidth, y: y + 2.5, width: numberWidth - 2, height: 13), withAttributes: attributes)
                (marker as NSString).draw(at: NSPoint(x: numberWidth * 2 + 8, y: y + 1), withAttributes: [
                    .font: font, .foregroundColor: tint ?? NSColor.tertiaryLabelColor,
                ])
                let text = line.text.count > 400 ? String(line.text.prefix(400)) + "…" : line.text
                (text.replacingOccurrences(of: "\t", with: "    ") as NSString).draw(
                    at: NSPoint(x: gutterWidth, y: y + 1),
                    withAttributes: [.font: font, .foregroundColor: line.kind == .same ? NSColor.secondaryLabelColor : NSColor.labelColor])
            }
        }
    }
}
