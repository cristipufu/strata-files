import AppKit

/// Geometry of one icon-grid cell, derived from the icon size so the whole grid scales with the slider.
struct GridMetrics: Equatable {
    static let minIconSize: CGFloat = 32
    static let maxIconSize: CGFloat = 256

    let typography: FileViewTypography
    let iconSize: CGFloat
    /// Padding between the icon and its selection box.
    let iconPad: CGFloat
    let topPad: CGFloat = 6
    let nameGap: CGFloat = 4
    let lineHeight: CGFloat
    let detailHeight: CGFloat
    let bottomPad: CGFloat = 6

    init(iconSize: CGFloat, typography: FileViewTypography) {
        self.typography = typography
        self.iconSize = iconSize.isFinite ? min(max(iconSize.rounded(), Self.minIconSize), Self.maxIconSize) : 64
        iconPad = (self.iconSize * 0.07).rounded().clamped(3, 10)
        let font = typography.font
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let detail = FileViewStyle.detailFont
        detailHeight = ceil(detail.ascender - detail.descender) + 2
    }

    /// The size of name up to which two short words fit the narrowest label.
    private static let narrowestLabel: (width: CGFloat, textSize: CGFloat) = (94, 16)

    /// Width available to the name: a little wider than the icon, never narrower than two short words. For names
    /// larger than that label was made for, it is as much wider as they are larger.
    var labelWidth: CGFloat {
        let narrowest = Self.narrowestLabel
        let twoShortWords = narrowest.width * max(1, typography.font.pointSize / narrowest.textSize)
        return max(iconSize + 34, twoShortWords.rounded())
    }
    var minCellWidth: CGFloat { labelWidth + 16 }
    var iconBoxSide: CGFloat { iconSize + iconPad * 2 }
    var itemHeight: CGFloat {
        topPad + iconBoxSide + nameGap + lineHeight * 2 + 2 + detailHeight + bottomPad
    }
}

fileprivate extension CGFloat {
    func clamped(_ low: CGFloat, _ high: CGFloat) -> CGFloat { Swift.min(Swift.max(self, low), high) }
}

/// A justified grid: as many equal columns as fit, items centered in each, rows of uniform height. Layout is O(visible)
/// so huge folders scroll smoothly. Points between items propose a background drop (gap before the end) instead of
/// an insertion point, since a file grid has no manual ordering.
final class GridLayout: NSCollectionViewLayout {
    var metrics = GridMetrics(iconSize: 64, typography: .standard)
    var sections: [FileKindSections.Section] = [] {
        didSet { measureSections(); invalidateLayout() }
    }
    var insets = NSEdgeInsets(top: 10, left: 14, bottom: 18, right: 14)
    var rowSpacing: CGFloat = 2
    private(set) var columns = 1
    private var cellWidth: CGFloat = 100
    private var lastWidth: CGFloat = 0

    private struct Band {
        let files: Range<Int>
        let header: NSRect?
        let startY: CGFloat
        let rows: Int
    }
    private var bands: [Band] = []
    private var contentHeight: CGFloat = 0
    private var pitch: CGFloat { metrics.itemHeight + rowSpacing }
    private var width: CGFloat {
        let value = collectionView?.enclosingScrollView?.contentView.bounds.width ?? collectionView?.bounds.width ?? 0
        return value.isFinite ? max(value, 0) : 0
    }
    private var left: CGFloat {
        let slack = max(width - insets.left - insets.right - cellWidth * CGFloat(columns), 0)
        return insets.left + (slack / 2).rounded(.down)
    }

    override func prepare() {
        super.prepare()
        let available = max(width - insets.left - insets.right, metrics.minCellWidth)
        columns = max(1, Int(exactly: floor(available / metrics.minCellWidth)) ?? 1)
        cellWidth = floor(available / CGFloat(columns))
        lastWidth = width
        measureSections()
    }

    private func measureSections() {
        var y = insets.top
        bands = sections.map { section in
            let header = section.kind.map { _ in NSRect(x: insets.left, y: y,
                width: max(0, width - insets.left - insets.right), height: metrics.lineHeight + 12) }
            if let header { y = header.maxY }
            let rows = section.files.isEmpty ? 0 : (section.files.count - 1) / columns + 1
            let band = Band(files: section.files, header: header, startY: y, rows: rows)
            y += CGFloat(rows) * pitch
            return band
        }
        contentHeight = max(y - rowSpacing, insets.top) + insets.bottom
    }

    override var collectionViewContentSize: NSSize { NSSize(width: width, height: contentHeight) }

    func frame(for index: Int) -> NSRect {
        guard let band = bands.first(where: { $0.files.contains(index) }) else { return .zero }
        let local = index - band.files.lowerBound
        return NSRect(x: left + CGFloat(local % columns) * cellWidth, y: band.startY + CGFloat(local / columns) * pitch,
                      width: cellWidth, height: metrics.itemHeight)
    }

    func index(at point: NSPoint) -> Int? {
        let col = floor((point.x - left) / cellWidth)
        guard col >= 0, col < CGFloat(columns) else { return nil }
        for band in bands {
            let row = floor((point.y - band.startY) / pitch)
            guard row >= 0, row < CGFloat(band.rows) else { continue }
            let index = band.files.lowerBound + Int(row) * columns + Int(col)
            if band.files.contains(index), frame(for: index).contains(point) { return index }
        }
        return nil
    }

    /// Visible file indexes are contiguous across section boundaries, even across a short last row.
    func indexes(in rect: NSRect) -> Range<Int> {
        guard !rect.isNull, !rect.minY.isNaN, !rect.maxY.isNaN else { return 0..<0 }
        var first: Int?, end = 0
        for band in bands where band.rows > 0 {
            let lower = max(0, floor((rect.minY - band.startY) / pitch))
            let upper = min(CGFloat(band.rows - 1), floor((rect.maxY - band.startY) / pitch))
            guard lower <= upper else { continue }
            if first == nil { first = band.files.lowerBound + Int(lower) * columns }
            end = min(band.files.upperBound, band.files.lowerBound + (Int(upper) + 1) * columns)
        }
        return (first ?? end)..<end
    }

    func verticalNeighbor(of index: Int, down: Bool) -> Int {
        guard let section = bands.firstIndex(where: { $0.files.contains(index) }) else { return index }
        let band = bands[section], local = index - band.files.lowerBound
        let row = local / columns + (down ? 1 : -1)
        if (0..<band.rows).contains(row) {
            return min(band.files.upperBound - 1, band.files.lowerBound + row * columns + local % columns)
        }
        let next = section + (down ? 1 : -1)
        guard bands.indices.contains(next) else { return index }
        let neighbor = bands[next]
        let start = neighbor.files.lowerBound + (down ? 0 : neighbor.rows - 1) * columns
        return min(neighbor.files.upperBound - 1, start + local % columns)
    }

    func isHeading(at point: NSPoint) -> Bool { bands.contains { $0.header?.contains(point) == true } }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result = indexes(in: rect).compactMap { index -> NSCollectionViewLayoutAttributes? in
            guard let section = bands.firstIndex(where: { $0.files.contains(index) }) else { return nil }
            return attributes(for: index, section: section)
        }
        for (section, band) in bands.enumerated() where band.header?.intersects(rect) == true {
            if let header = layoutAttributesForSupplementaryView(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                  at: IndexPath(item: 0, section: section)) { result.append(header) }
        }
        return result
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: NSCollectionView.SupplementaryElementKind,
                                                         at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard elementKind == NSCollectionView.elementKindSectionHeader, indexPath.count == 2,
              bands.indices.contains(indexPath.section), let frame = bands[indexPath.section].header else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        attributes.frame = frame
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.count == 2, bands.indices.contains(indexPath.section) else { return nil }
        let range = bands[indexPath.section].files
        guard indexPath.item >= 0, indexPath.item < range.count else { return nil }
        return attributes(for: range.lowerBound + indexPath.item, section: indexPath.section)
    }

    private func attributes(for index: Int, section: Int) -> NSCollectionViewLayoutAttributes {
        let path = IndexPath(item: index - bands[section].files.lowerBound, section: section)
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: path)
        attributes.frame = frame(for: index)
        return attributes
    }

    override func layoutAttributesForDropTarget(at pointInCollectionView: NSPoint) -> NSCollectionViewLayoutAttributes? {
        if let index = index(at: pointInCollectionView), let section = bands.firstIndex(where: { $0.files.contains(index) }) {
            return attributes(for: index, section: section)
        }
        guard let last = bands.indices.last else { return nil }
        let gap = NSCollectionViewLayoutAttributes(forInterItemGapBefore: IndexPath(item: bands[last].files.count, section: last))
        gap.frame = .zero
        return gap
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { abs(newBounds.width - lastWidth) > 0.5 }
}
