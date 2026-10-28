import AppKit

/// The last column when a file is selected: a large thumbnail, the name, and compact metadata.
final class ColumnPreviewPane: NSView {
    let thumbnails: FileThumbnails
    let itemInfo: ItemInfoLoader
    let imageView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let grid = NSGridView()
    private var imageSide: NSLayoutConstraint!
    private var imageHeight: NSLayoutConstraint!
    private var labelColumnWidth: CGFloat = 0
    private(set) var entry: FileEntry?
    private var thumbnailTicket: FileThumbnails.Ticket?
    private var infoTicket: ItemInfoLoader.Ticket?
    private(set) var dimensionsField: NSTextField?

    override var isFlipped: Bool { true }

    isolated deinit {
        thumbnails.cancel(thumbnailTicket)
        itemInfo.cancel(infoTicket)
    }

    init(frame: NSRect = .zero, thumbnails: FileThumbnails = .shared, itemInfo: ItemInfoLoader = .shared) {
        self.thumbnails = thumbnails
        self.itemInfo = itemInfo
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityElement(false)

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.isSelectable = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitle.font = FileViewStyle.detailFont
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        grid.rowSpacing = 5
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [imageView, nameLabel, subtitle, separator, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(14, after: imageView)
        stack.setCustomSpacing(12, after: subtitle)
        stack.setCustomSpacing(10, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        imageSide = imageView.widthAnchor.constraint(equalToConstant: 200)
        imageHeight = imageView.heightAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            imageSide,
            imageHeight,
            nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    convenience override init(frame: NSRect) {
        self.init(frame: frame, thumbnails: .shared, itemInfo: .shared)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        // Preview as large as the column allows, within reason.
        let side = min(max(bounds.width - 56, 96), 260).rounded()
        if imageSide.constant != side {
            imageSide.constant = side
            fitImageHeight()
            if let entry { requestThumbnail(entry, side: side) }
        }
        // Labels right-aligned to a shared axis a little left of center, values to its right.
        let labelWidth = max(40, ((bounds.width - 36) * 0.4).rounded())
        if labelWidth != labelColumnWidth, grid.numberOfColumns == 2 {
            labelColumnWidth = labelWidth
            grid.column(at: 0).width = labelWidth
        }
        super.layout()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview == nil else { return }
        thumbnails.cancel(thumbnailTicket)
        itemInfo.cancel(infoTicket)
        thumbnailTicket = nil
        infoTicket = nil
    }

    func show(_ entry: FileEntry) {
        self.entry = entry
        nameLabel.stringValue = entry.displayName
        subtitle.stringValue = [entry.kind, entry.size.map(Format.bytes)].compactMap { $0 }.joined(separator: " · ")
        setAccessibilityLabel(String(localized: "Preview of \(entry.displayName)", comment: "Accessibility; the placeholder is a file name"))
        setImage(thumbnails.icon(for: entry), animated: false)
        requestThumbnail(entry, side: imageSide.constant)

        var rows: [(String, String)] = [
            (String(localized: "Created", comment: "Info row label: the date the item was created"), Format.date(entry.created)),
            (String(localized: "Modified", comment: "Info row label: the date the item was last modified"), Format.date(entry.modified)),
        ]
        if let added = entry.added {
            rows.append((String(localized: "Added", comment: "Info row label: the date the item was added to its folder"), Format.date(added)))
        }
        itemInfo.cancel(infoTicket)
        infoTicket = nil
        let wantsDimensions = entry.contentType?.conforms(to: .image) == true && itemInfo.needsLoading(entry)
        let cachedDimensions = wantsDimensions ? itemInfo.immediate(entry, showHidden: true) : nil
        if wantsDimensions {
            rows.append((String(localized: "Dimensions", comment: "Info row label: an image's size in pixels"), cachedDimensions ?? "…"))
        }
        let fields = setRows(rows)
        // The dimensions row is the last one; its value arrives later.
        if wantsDimensions { dimensionsField = fields.last }
        if wantsDimensions, cachedDimensions == nil {
            infoTicket = itemInfo.request(entry, showHidden: true) { [weak self] text in
                guard let self, self.entry == entry else { return }
                self.infoTicket = nil
                self.dimensionsField?.stringValue = text
            }
        }
    }

    /// Wide thumbnails get a shorter box so the name sits right under them; icons stay square.
    private func fitImageHeight() {
        let side = imageSide.constant
        guard let image = imageView.image, image.size.width > 0 else {
            imageHeight.constant = side
            return
        }
        let aspect = image.size.height / image.size.width
        var height = side * min(max(aspect, 0.45), 1)
        if imageView.imageScaling == .scaleProportionallyDown {
            height = min(height, max(image.size.height * min(side / image.size.width, 1), 64))
        }
        imageHeight.constant = height.rounded()
    }

    private func setImage(_ image: NSImage, animated: Bool, upscale: Bool = true) {
        imageView.imageScaling = upscale ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            imageView.layer?.add(fade, forKey: "thumbnail")
        }
        imageView.image = image
        fitImageHeight()
    }

    private func requestThumbnail(_ entry: FileEntry, side: CGFloat) {
        thumbnails.cancel(thumbnailTicket)
        thumbnailTicket = nil
        let scale = window?.backingScaleFactor ?? 2
        if let cached = thumbnails.cached(entry, size: side, scale: scale) {
            setImage(cached.image, animated: false, upscale: !cached.exact)
            if cached.exact { return }
        }
        thumbnailTicket = thumbnails.request(entry, size: side, scale: scale) { [weak self] image in
            guard let self, self.entry == entry else { return }
            self.thumbnailTicket = nil
            self.setImage(image, animated: true, upscale: false)
        }
    }

    /// The value fields, in row order.
    @discardableResult
    private func setRows(_ rows: [(String, String)]) -> [NSTextField] {
        while grid.numberOfRows > 0 {
            let row = grid.row(at: 0)
            for index in 0..<row.numberOfCells { row.cell(at: index).contentView?.removeFromSuperview() }
            grid.removeRow(at: 0)
        }
        dimensionsField = nil
        var fields: [NSTextField] = []
        for (name, value) in rows {
            let label = NSTextField(labelWithString: name)
            label.font = FileViewStyle.detailFont
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            let field = NSTextField(labelWithString: value)
            field.font = FileViewStyle.detailFont
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fields.append(field)
            grid.addRow(with: [label, field])
        }
        if grid.numberOfColumns == 2 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .leading
            labelColumnWidth = 0
            needsLayout = true
        }
        return fields
    }
}
